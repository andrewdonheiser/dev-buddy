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
        // Selecting a document always leaves the terminal pane, so the detail
        // column goes back to Markdown.
        didSet {
            selectedTerminalID = nil
        }
    }
    /// The terminal tab shown in the embedded terminal, if any.
    @Published var selectedTerminalID: TerminalTab.ID?
    /// Terminal tabs, in open order.
    @Published private(set) var terminals: [TerminalTab] = []

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

    var selectedTerminal: TerminalTab? {
        guard let selectedTerminalID else { return nil }
        return terminals.first { $0.id == selectedTerminalID }
    }

    // MARK: - Terminal tabs

    /// Selects a terminal tab to show in the terminal pane.
    func select(terminalID: TerminalTab.ID) {
        guard terminals.contains(where: { $0.id == terminalID }) else { return }
        selectedTerminalID = terminalID
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
    func closeTerminal(id: TerminalTab.ID) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals.remove(at: index)
        TerminalSessionManager.shared.removeSession(terminalID: id)
        guard selectedTerminalID == id else { return }
        selectedTerminalID = nil
        // Closing the visible terminal returns to the selected document's
        // view; with no document open, fall back to a neighboring terminal.
        if selectedDocument == nil, !terminals.isEmpty {
            selectedTerminalID = terminals[min(index, terminals.count - 1)].id
        }
    }

    /// Updates a terminal tab's title as the running program reports it.
    func updateTerminalTitle(id: TerminalTab.ID, title: String) {
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
                // one is open.
                selectedTerminalID = terminals.first?.id
            } else {
                let nextIndex = min(index, documents.count - 1)
                selectedID = documents[nextIndex].id
            }
        }
    }

    func closeSelected() {
        // With a terminal on screen, ⌘W closes that first, not its document.
        if let terminalID = selectedTerminalID {
            closeTerminal(id: terminalID)
            return
        }
        guard let selectedID else { return }
        close(selectedID)
    }

    /// Whether ⌘W has anything to close right now.
    var canCloseSelected: Bool {
        selectedID != nil || selectedTerminalID != nil
    }

    /// Closes every open document and terminal.
    func closeAll() {
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        documents = []
        for terminal in terminals {
            TerminalSessionManager.shared.removeSession(terminalID: terminal.id)
        }
        terminals = []
        selectedID = nil
        selectedTerminalID = nil
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

    /// Replaces the tab list with the files stored in a saved view. Files that
    /// no longer exist on disk are skipped.
    func open(_ view: SavedView) {
        closeAll()
        open(urls: view.paths.map { URL(fileURLWithPath: $0) })
        if let selectedPath = view.selectedPath,
           let match = documents.first(where: { $0.url.path == selectedPath }) {
            selectedID = match.id
        }
    }

    // MARK: - Navigation

    /// The index of the selected tab in the open order: documents first,
    /// then terminals.
    private var currentTabIndex: Int? {
        if let selectedID, let index = documents.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        if let selectedTerminalID, let index = terminals.firstIndex(where: { $0.id == selectedTerminalID }) {
            return documents.count + index
        }
        return nil
    }

    private func selectTab(at index: Int) {
        guard index >= 0, index < documents.count + terminals.count else { return }
        if index < documents.count {
            selectedID = documents[index].id
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
            selectedID = match.id
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
