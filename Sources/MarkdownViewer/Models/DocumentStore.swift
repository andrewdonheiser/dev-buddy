import AppKit
import Combine
import Foundation
import MarkdownViewerKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the set of open documents, the current selection, and file watching.
@MainActor
final class DocumentStore: ObservableObject {

    static let shared = DocumentStore()

    @Published private(set) var documents: [OpenDocument] = []
    @Published var selectedID: OpenDocument.ID? {
        // Selecting a document always leaves the browser, terminal, and
        // workspace panes, so the detail column goes back to Markdown.
        didSet {
            selectedWebPageID = nil
            selectedTerminalID = nil
            selectedWorkspaceID = nil
        }
    }
    /// The nested web page shown in the embedded browser, if any.
    @Published var selectedWebPageID: LinkedWebPage.ID?
    /// Web pages opened from links in each document, in click order.
    @Published private(set) var webPages: [LinkedWebPage] = []
    /// The terminal tab shown in the embedded terminal, if any.
    @Published var selectedTerminalID: TerminalTab.ID?
    /// Terminal tabs, top-level and nested, in open order.
    @Published private(set) var terminals: [TerminalTab] = []
    /// Workspace tabs mapping to folders on disk, in open order.
    @Published private(set) var workspaces: [Workspace] = []
    /// The workspace whose overview is showing, if any.
    @Published var selectedWorkspaceID: Workspace.ID?
    /// Items whose nested children are expanded in the sidebar.
    @Published private(set) var expandedParents: Set<TabParent> = []
    /// Paths of the tabs the user checked as extra input for the LLM. The
    /// selected document is always used, checked or not.
    @Published private(set) var chatContextPaths: Set<String> = []

    private var watchers: [OpenDocument.ID: FileWatcher] = [:]
    private let renderer = HTMLRenderer()
    private let options = ViewOptions.shared
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Re-render every document when the reading width or text size changes.
        options.$contentWidth
            .combineLatest(options.$fontSize)
            .dropFirst()
            .sink { [weak self] _, _ in self?.rerenderAll() }
            .store(in: &cancellables)

