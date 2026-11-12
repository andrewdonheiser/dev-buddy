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
    /// The document selected for reading and for the chat panel. Selecting a
    /// document through `selectDocument(_:)` clears `selectedTerminalID` —
    /// selecting a document always returns the detail column to Markdown.
    /// Settable only inside the store, so the rule cannot be bypassed by a
    /// direct assignment from outside.
    @Published private(set) var selectedID: OpenDocument.ID?
    /// The terminal tab shown in the embedded terminal, if any. Selection is
    /// a store-level contract with a terminal-over-document precedence: when
    /// both a document and a terminal are selected, the terminal takes the
    /// detail column (matching `MainView` and `currentTabIndex`), while the
    /// document selection survives so the chat panel keeps its context and
    /// `openTerminalTab` still knows the document's folder. Tab order is
    /// documents first, then terminals in open order.
    @Published var selectedTerminalID: TerminalTab.ID?
    /// Terminal tabs, in open order.
    @Published private(set) var terminals: [TerminalTab] = []
    /// The terminal tab whose close is awaiting confirmation, if any.
    @Published private(set) var pendingCloseTerminalID: TerminalTab.ID?

    /// Whether a terminal tab's shell is still running, and the teardown for
    /// a tab's terminal session. Both default to the shared session manager
    /// and are injected through the initializer (mirroring `ChatStore`'s
    /// injected `stream` closure), so every manager access from the store
    /// flows through one seam and tests can exercise the close-confirmation
    /// flow without spawning real processes.
    private let hasLiveTerminalProcess: @MainActor (TerminalTab.ID) -> Bool
    private let removeTerminalSession: @MainActor (TerminalTab.ID) -> Void

    private var watchers: [OpenDocument.ID: FileWatcher] = [:]
    private let renderer = HTMLRenderer()
    private let options = ViewOptions.shared
    private var cancellables: Set<AnyCancellable> = []

    /// Internal (not private) so tests can build isolated stores instead of
    /// sharing the singleton, mirroring the other stores' injectable
    /// initializers.
    init(hasLiveTerminalProcess: @escaping @MainActor (TerminalTab.ID) -> Bool = { TerminalSessionManager.shared.hasLiveProcess($0) },
         removeTerminalSession: @escaping @MainActor (TerminalTab.ID) -> Void = { TerminalSessionManager.shared.removeSession($0) }) {
        self.hasLiveTerminalProcess = hasLiveTerminalProcess
        self.removeTerminalSession = removeTerminalSession
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

    var selectedTerminal: TerminalTab? {
        guard let selectedTerminalID else { return nil }
        return terminals.first { $0.id == selectedTerminalID }
    }

    /// Selects a document for reading and the chat panel, returning the
    /// detail column to Markdown. The single place the "selecting a document
    /// leaves the terminal pane" rule lives; a direct assignment inside the
    /// store (e.g. while re-selecting a neighbor after a close) keeps the
    /// terminal selection untouched.
    func selectDocument(_ id: OpenDocument.ID) {
        selectedID = id
        selectedTerminalID = nil
    }

    // MARK: - Terminal tabs

    /// Selects a terminal tab to show in the terminal pane.
    func selectTerminal(_ id: TerminalTab.ID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
    }

    /// Opens a terminal tab running the user's login shell in `directory`.
    @discardableResult
    func openTerminal(in directory: URL) -> TerminalTab {
        let terminal = TerminalTab(workingDirectory: directory)
        terminals.append(terminal)
        selectedTerminalID = terminal.id
        return terminal
    }

    /// Opens a terminal tab in the selected document's folder (or the home
    /// folder when nothing is open).
    @discardableResult
    func openTerminalTab() -> TerminalTab {
        let directory = selectedDocument?.url.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        return openTerminal(in: directory)
    }

    /// Closes a terminal tab and stops its process.
    func closeTerminal(_ id: TerminalTab.ID) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals.remove(at: index)
        removeTerminalSession(id)
        if pendingCloseTerminalID == id { pendingCloseTerminalID = nil }
        guard selectedTerminalID == id else { return }
        selectedTerminalID = nil
        // Closing the visible terminal returns to the selected document's
        // view; with no document open, fall back to a neighboring terminal.
        if selectedDocument == nil, !terminals.isEmpty {
            selectedTerminalID = terminals[min(index, terminals.count - 1)].id
        }
    }

    /// Asks to close a terminal tab. Closing kills the shell and its child
    /// processes, so a tab with a live process is confirmed first; a tab
    /// without one (never opened, or already exited) closes immediately.
    func requestCloseTerminal(_ id: TerminalTab.ID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        guard hasLiveTerminalProcess(id) else {
            closeTerminal(id)
            return
        }
        pendingCloseTerminalID = id
    }

    /// Closes the terminal tab whose close was confirmed.
    func confirmCloseTerminal() {
        guard let id = pendingCloseTerminalID else { return }
        pendingCloseTerminalID = nil
        closeTerminal(id)
    }

    /// Dismisses the close confirmation without closing anything.
    func cancelCloseTerminal() {
        pendingCloseTerminalID = nil
    }

    /// Updates a terminal tab's title as the running program reports it.
    func updateTerminalTitle(_ id: TerminalTab.ID, title: String) {
        guard let index = terminals.firstIndex(where: { $0.id == id }),
              !title.isEmpty, terminals[index].title != title else { return }
        terminals[index].title = title
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

            if let existing = documents.first(where: { $0.url == standardized }) {
                selectDocument(existing.id)
                reload(existing.id)
                labels.register(path: standardized.path)
                continue
            }
            guard let document = makeDocument(for: standardized) else { continue }
            documents.append(document)
            selectDocument(document.id)
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

    // MARK: - Closing

    func close(_ id: OpenDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        watchers[id]?.stop()
        watchers[id] = nil

        let wasSelected = selectedID == id
        documents.remove(at: index)

        if wasSelected {
            if documents.isEmpty {
                selectedID = nil
                // With no documents left, fall back to a terminal tab when
                // one is open — without displacing a terminal that is
                // already selected and visible.
                if selectedTerminalID == nil {
                    selectedTerminalID = terminals.first?.id
                }
            } else {
                let nextIndex = min(index, documents.count - 1)
                // Re-selecting the neighbor document must not dismiss the
                // terminal pane: selection only clears through
                // `selectDocument(_:)`.
                selectedID = documents[nextIndex].id
            }
        }
    }

    func closeSelected() {
        // With a terminal on screen, ⌘W closes that first, not its document —
        // with the same close confirmation as the terminal's own buttons.
        if let terminalID = selectedTerminalID {
            requestCloseTerminal(terminalID)
            return
        }
        guard let selectedID else { return }
        close(selectedID)
    }

    /// Whether ⌘W has anything to close right now.
    var canCloseSelected: Bool {
        selectedID != nil || selectedTerminalID != nil
    }

    /// Closes every open document, keeping terminal tabs (and their running
    /// shells) open.
    func closeAllDocuments() {
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        documents = []
        selectedID = nil
    }

    /// Closes every open document and terminal.
    func closeAll() {
        closeAllDocuments()
        for terminal in terminals {
            removeTerminalSession(terminal.id)
        }
        terminals = []
        selectedTerminalID = nil
        pendingCloseTerminalID = nil
    }

    // MARK: - Saved views

    /// Snapshots the open tab list into a named, restorable view.
    @discardableResult
    func saveCurrentView(named name: String) -> SavedView? {
        SavedViewStore.shared.save(
            name: name,
            paths: documents.map { $0.url.path },
            selectedPath: selectedDocument?.url.path
        )
    }

    /// Replaces the document tab list with the files stored in a saved view.
    /// Files that no longer exist on disk are skipped. Terminal tabs stay
    /// open: saved views restore documents only, and closing them here would
    /// terminate their shells without the confirmation every other close path
    /// uses.
    func open(_ view: SavedView) {
        closeAllDocuments()
        open(urls: view.paths.map { URL(fileURLWithPath: $0) })
        if let selectedPath = view.selectedPath,
           let match = documents.first(where: { $0.url.path == selectedPath }) {
            selectDocument(match.id)
        }
    }

    // MARK: - Navigation

    /// The index of the selected tab in the open order: documents first,
    /// then terminals. A visible terminal wins over the surviving document
    /// selection, so cycling follows what is on screen.
    private var currentTabIndex: Int? {
        if let selectedTerminalID, let index = terminals.firstIndex(where: { $0.id == selectedTerminalID }) {
            return documents.count + index
        }
        if let selectedID, let index = documents.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return nil
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < documents.count + terminals.count else { return }
        if index < documents.count {
            selectDocument(documents[index].id)
        } else {
            selectedTerminalID = terminals[index - documents.count].id
        }
    }

    func selectNext() {
        let count = documents.count + terminals.count
        guard count > 0 else { return }
        let index = (currentTabIndex ?? -1) + 1
        selectTab(at: index % count)
    }

    func selectPrevious() {
        let count = documents.count + terminals.count
        guard count > 0 else { return }
        let index = (currentTabIndex ?? count) - 1
        selectTab(at: (index + count) % count)
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
        documents[index].markdown = markdown
        documents[index].html = render(markdown: markdown, baseURL: url.deletingLastPathComponent())
        documents[index].lastModified = date
        documents[index].revision &+= 1
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

    // MARK: - Session persistence

    private enum SessionKeys {
        static let saveOnExit = "saveFilesOnExit"
        static let openPaths = "savedOpenFilePaths"
        static let selectedPath = "savedSelectedFilePath"
    }

    /// Whether the user wants the set of open files remembered on exit.
    var savesFilesOnExit: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SessionKeys.saveOnExit) != nil else { return true }
        return defaults.bool(forKey: SessionKeys.saveOnExit)
    }

    /// Persists the currently open files so they can be restored on next launch.
    func saveSession() {
        let defaults = UserDefaults.standard
        guard savesFilesOnExit else {
            defaults.removeObject(forKey: SessionKeys.openPaths)
            defaults.removeObject(forKey: SessionKeys.selectedPath)
            return
        }
        defaults.set(documents.map { $0.url.path }, forKey: SessionKeys.openPaths)
        defaults.set(selectedDocument?.url.path, forKey: SessionKeys.selectedPath)
    }

    /// Reopens the files saved by a previous session, respecting the setting.
    func restoreSession() {
        guard savesFilesOnExit else { return }
        let defaults = UserDefaults.standard
        guard let paths = defaults.stringArray(forKey: SessionKeys.openPaths), !paths.isEmpty else {
            return
        }
        open(urls: paths.map { URL(fileURLWithPath: $0) })
        if let selectedPath = defaults.string(forKey: SessionKeys.selectedPath),
           let match = documents.first(where: { $0.url.path == selectedPath }) {
            selectDocument(match.id)
        }
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
