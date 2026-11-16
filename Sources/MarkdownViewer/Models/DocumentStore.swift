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
    /// The document selected for reading and the chat panel; selecting a
    /// document clears the terminal selection, returning the detail column
    /// to Markdown. Settable only inside the store so the rule cannot be
    /// bypassed from outside.
    @Published private(set) var selectedID: OpenDocument.ID?
    /// The terminal tab shown in the embedded terminal, if any; a visible
    /// terminal takes the detail column over the selected document (which
    /// survives for the chat panel). Settable only inside the store so the
    /// precedence rule cannot be bypassed from outside.
    @Published private(set) var selectedTerminalID: TerminalTab.ID?
    /// Terminal tabs, in open order.
    @Published private(set) var terminals: [TerminalTab] = []
    /// Browser tabs, in open order.
    @Published private(set) var browsers: [BrowserTab] = []
    /// The browser tab shown in the embedded browser pane, if any; a
    /// visible browser takes the detail column just like a visible
    /// terminal does. Settable only inside the store so the precedence
    /// rule cannot be bypassed from outside.
    @Published private(set) var selectedBrowserID: BrowserTab.ID?
    /// The terminal tab whose close is awaiting confirmation, if any.
    @Published private(set) var pendingCloseTerminalID: TerminalTab.ID?

    /// The terminal session seams — liveness probe, teardown, and creation —
    /// injected through the initializer (defaulting to the shared session
    /// manager) so tests can exercise them without spawning real processes.
    typealias LivenessProbe = @MainActor (TerminalTab.ID) -> Bool
    typealias SessionRemover = @MainActor (TerminalTab.ID) -> Void
    typealias SessionProvider = @MainActor (TerminalTab, (@MainActor (String) -> Void)?) -> TerminalSession
    /// The external link opener — the seam link routing uses so tests can
    /// record non-web links (mailto:, etc.) instead of launching system
    /// handlers.
    typealias ExternalLinkOpener = @MainActor (URL) -> Void
    /// The browser session factory, injected so tests can create sessions
    /// without loading real pages.
    typealias BrowserSessionFactory = @MainActor (BrowserTab, (@MainActor (String) -> Void)?) -> BrowserSession

    private let hasLiveTerminalProcess: LivenessProbe
    private let removeTerminalSession: SessionRemover
    private let terminalSessionProvider: SessionProvider
    /// Where links the in-app browser cannot show go (mirroring the web
    /// view's old behavior of handing them to the system).
    private let openExternalURL: ExternalLinkOpener
    /// Creates a browser tab's session on first request.
    private let browserSessionFactory: BrowserSessionFactory
    /// One session per browser tab, for the life of the tab, so pages
    /// survive tab switches.
    private var browserSessions: [BrowserTab.ID: BrowserSession] = [:]

    /// The registry that records the files this store opens; injected so
    /// tests can open documents against a scratch registry.
    private let labels: LabelStore

    private var watchers: [OpenDocument.ID: FileWatcher] = [:]
    private let renderer = HTMLRenderer()
    private let options = ViewOptions.shared
    private var cancellables: Set<AnyCancellable> = []

    /// Internal (not private) so tests can build isolated stores instead of
    /// sharing the singleton, mirroring the other stores' injectable
    /// initializers.
    init(hasLiveTerminalProcess: @escaping LivenessProbe = { TerminalSessionManager.shared.hasLiveProcess($0) },
         removeTerminalSession: @escaping SessionRemover = { TerminalSessionManager.shared.removeSession($0) },
         terminalSessionProvider: @escaping SessionProvider = { TerminalSessionManager.shared.session($0, onTitleChange: $1) },
         openExternalURL: @escaping ExternalLinkOpener = { NSWorkspace.shared.open($0) },
         browserSessionFactory: @escaping BrowserSessionFactory = { browser, onTitleChange in
             BrowserSession(url: browser.url, initialTitle: browser.title, onTitleChange: onTitleChange)
         },
         labels: LabelStore = .shared) {
        self.hasLiveTerminalProcess = hasLiveTerminalProcess
        self.removeTerminalSession = removeTerminalSession
        self.terminalSessionProvider = terminalSessionProvider
        self.openExternalURL = openExternalURL
        self.browserSessionFactory = browserSessionFactory
        self.labels = labels
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

    var selectedBrowser: BrowserTab? {
        guard let selectedBrowserID else { return nil }
        return browsers.first { $0.id == selectedBrowserID }
    }

    /// The document-selection stream, for the cross-store wiring in
    /// `SelectionCoordinator` — selection stays settable only inside the
    /// store, so the coordinator observes instead.
    var documentSelectionUpdates: AnyPublisher<OpenDocument.ID?, Never> {
        $selectedID.eraseToAnyPublisher()
    }

    /// The terminal-selection stream, likewise.
    var terminalSelectionUpdates: AnyPublisher<TerminalTab.ID?, Never> {
        $selectedTerminalID.eraseToAnyPublisher()
    }

    /// The browser-selection stream, likewise.
    var browserSelectionUpdates: AnyPublisher<BrowserTab.ID?, Never> {
        $selectedBrowserID.eraseToAnyPublisher()
    }

    /// Selects a document for reading and the chat panel, returning the
    /// detail column to Markdown — the single place the "selecting a
    /// document leaves the terminal and browser panes" rule lives. Unknown
    /// ids are ignored, mirroring `selectTerminal(_:)`.
    func selectDocument(_ id: OpenDocument.ID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selectedTerminalID = nil
        selectedBrowserID = nil
    }

    // MARK: - Terminal tabs

    /// The terminal tab whose close is awaiting confirmation, if any.
    var pendingCloseTerminal: TerminalTab? {
        guard let pendingCloseTerminalID else { return nil }
        return terminals.first { $0.id == pendingCloseTerminalID }
    }

    /// The tab's terminal session, created (and spawned) on first request
    /// through the injected session seam; the session's title updates stream
    /// back into the tab list. Returns nil for an id that is not an open tab.
    func session(_ id: TerminalTab.ID) -> TerminalSession? {
        guard let terminal = terminals.first(where: { $0.id == id }) else { return nil }
        return terminalSessionProvider(terminal) { [weak self] title in
            self?.updateTerminalTitle(id, title: title)
        }
    }

    /// Selects a terminal tab to show in the terminal pane, taking the
    /// column from a visible browser; selecting a document takes it back.
    func selectTerminal(_ id: TerminalTab.ID) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
        selectedBrowserID = nil
    }

    /// Returns the detail column from the terminal or browser pane without
    /// touching the surviving document selection — the counterpart to
    /// `selectDocument(_:)`'s pane rule, used when a review work unit's
    /// overview takes the column.
    func dismissPanes() {
        selectedTerminalID = nil
        selectedBrowserID = nil
    }

    /// Opens a terminal tab running the user's login shell in `directory`,
    /// nested under the review work unit when one is given.
    @discardableResult
    func openTerminal(in directory: URL, workUnitID: WorkUnit.ID? = nil) -> TerminalTab {
        let terminal = TerminalTab(workingDirectory: directory, workUnitID: workUnitID)
        terminals.append(terminal)
        selectedBrowserID = nil
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

    /// Opens a terminal tab in the active review work unit's worktree — the
    /// selected unit, or the unit the visible terminal belongs to — or, with
    /// no active unit, wherever `openTerminalTab()` would. The single place
    /// the "where a new terminal opens" rule lives; the ⌘T menu item and
    /// the sidebar's New Terminal button both go through it.
    @discardableResult
    func openTerminalInActiveWorkUnit(workUnits: WorkUnitStore) -> TerminalTab {
        if let unit = workUnits.activeUnit(forSelectedTerminal: selectedTerminal) {
            return openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
        }
        return openTerminalTab()
    }

    /// Tooltip text describing where `openTerminalInActiveWorkUnit(workUnits:)`
    /// opens its terminal — the same rule, described once for both callers.
    func newTerminalHelp(workUnits: WorkUnitStore) -> String {
        if let unit = workUnits.activeUnit(forSelectedTerminal: selectedTerminal) {
            return "Open a terminal tab in the \(unit.title) worktree"
        }
        if selectedDocument != nil {
            return "Open a terminal tab in the selected file's folder"
        }
        return "Open a terminal tab in your home folder"
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
        // With no neighboring terminal either, fall back to an open
        // browser tab — the same fallback chain `close(_:)` applies, so
        // the detail column never goes blank while a pane tab is open.
        if selectedDocument == nil && selectedTerminalID == nil && selectedBrowserID == nil {
            selectedBrowserID = browsers.first?.id
        }
    }

    /// Asks to close a terminal tab: closing kills the shell and its child
    /// processes, so a tab with a live process is confirmed first, while one
    /// without (never opened, or already exited) closes immediately.
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

    /// The terminal tabs nested under a review work unit, in open order.
    func terminals(inWorkUnit id: WorkUnit.ID) -> [TerminalTab] {
        terminals.filter { $0.workUnitID == id }
    }

    /// Updates a terminal tab's title as the running program reports it.
    func updateTerminalTitle(_ id: TerminalTab.ID, title: String) {
        guard let index = terminals.firstIndex(where: { $0.id == id }),
              !title.isEmpty, terminals[index].title != title else { return }
        terminals[index].title = title
    }

    // MARK: - Browser tabs

    /// Selects a browser tab to show in the browser pane, taking the column
    /// from a visible terminal; selecting a document or terminal takes it
    /// back.
    func selectBrowser(_ id: BrowserTab.ID) {
        guard browsers.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = nil
        selectedBrowserID = id
    }

    /// Opens a browser tab showing `url`, nested under the review work unit
    /// when one is given; browsers without one appear as top-level tabs.
    @discardableResult
    func openBrowserTab(url: URL, workUnitID: WorkUnit.ID? = nil) -> BrowserTab {
        let browser = BrowserTab(url: url, workUnitID: workUnitID)
        browsers.append(browser)
        selectedTerminalID = nil
        selectedBrowserID = browser.id
        return browser
    }

    /// Opens a link from `document` in an in-app browser tab instead of an
    /// external browser: web pages nest under the document's review work
    /// unit when the document is nested in one, and open top-level
    /// otherwise. Links the browser pane cannot show (mailto:, etc.) still
    /// go to the system handler.
    func openBrowserTab(forLink url: URL, from document: OpenDocument) {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            openBrowserTab(url: url, workUnitID: document.workUnitID)
        } else {
            openExternalURL(url)
        }
    }

    /// Closes a browser tab and releases its web page.
    func closeBrowser(_ id: BrowserTab.ID) {
        guard let index = browsers.firstIndex(where: { $0.id == id }) else { return }
        browsers.remove(at: index)
        browserSessions.removeValue(forKey: id)?.stop()
        guard selectedBrowserID == id else { return }
        selectedBrowserID = nil
        // Closing the visible browser returns to the selected document's
        // view; with no document open, fall back to a neighboring browser.
        if selectedDocument == nil, !browsers.isEmpty {
            selectedBrowserID = browsers[min(index, browsers.count - 1)].id
        }
        // With no neighboring browser either, fall back to an open
        // terminal tab — the same fallback chain `close(_:)` applies, so
        // the detail column never goes blank while a pane tab is open.
        if selectedDocument == nil && selectedBrowserID == nil && selectedTerminalID == nil {
            selectedTerminalID = terminals.first?.id
        }
    }

    /// The browser tabs nested under a review work unit, in open order.
    func browsers(inWorkUnit id: WorkUnit.ID) -> [BrowserTab] {
        browsers.filter { $0.workUnitID == id }
    }

    /// The tab's browser session, created (and loading its page) on first
    /// request; the session's title updates stream back into the tab list.
    /// Returns nil for an id that is not an open tab.
    func browserSession(_ id: BrowserTab.ID) -> BrowserSession? {
        guard let browser = browsers.first(where: { $0.id == id }) else { return nil }
        if let existing = browserSessions[id] { return existing }
        let session = browserSessionFactory(browser) { [weak self] title in
            self?.updateBrowserTitle(id, title: title)
        }
        browserSessions[id] = session
        return session
    }

    /// Updates a browser tab's title as its page reports it.
    func updateBrowserTitle(_ id: BrowserTab.ID, title: String) {
        guard let index = browsers.firstIndex(where: { $0.id == id }),
              !title.isEmpty, browsers[index].title != title else { return }
        browsers[index].title = title
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

    func open(urls: [URL], workUnitID: WorkUnit.ID? = nil) {
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
            guard let document = makeDocument(for: standardized, workUnitID: workUnitID) else { continue }
            documents.append(document)
            selectDocument(document.id)
            startWatching(document)
            labels.register(path: standardized.path)
        }
    }

    func open(url: URL, workUnitID: WorkUnit.ID? = nil) {
        open(urls: [url], workUnitID: workUnitID)
    }

    private func makeDocument(for url: URL, workUnitID: WorkUnit.ID? = nil) -> OpenDocument? {
        guard let markdown = readMarkdown(at: url) else { return nil }
        let html = render(markdown: markdown, baseURL: url.deletingLastPathComponent())
        return OpenDocument(
            url: url,
            markdown: markdown,
            html: html,
            lastModified: modificationDate(of: url),
            workUnitID: workUnitID
        )
    }

    /// The documents nested under a review work unit, in open order.
    func documents(inWorkUnit id: WorkUnit.ID) -> [OpenDocument] {
        documents.filter { $0.workUnitID == id }
    }

    // MARK: - Creating new files

    /// Creates a new Markdown file in `directory` — the first free
    /// "Untitled.md", "Untitled 2.md", … — and opens it as a document
    /// nested under the review work unit when one is given. Returns nil
    /// only when the just-written file could not be opened back.
    @discardableResult
    func openNewMarkdown(in directory: URL, workUnitID: WorkUnit.ID? = nil) throws -> OpenDocument? {
        let url = Self.availableFileURL(baseName: "Untitled", fileExtension: "md", in: directory)
        try "# Untitled\n".write(to: url, atomically: true, encoding: .utf8)
        open(url: url, workUnitID: workUnitID)
        return documents.first { $0.url == url }
    }

    /// The first "Name.md", "Name 2.md", … in `directory` that no file
    /// uses, so repeated creations never collide.
    private static func availableFileURL(baseName: String, fileExtension: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let first = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        if !fileManager.fileExists(atPath: first.path) { return first }
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) \(index).\(fileExtension)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
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
                // one is open, then to a browser tab — without displacing a
                // pane that is already selected and visible.
                if selectedTerminalID == nil && selectedBrowserID == nil {
                    selectedTerminalID = terminals.first?.id
                }
                if selectedTerminalID == nil && selectedBrowserID == nil {
                    selectedBrowserID = browsers.first?.id
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
        // With a terminal on screen, ⌘W closes that first, then a browser —
        // not their document — with the same close confirmation as the
        // terminal's own buttons.
        if let terminalID = selectedTerminalID {
            requestCloseTerminal(terminalID)
            return
        }
        if let browserID = selectedBrowserID {
            closeBrowser(browserID)
            return
        }
        guard let selectedID else { return }
        close(selectedID)
    }

    /// Whether ⌘W has anything to close right now.
    var canCloseSelected: Bool {
        selectedID != nil || selectedTerminalID != nil || selectedBrowserID != nil
    }

    /// The label for the ⌘W command: the visible tab kind it will close.
    var closeSelectedTitle: String {
        if selectedTerminalID != nil { return "Close Terminal" }
        if selectedBrowserID != nil { return "Close Browser" }
        return "Close Tab"
    }

    /// Whether ⌘R has anything to reload right now: it acts on the visible
    /// tab, and a selected terminal or browser takes the detail column
    /// while hiding the document it would reload.
    var canRefreshSelected: Bool {
        selectedTerminalID == nil && selectedBrowserID == nil && selectedID != nil
    }

    /// Closes every open document, keeping terminal tabs (and their running
    /// shells) open; with no document left, the detail column falls back to
    /// an open terminal — the same rule `close(_:)` applies.
    func closeAllDocuments() {
        for watcher in watchers.values { watcher.stop() }
        watchers = [:]
        documents = []
        selectedID = nil
        // The same fallback rule `close(_:)` applies: a visible browser
        // pane keeps the column over the terminal fallback.
        if selectedTerminalID == nil && selectedBrowserID == nil {
            selectedTerminalID = terminals.first?.id
        }
        if selectedTerminalID == nil && selectedBrowserID == nil {
            selectedBrowserID = browsers.first?.id
        }
    }

    /// Closes every open document, terminal and browser.
    func closeAll() {
        closeAllDocuments()
        for terminal in terminals {
            removeTerminalSession(terminal.id)
        }
        terminals = []
        selectedTerminalID = nil
        pendingCloseTerminalID = nil
        for session in browserSessions.values { session.stop() }
        browserSessions = [:]
        browsers = []
        selectedBrowserID = nil
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

    /// Replaces the document tab list with a saved view's files, skipping
    /// files that no longer exist on disk. Terminal tabs stay open: closing
    /// them would terminate their shells without the confirmation every
    /// other close path uses.
    func open(_ view: SavedView) {
        closeAllDocuments()
        open(urls: view.paths.map { URL(fileURLWithPath: $0) })
        if let selectedPath = view.selectedPath,
           let match = documents.first(where: { $0.url.path == selectedPath }) {
            selectDocument(match.id)
        }
    }

    // MARK: - Navigation

    /// The index of the selected tab in the open order (documents first,
    /// then terminals, then browsers); a visible terminal or browser wins
    /// over the surviving document selection, so cycling follows what is on
    /// screen.
    private var currentTabIndex: Int? {
        if let selectedTerminalID, let index = terminals.firstIndex(where: { $0.id == selectedTerminalID }) {
            return documents.count + index
        }
        if let selectedBrowserID, let index = browsers.firstIndex(where: { $0.id == selectedBrowserID }) {
            return documents.count + terminals.count + index
        }
        if let selectedID, let index = documents.firstIndex(where: { $0.id == selectedID }) {
            return index
        }
        return nil
    }

    private func selectTab(at index: Int) {
        let terminalBase = documents.count
        let browserBase = terminalBase + terminals.count
        guard index >= 0, index < browserBase + browsers.count else { return }
        if index < documents.count {
            selectDocument(documents[index].id)
        } else if index < terminalBase + terminals.count {
            selectedBrowserID = nil
            selectedTerminalID = terminals[index - terminalBase].id
        } else {
            selectedTerminalID = nil
            selectedBrowserID = browsers[index - browserBase].id
        }
    }

    func selectNext() {
        let count = documents.count + terminals.count + browsers.count
        guard count > 0 else { return }
        let index = (currentTabIndex ?? -1) + 1
        selectTab(at: index % count)
    }

    func selectPrevious() {
        let count = documents.count + terminals.count + browsers.count
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