        // Theme changes only affect styling, but re-rendering keeps the emitted
        // HTML in sync with the selected theme.
        options.$themeIndex
            .dropFirst()
            .sink { [weak self] _ in self?.rerenderAll() }
            .store(in: &cancellables)
    }

    var selectedDocument: OpenDocument? {
        guard let selectedID else { return nil }
        return documents.first { $0.id == selectedID }
    }

    /// The nested web page on screen, if any.
    var selectedWebPage: LinkedWebPage? {
        guard let selectedWebPageID else { return nil }
        return webPages.first { $0.id == selectedWebPageID }
    }

    /// The terminal tab on screen, if any.
    var selectedTerminal: TerminalTab? {
        guard let selectedTerminalID else { return nil }
        return terminals.first { $0.id == selectedTerminalID }
    }

    /// The workspace whose overview is on screen, if any.
    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// What the chat panel is bound to: the selected document, or the selected
    /// workspace (whose files become the chat context).
    enum ChatTarget {
        case document(OpenDocument)
        case workspace(Workspace)
    }

    var chatTarget: ChatTarget? {
        if let document = selectedDocument { return .document(document) }
        if let workspace = selectedWorkspace { return .workspace(workspace) }
        return nil
    }

    func document(id: OpenDocument.ID) -> OpenDocument? {
        documents.first { $0.id == id }
    }

    /// Top-level tabs only, in order; documents opened through links nest
    /// under their parent instead.
    var topLevelDocuments: [OpenDocument] {
        documents.filter { $0.parentID == nil }
    }

    /// Selects a document tab, leaving the browser pane if one was showing.
    func selectDocument(_ id: OpenDocument.ID) {
        selectedID = id
    }

    /// Selects a nested web page to show in the browser pane. The document
    /// selection follows the page's parent, so the chat panel keeps talking
    /// about the document the page belongs to.
    func select(webPageID: LinkedWebPage.ID) {
        guard let page = webPages.first(where: { $0.id == webPageID }) else { return }
        if let parent = documents.first(where: { $0.id == page.parentID }) {
            selectedID = parent.id
        }
        selectedWebPageID = webPageID
    }

    // MARK: - Terminal tabs

    /// Selects a terminal tab to show in the terminal pane. A nested terminal
    /// anchors the chat to its parent — the document, or the workspace it was
    /// opened from — like web pages do, so the chat panel keeps its context.
    func select(terminalID: TerminalTab.ID) {
        guard let terminal = terminals.first(where: { $0.id == terminalID }) else { return }
        switch terminal.parentID {
        case .document(let docID) where documents.contains(where: { $0.id == docID }):
            selectedID = docID
        case .workspace(let wsID) where workspaces.contains(where: { $0.id == wsID }):
            if selectedID != nil { selectedID = nil } // clears web page + terminal
            selectedWebPageID = nil
            selectedWorkspaceID = wsID
        default:
            selectedWebPageID = nil
        }
        selectedTerminalID = terminalID
    }

    /// Opens a terminal tab running the OpenCode TUI. Nested under `parent`
    /// when given; otherwise a top-level tab.
    @discardableResult
    func openTerminal(in directory: URL, parent: TabParent? = nil) -> TerminalTab {
        let terminal = TerminalTab(parentID: parent, workingDirectory: directory)
        terminals.append(terminal)
        switch parent {
        case .document(let docID):
            expandedParents.insert(.document(docID))
            selectedID = docID // clears the terminal selection; re-set below
        case .workspace(let wsID):
            expandedParents.insert(.workspace(wsID))
            select(workspaceID: wsID)
        case nil:
            selectedWebPageID = nil
        }
        selectedTerminalID = terminal.id
        return terminal
    }

    /// Opens a terminal nested under a workspace, running in the workspace
    /// folder — that directory becomes the working directory opencode uses.
    @discardableResult
    func openTerminal(in workspace: Workspace) -> TerminalTab {
        openTerminal(in: workspace.url, parent: .workspace(workspace.id))
    }

    /// Opens a top-level terminal in the selected document's folder (or the
    /// home folder when nothing is open).
    @discardableResult
    func openTerminalTab() -> TerminalTab {
        let directory = selectedDocument?.url.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        return openTerminal(in: directory)
    }

    /// Closes a terminal tab and stops its process.
    func closeTerminal(id: TerminalTab.ID) {
        terminals.removeAll { $0.id == id }
        TerminalSessionManager.shared.removeSession(terminalID: id)
        if selectedTerminalID == id {
            selectedTerminalID = nil
        }
    }

    /// Updates a terminal tab's title as the running program reports it.
    func updateTerminalTitle(id: TerminalTab.ID, title: String) {
        guard let index = terminals.firstIndex(where: { $0.id == id }),
              !title.isEmpty, terminals[index].title != title else { return }
        terminals[index].title = title
    }

    // MARK: - Workspaces

    /// Opens a folder as a workspace tab, or focuses the existing workspace
    /// for the same folder.
    @discardableResult
    func openWorkspace(url: URL) -> Workspace {
        let standardized = url.standardizedFileURL
        if let existing = workspaces.first(where: { $0.url == standardized }) {
            select(workspaceID: existing.id)
            return existing
        }
        let workspace = Workspace(url: standardized)
        workspaces.append(workspace)
        select(workspaceID: workspace.id)
        return workspace
    }

    /// Shows a workspace's overview. Leaves the browser and terminal panes;
    /// the chat rebinds to the workspace itself.
    func select(workspaceID: Workspace.ID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        if selectedID != nil { selectedID = nil } // clears web page + terminal
        selectedWebPageID = nil
        selectedTerminalID = nil
        selectedWorkspaceID = workspaceID
    }

    /// Closes a workspace and everything nested under it: its documents and
    /// terminals. Unsaved edits are confirmed first, like closing a document.
    func close(workspaceID: Workspace.ID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        let childIDs = documents.filter { $0.parentID == .workspace(workspaceID) }.map(\.id)
        for terminal in terminals where terminal.parentID == .workspace(workspaceID) {
            closeTerminal(id: terminal.id)
        }
        for childID in childIDs {
            close(childID)
        }
        workspaces.removeAll { $0.id == workspaceID }
        expandedParents.remove(.workspace(workspaceID))
        if selectedWorkspaceID == workspaceID {
            selectedWorkspaceID = nil
        }
    }

    /// Re-reads the workspace folder's Markdown files.
    func rescanWorkspace(id: Workspace.ID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].rescan()
    }

    /// Opens a file from the workspace as a document nested under it, with
    /// the full editing / watching / chat machinery.
    @discardableResult
    func openFile(_ url: URL, in workspace: Workspace) -> OpenDocument? {
        openNested(url: url, parent: .workspace(workspace.id))
    }

    /// Opens a workspace file located by its workspace and relative path.
    @discardableResult
    func openFile(_ file: WorkspaceFile) -> OpenDocument? {
        guard let workspace = workspaces.first(where: { $0.id == file.workspaceID }) else { return nil }
        return openFile(file.url, in: workspace)
    }

    /// The folder picker behind "Open Workspace…".
    func presentWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openWorkspace(url: url)
        }
    }

    // MARK: - Opening links

    /// Handles a link clicked inside a rendered document. Web links and links
    /// to other local Markdown files become nested items under the document
    /// in the sidebar; anything else goes to the system.
    func openLink(_ url: URL, in document: OpenDocument) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            selectedID = document.id // the chat follows the document the link came from
            if let existing = webPages.first(where: { $0.parentID == document.id && $0.url == url }) {
                selectedWebPageID = existing.id
            } else {
                let page = LinkedWebPage(parentID: document.id, url: url)
                webPages.append(page)
                selectedWebPageID = page.id
                // Start loading right away so the chat can quote the page
                // even before it has been viewed.
                _ = WebPageSessionManager.shared.session(for: page)
            }
            expandedParents.insert(.document(document.id))
        case "file" where Self.isMarkdownFile(url):
            openNested(url: url, parent: .document(document.id))
        default:
            NSWorkspace.shared.open(url)
        }
    }

    static func isMarkdownFile(_ url: URL) -> Bool {
        let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Opens a local Markdown file as a document nested under `parent` —
    /// another document or a workspace.
    @discardableResult
    private func openNested(url: URL, parent: TabParent) -> OpenDocument? {
        let standardized = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == standardized }) {
            selectedID = existing.id
            if let existingParent = existing.parentID {
                expandedParents.insert(existingParent)
            }
            return existing
        }
        guard var nested = makeDocument(for: standardized) else {
            NSWorkspace.shared.open(url)
            return nil
        }
        nested.parentID = parent
        documents.append(nested)
        selectedID = nested.id
        startWatching(nested)
        expandedParents.insert(parent)
        LabelStore.shared.register(path: standardized.path)
        return nested
    }

    /// Updates a nested web page's title as the browser reports it.
    func updateWebPageTitle(id: LinkedWebPage.ID, title: String) {
        guard let index = webPages.firstIndex(where: { $0.id == id }),
              !title.isEmpty, webPages[index].title != title else { return }
        webPages[index].title = title
    }

    /// Stores a web page's visible text as reported by its browser session,
    /// so the chat can quote it.
    func updateWebPageText(id: LinkedWebPage.ID, text: String) {
        guard let index = webPages.firstIndex(where: { $0.id == id }),
              !text.isEmpty, webPages[index].text != text else { return }
        webPages[index].text = text
    }

    /// Closes a nested web page and its browsing session.
    func closeWebPage(id: LinkedWebPage.ID) {
        webPages.removeAll { $0.id == id }
        WebPageSessionManager.shared.removeSession(pageID: id)
        if selectedWebPageID == id {
            selectedWebPageID = nil
        }
    }

    /// Expands or collapses an item's nested children in the sidebar.
    func setExpanded(_ expanded: Bool, parent: TabParent) {
        if expanded {
            expandedParents.insert(parent)
        } else {
            expandedParents.remove(parent)
        }
    }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.markdownContentTypes + [.plainText]
        panel.prompt = "Open"
        if panel.runModal() == .OK {
            open(urls: panel.urls)
        }
    }

    func open(urls: [URL]) {
        let labels = LabelStore.shared
        for url in urls {
            let standardized = url.standardizedFileURL

            // A label points at a file that may no longer exist; forget it so
            // stale entries do not linger in search results.
            guard FileManager.default.fileExists(atPath: standardized.path) else {
                labels.removeEverywhere(path: standardized.path)
                continue
            }

            // Folders (dropped, opened from Finder, or passed on the command
            // line) become workspace tabs.
            if Self.isDirectory(standardized) {
                openWorkspace(url: standardized)
                continue
            }

            if let existing = documents.first(where: { $0.url == standardized }) {
                selectedID = existing.id
                reload(existing.id)
                labels.register(path: standardized.path)
                continue
            }
            guard let document = makeDocument(for: standardized) else { continue }
            documents.append(document)
            selectedID = document.id
            startWatching(document)
            labels.register(path: standardized.path)
        }
    }

    func open(url: URL) {
        open(urls: [url])
    }

    private func makeDocument(for url: URL) -> OpenDocument? {
        guard let markdown = readMarkdown(at: url) else { return nil }
        let html = render(markdown: markdown, baseURL: url.deletingLastPathComponent())
        return OpenDocument(
            url: url,
            markdown: markdown,
            html: html,
            lastModified: modificationDate(of: url)
        )
    }

    private func readMarkdown(at url: URL) -> String? {
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents
        }
        if let data = try? Data(contentsOf: url),
           let contents = String(data: data, encoding: .isoLatin1) {
            return contents
        }
        return nil
    }

    // MARK: - Editing

    /// Draft text for documents in edit mode, keyed by document ID. A
    /// document with an entry here is being edited; the entry is its buffer.
    @Published private(set) var drafts: [OpenDocument.ID: String] = [:]

    /// Whether the document is showing the editor instead of the rendered page.
    func isEditing(_ id: OpenDocument.ID) -> Bool {
        drafts[id] != nil
    }

    /// The edit buffer, or nil when the document is not being edited.
    func draft(for id: OpenDocument.ID) -> String? {
        drafts[id]
    }

    /// Whether the edit buffer differs from the contents saved on disk.
    func isDraftDirty(_ id: OpenDocument.ID) -> Bool {
        guard let draft = drafts[id],
              let document = documents.first(where: { $0.id == id }) else { return false }
        return draft != document.markdown
    }

    /// Opens the editor for the document, seeding the buffer from the file.
    func beginEditing(_ id: OpenDocument.ID) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        if drafts[id] == nil {
            drafts[id] = document.markdown
        }
    }

    /// Updates the edit buffer as the user types.
    func updateDraft(_ id: OpenDocument.ID, text: String) {
        guard isEditing(id) else { return }
        drafts[id] = text
    }

    /// Leaves edit mode, discarding unsaved changes after confirmation.
    func endEditing(_ id: OpenDocument.ID) {
        guard isEditing(id) else { return }
        if isDraftDirty(id), let document = documents.first(where: { $0.id == id }) {
            guard confirmDiscard(fileName: document.fileName) else { return }
        }
        discardDraft(id)
    }

    /// Drops the edit buffer without any confirmation. Used after the user
    /// has already chosen to discard, and when a tab closes.
    func discardDraft(_ id: OpenDocument.ID) {
        drafts[id] = nil
    }

    /// Toggles the editor for the document.
    func toggleEditing(_ id: OpenDocument.ID) {
        if isEditing(id) {
            endEditing(id)
        } else {
            beginEditing(id)
        }
    }

    /// Writes the edit buffer back to the file and re-renders the page. The
    /// editor stays open with a clean buffer so editing can continue.
    @discardableResult
    func save(_ id: OpenDocument.ID) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              let draft = drafts[id] else { return false }
        do {
            try draft.write(to: documents[index].url, atomically: true, encoding: .utf8)
        } catch {
            presentSaveError(for: documents[index], underlying: error)
            return false
        }
        documents[index].markdown = draft
        documents[index].html = render(markdown: draft, baseURL: documents[index].url.deletingLastPathComponent())
        documents[index].lastModified = modificationDate(of: documents[index].url)
        documents[index].revision &+= 1
        drafts[id] = draft
        return true
    }

    // MARK: - Closing

    func close(_ id: OpenDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        if isDraftDirty(id) {
            switch confirmClose(fileName: documents[index].fileName) {
            case .save:
                guard save(id) else { return } // save failed; keep the tab open
            case .discard:
                break
            case .cancel:
                return
            }
        }
        watchers[id]?.stop()
        watchers[id] = nil
        discardDraft(id)

        let wasSelected = selectedID == id
        documents.remove(at: index)

        // Nested items follow their parent: web pages and terminals are
        // dropped outright, child documents go through the same close (and
        // confirmation) flow.
        let childIDs = documents.filter { $0.parentID == .document(id) }.map(\.id)
        for page in webPages where page.parentID == id {
            closeWebPage(id: page.id)
        }
        for terminal in terminals where terminal.parentID == .document(id) {
            closeTerminal(id: terminal.id)
        }
        for childID in childIDs {
            close(childID)
        }
        expandedParents.remove(.document(id))

        if wasSelected {
            if documents.isEmpty {
                selectedID = nil
            } else {
                let nextIndex = min(index, documents.count - 1)
                if documents[nextIndex].parentID != nil, let top = topLevelDocuments.first {
                    // Prefer falling back to a top-level tab rather than
                    // another document's nested child.
                    selectedID = top.id
                } else {
                    selectedID = documents[nextIndex].id
                }
            }
        }
    }

    func closeSelected() {
        // With a terminal, web page, or workspace on screen, ⌘W closes that
        // item first, not its document.
        if let terminalID = selectedTerminalID {
            closeTerminal(id: terminalID)
            return
        }
        if let webPageID = selectedWebPageID {
            closeWebPage(id: webPageID)
            return
        }
        if let workspaceID = selectedWorkspaceID {
            close(workspaceID: workspaceID)
            return
        }
        guard let selectedID else { return }
        close(selectedID)
    }

    /// Whether ⌘W has anything to close right now.
    var canCloseSelected: Bool {
        selectedID != nil || selectedWebPageID != nil
            || selectedTerminalID != nil || selectedWorkspaceID != nil
    }

    /// Closes every open document. Unsaved edits are confirmed first.
    func closeAll() {
        guard resolveUnsavedEdits(quitting: false) else { return }
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        documents = []
        selectedID = nil
        chatContextPaths = []
        drafts = [:]
        for page in webPages {
            WebPageSessionManager.shared.removeSession(pageID: page.id)
        }
        webPages = []
        for terminal in terminals {
            TerminalSessionManager.shared.removeSession(terminalID: terminal.id)
        }
        terminals = []
        workspaces = []
        selectedWebPageID = nil
        selectedTerminalID = nil
        selectedWorkspaceID = nil
        expandedParents = []
    }

    /// Prompts about unsaved edits before the tab list is replaced or the app
    /// quits. Saves or discards them according to the answer. Returns false
    /// when the user cancelled or a save failed, meaning the action (closing
    /// or quitting) should not proceed.
    @discardableResult
    func resolveUnsavedEdits(quitting: Bool) -> Bool {
        let dirtyIDs = documents.filter { isDraftDirty($0.id) }.map(\.id)
        guard !dirtyIDs.isEmpty else { return true }
        switch confirmCloseAll(dirtyCount: dirtyIDs.count, quitting: quitting) {
        case .save:
            // A failed save aborts so nothing is lost; the user can retry.
            for id in dirtyIDs where !save(id) { return false }
        case .discard:
            break
        case .cancel:
            return false
        }
        return true
    }

    // MARK: - Saved views

    /// Snapshots the open tab list into a named, restorable view, keeping the
    /// nested links, web pages, terminals, and workspaces under each tab.
    @discardableResult
    func saveCurrentView(named name: String) -> SavedView? {
        SavedViewStore.shared.save(
            name: name,
            paths: topLevelDocuments.map { $0.url.path },
            selectedPath: selectedDocument?.url.path,
            tree: tabSnapshots(),
            topLevelTerminals: topLevelTerminals.map {
                TerminalTabSnapshot(id: $0.id, directory: $0.workingDirectory.path)
            },
            workspaces: workspaceSnapshots(),
            selectedWebPageURL: selectedWebPage?.url.absoluteString,
            selectedTerminalID: selectedTerminal?.id,
            selectedWorkspaceID: selectedWorkspace?.id
        )
    }

    /// Replaces the tab list with the files stored in a saved view. Files that
    /// no longer exist on disk are skipped.
    func open(_ view: SavedView) {
        closeAll()
        if let tree = view.tree, !tree.isEmpty {
            restore(from: tree)
        } else if !view.paths.isEmpty {
            // A view saved before nested links existed: a flat file list.
            open(urls: view.paths.map { URL(fileURLWithPath: $0) })
        }
        restoreTopLevelTerminals(from: view.topLevelTerminals ?? [])
        restoreWorkspaces(from: view.workspaces ?? [])
        if let selectedPath = view.selectedPath,
           let match = documents.first(where: { $0.url.path == selectedPath }) {
            selectedID = match.id
        }
        if let webURLString = view.selectedWebPageURL,
           let url = URL(string: webURLString),
           let page = webPages.first(where: { $0.url == url }) {
            selectedWebPageID = page.id
        }
        if let terminalID = view.selectedTerminalID,
           terminals.contains(where: { $0.id == terminalID }) {
            select(terminalID: terminalID)
        } else if let workspaceID = view.selectedWorkspaceID,
                  workspaces.contains(where: { $0.id == workspaceID }) {
            // The workspace overview applies last: nothing else was showing.
            select(workspaceID: workspaceID)
        }
    }

    // MARK: - Tab tree snapshots

    /// A serializable snapshot of every top-level tab and the links nested
    /// under it. Feeds session restore and saved views.
    func tabSnapshots() -> [TabSnapshot] {
        topLevelDocuments.map { snapshot(for: $0) }
    }

    private func snapshot(for document: OpenDocument) -> TabSnapshot {
        TabSnapshot(
            path: document.url.path,
            expanded: expandedParents.contains(.document(document.id)),
            webPageURLs: webPages
                .filter { $0.parentID == document.id }
                .map { $0.url.absoluteString },
            markdownChildren: documents
                .filter { $0.parentID == .document(document.id) }
                .map { snapshot(for: $0) },
            terminals: terminals
                .filter { $0.parentID == .document(document.id) }
                .map { TerminalTabSnapshot(id: $0.id, directory: $0.workingDirectory.path) }
        )
    }

    /// Snapshots every workspace tab and the documents and terminals nested
    /// under it.
    func workspaceSnapshots() -> [WorkspaceSnapshot] {
        workspaces.map { workspace in
            WorkspaceSnapshot(
                id: workspace.id,
                directory: workspace.url.path,
                expanded: expandedParents.contains(.workspace(workspace.id)),
                markdownChildren: documents
                    .filter { $0.parentID == .workspace(workspace.id) }
                    .map { snapshot(for: $0) },
                terminals: terminals
                    .filter { $0.parentID == .workspace(workspace.id) }
                    .map { TerminalTabSnapshot(id: $0.id, directory: $0.workingDirectory.path) }
            )
        }
    }

    /// Rebuilds the tab list from snapshots: top-level tabs first, then their
    /// nested Markdown files and web pages, recursively. Missing files are
    /// skipped.
    func restore(from snapshots: [TabSnapshot]) {
        for tab in snapshots {
            let url = URL(fileURLWithPath: tab.path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  !documents.contains(where: { $0.url == url }),
                  let document = makeDocument(for: url) else { continue }
            documents.append(document)
            startWatching(document)
            LabelStore.shared.register(path: url.path)
            if tab.expanded { expandedParents.insert(.document(document.id)) }
            restoreChildren(of: tab, under: .document(document.id))
        }
    }

    /// Restores workspaces and everything nested under them, keeping the
    /// workspace IDs so a saved selection can be re-applied.
    func restoreWorkspaces(from snapshots: [WorkspaceSnapshot]) {
        for snapshot in snapshots {
            let url = URL(fileURLWithPath: snapshot.directory).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  Self.isDirectory(url),
                  !workspaces.contains(where: { $0.url == url }) else { continue }
            let workspace = Workspace(id: snapshot.id, url: url)
            workspaces.append(workspace)
            if snapshot.expanded { expandedParents.insert(.workspace(workspace.id)) }
            restoreMarkdownChildren(snapshot.markdownChildren, under: .workspace(workspace.id))
            for terminal in snapshot.terminals {
                guard !terminals.contains(where: { $0.id == terminal.id }) else { continue }
                terminals.append(TerminalTab(id: terminal.id,
                                             parentID: .workspace(workspace.id),
                                             workingDirectory: URL(fileURLWithPath: terminal.directory)))
            }
        }
    }

    /// Restores the Markdown children of a snapshot under `parent`, then
    /// their own nested items, recursively.
    private func restoreMarkdownChildren(_ children: [TabSnapshot], under parent: TabParent) {
        for child in children {
            let url = URL(fileURLWithPath: child.path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path),
                  !documents.contains(where: { $0.url == url }),
                  var nested = makeDocument(for: url) else { continue }
            nested.parentID = parent
            documents.append(nested)
            startWatching(nested)
            LabelStore.shared.register(path: url.path)
            if child.expanded { expandedParents.insert(.document(nested.id)) }
            restoreChildren(of: child, under: .document(nested.id))
        }
    }

    private func restoreChildren(of snapshot: TabSnapshot, under parent: TabParent) {
        restoreMarkdownChildren(snapshot.markdownChildren, under: parent)
        // Web pages only nest under documents.
        if case .document(let docID) = parent {
            for urlString in snapshot.webPageURLs {
                guard let url = URL(string: urlString), url.scheme != nil else { continue }
                let page = LinkedWebPage(parentID: docID, url: url)
                webPages.append(page)
                // Load the page so its text is available to the chat again.
                _ = WebPageSessionManager.shared.session(for: page)
            }
        }
        // Terminals restore as tabs; their processes start lazily when the
        // tab is first shown.
        for terminal in snapshot.terminals ?? [] {
            guard !terminals.contains(where: { $0.id == terminal.id }) else { continue }
            terminals.append(TerminalTab(id: terminal.id,
                                         parentID: parent,
                                         workingDirectory: URL(fileURLWithPath: terminal.directory)))
        }
    }

    /// Restores top-level terminal tabs from their snapshots.
    func restoreTopLevelTerminals(from snapshots: [TerminalTabSnapshot]) {
        for terminal in snapshots {
            guard !terminals.contains(where: { $0.id == terminal.id }) else { continue }
            terminals.append(TerminalTab(id: terminal.id,
                                         parentID: nil,
                                         workingDirectory: URL(fileURLWithPath: terminal.directory)))
        }
    }

    // MARK: - Chat context

    /// Every document nested under `document`, depth-first in open order.
    func nestedDocuments(of document: OpenDocument) -> [OpenDocument] {
        var result: [OpenDocument] = []
        for child in documents where child.parentID == .document(document.id) {
            result.append(child)
            result.append(contentsOf: nestedDocuments(of: child))
        }
        return result
    }

    /// The web pages opened from `document` and from everything nested under
    /// it, in click order.
    func nestedWebPages(of document: OpenDocument) -> [LinkedWebPage] {
        var pages = webPages.filter { $0.parentID == document.id }
        for child in nestedDocuments(of: document) {
            pages.append(contentsOf: webPages.filter { $0.parentID == child.id })
        }
        return pages
    }

    /// The chat context for `document`: files checked in the sidebar, every
    /// Markdown file nested under it, and the cached text of its web pages.
    func chatContextAttachments(for document: OpenDocument) -> [ChatStore.AttachedDocument] {
        var attachments = fileAttachments(for: document)
        for page in nestedWebPages(of: document) {
            appendWebPage(page, to: &attachments)
        }
        return attachments
    }

    /// Like `chatContextAttachments(for:)`, but re-reads each web page from
    /// its browser session first, so the prompt carries the current page
    /// contents rather than what was cached when it last finished loading.
    func refreshedChatContext(for document: OpenDocument) async -> [ChatStore.AttachedDocument] {
        var attachments = fileAttachments(for: document)
        for page in nestedWebPages(of: document) {
            var text = await WebPageSessionManager.shared.session(for: page).currentText()
            if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                text = page.text // fall back to the last extraction
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                attachments.append(ChatStore.AttachedDocument(name: page.title, text: text))
            }
        }
        return attachments
    }

    /// The checked sidebar files plus nested Markdown files, in tab order.
    private func fileAttachments(for document: OpenDocument) -> [ChatStore.AttachedDocument] {
        var attachments = chatContextDocuments(excluding: document).map {
            ChatStore.AttachedDocument(name: $0.fileName, text: draft(for: $0.id) ?? $0.markdown)
        }
        for nested in nestedDocuments(of: document) {
            attachments.append(ChatStore.AttachedDocument(name: nested.fileName,
                                                          text: draft(for: nested.id) ?? nested.markdown))
        }
        return attachments
    }

    private func appendWebPage(_ page: LinkedWebPage, to attachments: inout [ChatStore.AttachedDocument]) {
        guard let text = page.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        attachments.append(ChatStore.AttachedDocument(name: page.title, text: text))
    }

    // MARK: - Workspace chat context

    /// Total character budget for a workspace's chat context, so an enormous
    /// folder cannot flood the prompt. The README is always sent whole.
    static let workspaceContextBudget = 120_000

    /// The chat context for a workspace: its README (as the main document,
    /// via `readmeText`) plus every other Markdown file, open ones using
    /// their latest contents, within a character budget.
    func workspaceChatAttachments(for workspace: Workspace) -> [ChatStore.AttachedDocument] {
        buildWorkspaceAttachments(for: workspace)
    }

    /// The workspace's README contents, used as the chat's main document.
    /// Nil when the folder has none; the chat still works with attachments.
    func readmeText(for workspace: Workspace) -> String? {
        guard let readme = workspace.readme else { return nil }
        if let document = documents.first(where: { $0.url == readme.url }) {
            return draft(for: document.id) ?? document.markdown
        }
        return readMarkdown(at: readme.url)
    }

    private func buildWorkspaceAttachments(for workspace: Workspace) -> [ChatStore.AttachedDocument] {
        var attachments: [ChatStore.AttachedDocument] = []
        var remaining = Self.workspaceContextBudget
        for file in workspace.files {
            guard file.relativePath.lowercased().hasPrefix("readme.") == false else { continue }
            // Open documents use their latest contents (the draft while
            // editing); the rest are read from disk.
            let text: String
            if let document = documents.first(where: { $0.url == file.url }) {
                text = draft(for: document.id) ?? document.markdown
            } else if let contents = readMarkdown(at: file.url) {
                text = contents
            } else {
                continue
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if text.count > remaining {
                guard remaining > 200 else { break }
                attachments.append(ChatStore.AttachedDocument(name: file.relativePath,
                                                              text: String(text.prefix(remaining))))
                remaining = 0
                break
            }
            remaining -= text.count
            attachments.append(ChatStore.AttachedDocument(name: file.relativePath, text: text))
        }
        return attachments
    }

    // MARK: - Navigation

    /// Next/previous move through top-level tabs; nested items are reached
    /// from their parent in the sidebar.
    func selectNext() {
        let tabs = topLevelDocuments
        guard let current = selectedID,
              let index = tabs.firstIndex(where: { $0.id == current }),
              !tabs.isEmpty else {
            selectedID = tabs.first?.id
            return
        }
        selectedID = tabs[(index + 1) % tabs.count].id
    }

    func selectPrevious() {
        let tabs = topLevelDocuments
        guard let current = selectedID,
              let index = tabs.firstIndex(where: { $0.id == current }),
              !tabs.isEmpty else {
            selectedID = tabs.last?.id
            return
        }
        selectedID = tabs[(index - 1 + tabs.count) % tabs.count].id
    }

    // MARK: - Chat context

    /// Whether the file is checked in the sidebar for use as LLM input.
    func isInChatContext(_ path: String) -> Bool {
        chatContextPaths.contains(path)
    }

    /// Checks or unchecks the file as extra input for the LLM.
    func setChatContext(_ path: String, included: Bool) {
        if included {
            chatContextPaths.insert(path)
        } else {
            chatContextPaths.remove(path)
        }
    }

    /// Flips the file's checkbox in the sidebar.
    func toggleChatContext(_ path: String) {
        setChatContext(path, included: !chatContextPaths.contains(path))
    }

    /// The checked documents other than `current`, in tab order: the extra
    /// inputs sent to the model alongside the open document.
    func chatContextDocuments(excluding current: OpenDocument) -> [OpenDocument] {
        documents.filter { $0.id != current.id && chatContextPaths.contains($0.url.path) }
    }

    // MARK: - Reloading

    /// Reloads a document. Skips work when the file is unchanged unless
    /// `force` is set (e.g. a manual refresh button).
    func reload(_ id: OpenDocument.ID, force: Bool = false) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let url = documents[index].url
        let date = modificationDate(of: url)
        if !force, date == documents[index].lastModified { return }
        guard let markdown = readMarkdown(at: url) else { return }
        let wasClean = drafts[id].map { $0 == documents[index].markdown } ?? false
        documents[index].markdown = markdown
        documents[index].html = render(markdown: markdown, baseURL: url.deletingLastPathComponent())
        documents[index].lastModified = date
        documents[index].revision &+= 1
        // A buffer the user has not touched follows the file; a dirty one is
        // kept so typing is never lost to an external change.
        if wasClean { drafts[id] = markdown }
    }

    /// Re-renders every open document with the current view options.
    func rerenderAll() {
        for index in documents.indices {
            let url = documents[index].url
            documents[index].html = render(markdown: documents[index].markdown, baseURL: url.deletingLastPathComponent())
            documents[index].revision &+= 1
        }
    }

    private func render(markdown: String, baseURL: URL?) -> String {
        MarkdownPage.html(markdown: markdown,
                          baseURL: baseURL,
                          contentWidth: options.contentWidth,
                          fontSize: options.fontSize,
                          theme: options.currentTheme)
    }

    /// Manually re-renders a document regardless of the file's modification time.
    func refresh(_ id: OpenDocument.ID) {
        reload(id, force: true)
    }

    /// Manually re-renders the selected document.
    func refreshSelected() {
        guard let selectedID else { return }
        refresh(selectedID)
    }

    // MARK: - Selected-document editing

    var isEditingSelected: Bool {
        selectedID.map { isEditing($0) } ?? false
    }

    /// Whether ⌘S would do anything: a selected document with unsaved edits.
    var canSaveSelected: Bool {
        selectedID.map { isDraftDirty($0) } ?? false
    }

    func editSelected() {
        guard let selectedID else { return }
        beginEditing(selectedID)
    }

    func toggleEditSelected() {
        guard let selectedID else { return }
        toggleEditing(selectedID)
    }

    @discardableResult
    func saveSelected() -> Bool {
        guard let selectedID else { return false }
        return save(selectedID)
    }

    // MARK: - Edit confirmations

    private enum CloseChoice {
        case save, discard, cancel
    }

    /// Asks whether to save before closing a single edited document.
    private func confirmClose(fileName: String) -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(fileName)” before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .cancel
        default: return .discard
        }
    }

    /// Asks whether to save before closing every edited document or quitting.
    private func confirmCloseAll(dirtyCount: Int, quitting: Bool) -> CloseChoice {
        let verb = quitting ? "quitting" : "closing"
        let alert = NSAlert()
        if dirtyCount == 1,
           let document = documents.first(where: { isDraftDirty($0.id) }) {
            alert.messageText = "Save changes to “\(document.fileName)” before \(verb)?"
        } else {
            alert.messageText = "Save changes to \(dirtyCount) files before \(verb)?"
        }
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .cancel
        default: return .discard
        }
    }

    /// Asks whether to discard the unsaved edits of one document.
    private func confirmDiscard(fileName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard changes to “\(fileName)”?"
        alert.informativeText = "Your unsaved changes will be lost."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentSaveError(for document: OpenDocument, underlying: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save “\(document.fileName)”"
        alert.informativeText = underlying.localizedDescription
        alert.runModal()
    }

    // MARK: - Session persistence

    private enum SessionKeys {
        static let saveOnExit = "saveFilesOnExit"
        static let openPaths = "savedOpenFilePaths"
        static let selectedPath = "savedSelectedFilePath"
        static let chatContextPaths = "savedChatContextPaths"
        static let tabTree = "savedTabTree"
        static let selection = "savedTabSelection"
        static let topLevelTerminals = "savedTopLevelTerminals"
        static let workspaces = "savedWorkspaces"
    }

    /// Whether the user wants the set of open files remembered on exit.
    var savesFilesOnExit: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SessionKeys.saveOnExit) != nil else { return true }
        return defaults.bool(forKey: SessionKeys.saveOnExit)
    }

    /// Top-level terminal tabs, in open order. (Nested terminals live inside
    /// the tab tree snapshots.)
    var topLevelTerminals: [TerminalTab] {
        terminals.filter { $0.parentID == nil }
    }

    /// Persists the open tabs — including the links, web pages, and terminals
    /// nested under them, and what was on screen — so they can be restored on
    /// next launch.
    func saveSession() {
        let defaults = UserDefaults.standard
        guard savesFilesOnExit else {
            defaults.removeObject(forKey: SessionKeys.openPaths)
            defaults.removeObject(forKey: SessionKeys.selectedPath)
            defaults.removeObject(forKey: SessionKeys.chatContextPaths)
            defaults.removeObject(forKey: SessionKeys.tabTree)
            defaults.removeObject(forKey: SessionKeys.selection)
            defaults.removeObject(forKey: SessionKeys.topLevelTerminals)
            defaults.removeObject(forKey: SessionKeys.workspaces)
            return
        }
        if let data = try? JSONEncoder().encode(tabSnapshots()) {
            defaults.set(data, forKey: SessionKeys.tabTree)
        }
        let selection = SelectionSnapshot(
            documentPath: selectedDocument?.url.path,
            webPageURL: selectedWebPage?.url.absoluteString,
            terminalID: selectedTerminal?.id,
            workspaceID: selectedWorkspace?.id
        )
        if let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: SessionKeys.selection)
        }
        let terminalSnapshots = topLevelTerminals.map {
            TerminalTabSnapshot(id: $0.id, directory: $0.workingDirectory.path)
        }
        if let data = try? JSONEncoder().encode(terminalSnapshots) {
            defaults.set(data, forKey: SessionKeys.topLevelTerminals)
        }
        if let data = try? JSONEncoder().encode(workspaceSnapshots()) {
            defaults.set(data, forKey: SessionKeys.workspaces)
        }
        // The flat keys stay in sync for versions that predate nesting.
        defaults.set(topLevelDocuments.map { $0.url.path }, forKey: SessionKeys.openPaths)
        defaults.set(selectedDocument?.url.path, forKey: SessionKeys.selectedPath)
        defaults.set(Array(chatContextPaths), forKey: SessionKeys.chatContextPaths)
    }

    /// Reopens the tabs saved by a previous session, respecting the setting.
    /// Restores the nested structure when it was saved; otherwise falls back
    /// to the flat file list older sessions stored.
    func restoreSession() {
        guard savesFilesOnExit else { return }
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: SessionKeys.tabTree),
           let tree = try? JSONDecoder().decode([TabSnapshot].self, from: data),
           !tree.isEmpty {
            restore(from: tree)
            if let data = defaults.data(forKey: SessionKeys.topLevelTerminals),
               let terminalSnapshots = try? JSONDecoder().decode([TerminalTabSnapshot].self, from: data) {
                restoreTopLevelTerminals(from: terminalSnapshots)
            }
            if let data = defaults.data(forKey: SessionKeys.workspaces),
               let workspaceSnapshots = try? JSONDecoder().decode([WorkspaceSnapshot].self, from: data) {
                restoreWorkspaces(from: workspaceSnapshots)
            }
            if let data = defaults.data(forKey: SessionKeys.selection),
               let selection = try? JSONDecoder().decode(SelectionSnapshot.self, from: data) {
                if let path = selection.documentPath,
                   let match = documents.first(where: { $0.url.path == path }) {
                    selectedID = match.id
                }
                if let urlString = selection.webPageURL,
                   let url = URL(string: urlString),
                   let page = webPages.first(where: { $0.url == url }) {
                    selectedWebPageID = page.id
                }
                if let terminalID = selection.terminalID,
                   terminals.contains(where: { $0.id == terminalID }) {
                    selectedTerminalID = terminalID
                }
                // The workspace overview applies last, and only when neither
                // a web page nor a terminal was showing.
                if selection.terminalID == nil, selection.webPageURL == nil,
                   let workspaceID = selection.workspaceID,
                   workspaces.contains(where: { $0.id == workspaceID }) {
                    select(workspaceID: workspaceID)
                }
            }
            // Checks only matter for tabs that actually reopened, so stale paths
            // from files that have since moved or vanished are dropped.
            let checked = Set(defaults.stringArray(forKey: SessionKeys.chatContextPaths) ?? [])
            chatContextPaths = checked.intersection(documents.map(\.url.path))
            return
        }

        guard let paths = defaults.stringArray(forKey: SessionKeys.openPaths), !paths.isEmpty else {
            return
        }
        open(urls: paths.map { URL(fileURLWithPath: $0) })
        if let selectedPath = defaults.string(forKey: SessionKeys.selectedPath),
           let match = documents.first(where: { $0.url.path == selectedPath }) {
            selectedID = match.id
        }
        // Checks only matter for tabs that actually reopened, so stale paths
        // from files that have since moved or vanished are dropped.
        let checked = Set(defaults.stringArray(forKey: SessionKeys.chatContextPaths) ?? [])
        chatContextPaths = checked.intersection(documents.map(\.url.path))
    }

    // MARK: - Watching

    private func startWatching(_ document: OpenDocument) {
        let watcher = FileWatcher(url: document.url) { [weak self] in
            self?.reload(document.id)
        }
        watchers[document.id] = watcher
    }

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: - Drag & drop

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        let type = UTType.fileURL.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                }
                guard let resolved = url else { return }
                lock.lock()
                urls.append(resolved)
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.open(urls: urls)
        }
        return true
    }

    // MARK: - Types

    static let markdownContentTypes: [UTType] = {
        var types: [UTType] = []
        for identifier in ["net.daringfireball.markdown", "public.markdown"] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        if types.isEmpty, let type = UTType(filenameExtension: "md") {
            types.append(type)
        }
        return types
    }()
}
