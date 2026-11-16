import Foundation
import Testing
import WebKit
@testable import MarkdownViewer

/// Covers the embedded browser tabs: lifecycle and selection, the nesting
/// rule for links opened from documents, the "New Markdown in Worktree"
/// file creation, and the session cache behind the pane.
@Suite("Browser tabs")
@MainActor
struct BrowserTabTests {

    /// Makes a temporary Markdown file the tests can open.
    private func makeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-tests-\(UUID().uuidString).md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An isolated store per test, mirroring the fixture pattern the other
    /// suites use, so no test touches the shared singleton. Opening a
    /// document registers it with the label store, so the registry persists
    /// to a scratch file instead of the real labels.json.
    private func makeStore() -> DocumentStore {
        let scratchLabels = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-tests-labels-\(UUID().uuidString).json")
        return DocumentStore(labels: LabelStore(storageURL: scratchLabels))
    }

    private func makeURL(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("browser tabs open as panes and close cleanly")
    func browserLifecycle() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)

        // The browser takes the detail column without disturbing open
        // documents — the document survives for the chat panel, exactly as
        // it does behind a terminal.
        let browser = store.openBrowserTab(url: makeURL("https://github.com/owner/repo/pull/1"))
        #expect(store.selectedBrowser?.id == browser.id)
        #expect(store.selectedTerminal == nil)
        #expect(store.selectedDocument?.id == document.id)
        #expect(store.browsers.map(\.id) == [browser.id])

        // A second browser coexists with the first.
        let second = store.openBrowserTab(url: makeURL("https://example.com/page"))
        #expect(store.browsers.map(\.id) == [browser.id, second.id])
        #expect(store.selectedBrowser?.id == second.id)

        // Closing the visible browser returns to the document view.
        store.closeBrowser(second.id)
        #expect(store.selectedBrowser == nil)
        #expect(store.selectedDocument?.id == document.id)
        #expect(!store.browsers.contains { $0.id == second.id })
        #expect(store.canRefreshSelected)
    }

    @Test("closing a browser with no document open falls back to a sibling browser")
    func fallbackToSiblingBrowser() {
        let store = makeStore()
        defer { store.closeAll() }

        let first = store.openBrowserTab(url: makeURL("https://example.com"))
        let second = store.openBrowserTab(url: makeURL("https://example.com/about"))
        #expect(store.selectedBrowser?.id == second.id)

        store.closeBrowser(second.id)

        #expect(store.selectedBrowser?.id == first.id)
        #expect(store.browsers.map(\.id) == [first.id])
    }

    @Test("closing the last browser with no document falls back to an open terminal")
    func closingLastBrowserFallsBackToTerminal() {
        let store = makeStore()
        defer { store.closeAll() }

        let terminal = store.openTerminalTab()
        // Opening the browser takes the column from the terminal.
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        #expect(store.selectedBrowser?.id == browser.id)
        #expect(store.selectedTerminal == nil)

        store.closeBrowser(browser.id)

        // With no documents or sibling browsers, the open terminal takes
        // the column back instead of leaving it blank.
        #expect(store.selectedBrowser == nil)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("closing the last terminal with no document falls back to an open browser")
    func closingLastTerminalFallsBackToBrowser() {
        let store = makeStore()
        defer { store.closeAll() }

        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        let terminal = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == terminal.id)
        #expect(store.selectedBrowser == nil)

        store.closeTerminal(terminal.id)

        // With no documents or sibling terminals, the open browser takes
        // the column back instead of leaving it blank.
        #expect(store.selectedTerminal == nil)
        #expect(store.selectedBrowser?.id == browser.id)
    }

    @Test("closing the last document falls back to an open browser")
    func fallbackToBrowserAfterLastDocument() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        store.selectDocument(document.id)
        #expect(store.selectedBrowser == nil)

        store.close(document.id)

        #expect(store.documents.isEmpty)
        #expect(store.selectedDocument == nil)
        #expect(store.selectedBrowser?.id == browser.id)
    }

    @Test("the terminal and browser panes hand the column to each other")
    func paneSelectionExclusivity() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == terminal.id)

        // Opening and selecting a browser takes the column from a visible
        // terminal; opening a terminal takes it back.
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        #expect(store.selectedTerminal == nil)
        #expect(store.selectedBrowser?.id == browser.id)

        store.selectTerminal(terminal.id)
        #expect(store.selectedBrowser == nil)

        store.selectBrowser(browser.id)
        #expect(store.selectedTerminal == nil)

        // Selecting a document takes the column from both panes.
        store.selectDocument(document.id)
        #expect(store.selectedTerminal == nil)
        #expect(store.selectedBrowser == nil)
        #expect(store.selectedDocument?.id == document.id)

        // Opening a terminal while a browser is visible hands the column
        // to the terminal.
        store.selectBrowser(browser.id)
        _ = store.openTerminalTab()
        #expect(store.selectedBrowser == nil)
        #expect(store.selectedTerminal != nil)
    }

    @Test("closing the last document keeps a visible browser in front of open terminals")
    func closingLastDocumentDoesNotDisplaceVisibleBrowser() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        _ = store.openTerminalTab()
        // Opening the browser takes the column from the terminal; the
        // document stays selected behind it.
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        #expect(store.selectedBrowser?.id == browser.id)
        #expect(store.selectedTerminal == nil)

        store.close(document.id)

        // The terminal fallback must not displace the visible browser, and
        // only one pane selection may be set.
        #expect(store.documents.isEmpty)
        #expect(store.selectedBrowser?.id == browser.id)
        #expect(store.selectedTerminal == nil)
    }

    @Test("closing all documents keeps a visible browser in front of open terminals")
    func closingAllDocumentsDoesNotDisplaceVisibleBrowser() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        _ = store.openTerminalTab()
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        #expect(store.selectedBrowser?.id == browser.id)

        store.closeAllDocuments()

        #expect(store.documents.isEmpty)
        #expect(store.selectedBrowser?.id == browser.id)
        #expect(store.selectedTerminal == nil)
    }

    @Test("browser tabs nest under review work units")
    func browsersNestUnderUnit() {
        let store = makeStore()
        let workUnitID = UUID()
        defer { store.closeAll() }

        let nested = store.openBrowserTab(url: makeURL("https://github.com/owner/repo/pull/1"),
                                           workUnitID: workUnitID)
        let topLevel = store.openBrowserTab(url: makeURL("https://example.com"))

        #expect(nested.workUnitID == workUnitID)
        #expect(topLevel.workUnitID == nil)
        #expect(store.browsers.map(\.id) == [nested.id, topLevel.id])
        #expect(store.browsers(inWorkUnit: workUnitID).map(\.id) == [nested.id])
        #expect(store.browsers(inWorkUnit: UUID()).isEmpty)
    }

    @Test("web links from a document open as browser tabs nested under its unit")
    func linkFromNestedDocumentNestsUnderItsUnit() throws {
        let store = makeStore()
        let workUnitID = UUID()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url, workUnitID: workUnitID)
        let document = try #require(store.selectedDocument)
        #expect(document.workUnitID == workUnitID)

        store.openBrowserTab(forLink: makeURL("https://example.com/page"), from: document)

        #expect(store.browsers.count == 1)
        #expect(store.browsers[0].url == makeURL("https://example.com/page"))
        #expect(store.browsers[0].workUnitID == workUnitID)
        #expect(store.selectedBrowser?.id == store.browsers[0].id)
    }

    @Test("web links from an unnested document open as top-level browser tabs")
    func linkFromTopLevelDocumentOpensTopLevel() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)

        // A selected document clears the work-unit selection, so a link
        // from an unnested doc has no nest to open under — the tab is
        // top-level, still in-app rather than an external browser.
        store.openBrowserTab(forLink: makeURL("http://example.com/insecure"), from: document)

        #expect(store.browsers.count == 1)
        #expect(store.browsers[0].workUnitID == nil)
    }

    @Test("links the browser cannot show still go to the system handler")
    func nonWebLinksGoToSystemHandler() throws {
        var openedExternally: [URL] = []
        let store = DocumentStore(openExternalURL: { url in openedExternally.append(url) },
                                  labels: LabelStore(storageURL: FileManager.default.temporaryDirectory
                                      .appendingPathComponent("browser-tests-labels-\(UUID().uuidString).json")))
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)

        store.openBrowserTab(forLink: makeURL("mailto:someone@example.com"), from: document)

        #expect(openedExternally == [makeURL("mailto:someone@example.com")])
        #expect(store.browsers.isEmpty)
        #expect(store.selectedBrowser == nil)
    }

    @Test("new markdown files are created in the worktree and nest under the unit")
    func newMarkdownNestsUnderUnit() throws {
        let store = makeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-tests-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { store.closeAll() }

        let workUnitID = UUID()
        let document = try #require(try store.openNewMarkdown(in: directory, workUnitID: workUnitID))

        #expect(document.url.lastPathComponent == "Untitled.md")
        #expect(FileManager.default.fileExists(atPath: document.url.path))
        #expect(document.workUnitID == workUnitID)
        #expect(store.documents(inWorkUnit: workUnitID).map(\.id) == [document.id])
        #expect(store.selectedDocument?.id == document.id)

        // A second file never collides with the first.
        let second = try #require(try store.openNewMarkdown(in: directory, workUnitID: workUnitID))
        #expect(second.url.lastPathComponent == "Untitled 2.md")
        #expect(store.documents(inWorkUnit: workUnitID).count == 2)
    }

    @Test("creating a markdown file in a missing directory reports the failure")
    func newMarkdownFailureIsReported() {
        let store = makeStore()
        defer { store.closeAll() }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-tests-missing-\(UUID().uuidString)", isDirectory: true)

        #expect(throws: Error.self) {
            _ = try store.openNewMarkdown(in: missing)
        }
        #expect(store.documents.isEmpty)
    }

    @Test("next and previous tab cycle through documents, terminals and browsers")
    func tabCycling() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        #expect(store.selectedBrowser?.id == browser.id)

        // Documents come first in the open order, then terminals, then
        // browsers.
        store.selectNext()
        #expect(store.selectedDocument?.id == document.id)
        store.selectNext()
        #expect(store.selectedTerminal?.id == terminal.id)
        store.selectNext()
        #expect(store.selectedBrowser?.id == browser.id)

        // Wrap around both ways, through the whole mix.
        store.selectNext()
        #expect(store.selectedDocument?.id == document.id)
        store.selectPrevious()
        #expect(store.selectedBrowser?.id == browser.id)
        store.selectPrevious()
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("close selected closes the visible browser first")
    func closeSelectedPrefersBrowser() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        #expect(store.canCloseSelected)
        #expect(store.closeSelectedTitle == "Close Browser")

        store.closeSelected()

        #expect(store.browsers.isEmpty)
        #expect(store.selectedBrowser == nil)
        #expect(store.selectedDocument?.id == document.id)
        #expect(store.closeSelectedTitle == "Close Tab")
    }

    @Test("⌘R is disabled while a browser tab is visible")
    func canRefreshSelectedDisablesWhileBrowserVisible() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        #expect(store.canRefreshSelected)

        store.openBrowserTab(url: makeURL("https://example.com"))

        // The visible browser hides the document ⌘R would reload, but ⌘W
        // still has the browser to close.
        #expect(!store.canRefreshSelected)
        #expect(store.canCloseSelected)
    }

    @Test("selecting an unknown browser id is ignored")
    func selectingUnknownBrowserIsIgnored() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let terminal = store.openTerminalTab()
        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        store.selectTerminal(terminal.id)
        #expect(store.selectedBrowser == nil)

        // An id that is not an open browser changes nothing — most
        // importantly, it must not clear the visible terminal.
        store.selectBrowser(UUID())

        #expect(store.selectedBrowser == nil)
        #expect(store.selectedTerminal?.id == terminal.id)
        #expect(store.browsers.map(\.id) == [browser.id])
    }

    @Test("close all clears browsers alongside documents and terminals")
    func closeAllClearsBrowsers() {
        let store = makeStore()

        store.openBrowserTab(url: makeURL("https://example.com"))
        store.openBrowserTab(url: makeURL("https://example.com/about"))
        #expect(store.browsers.count == 2)

        store.closeAll()

        #expect(store.browsers.isEmpty)
        #expect(store.selectedBrowser == nil)
        #expect(store.canCloseSelected == false)
    }

    @Test("browser sessions are created once per tab and dropped on close")
    func browserSessionReuse() {
        var created = 0
        let store = DocumentStore(
            browserSessionFactory: { tab, onTitleChange in
                created += 1
                // A blank page keeps the test off the network.
                return BrowserSession(url: URL(string: "about:blank")!,
                               initialTitle: tab.title,
                               onTitleChange: onTitleChange)
            },
            labels: LabelStore(storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-tests-labels-\(UUID().uuidString).json")))
        defer { store.closeAll() }

        // An id that is not an open tab has no session.
        #expect(store.browserSession(UUID()) == nil)

        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        let first = store.browserSession(browser.id)
        let second = store.browserSession(browser.id)

        #expect(first === second)
        #expect(created == 1)

        // Closing the tab drops its session; a fresh tab gets a fresh one.
        store.closeBrowser(browser.id)
        #expect(store.browserSession(browser.id) == nil)
        let reopened = store.openBrowserTab(url: makeURL("https://example.com"))
        _ = store.browserSession(reopened.id)
        #expect(created == 2)
    }

    @Test("page title updates stream back into the browser tab list")
    func titleChangeStreamsIntoTabList() {
        var captured: (@MainActor (String) -> Void)?
        let store = DocumentStore(
            browserSessionFactory: { _, onTitleChange in
                captured = onTitleChange
                return BrowserSession(url: URL(string: "about:blank")!,
                                      initialTitle: "Loading",
                                      onTitleChange: onTitleChange)
            },
            labels: LabelStore(storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("browser-tests-labels-\(UUID().uuidString).json")))
        defer { store.closeAll() }

        let browser = store.openBrowserTab(url: makeURL("https://example.com"))
        _ = store.browserSession(browser.id)

        captured?("Example Domain")

        #expect(store.browsers.first { $0.id == browser.id }?.title == "Example Domain")

        // Empty titles and repeats change nothing.
        captured?("")
        captured?("Example Domain")
        #expect(store.browsers.first { $0.id == browser.id }?.title == "Example Domain")
    }

    // The navigation-failure tests drive the session's WKNavigationDelegate
    // callbacks directly — the same calls WebKit makes — so they stay off
    // the network while covering the published error state.

    @Test("a failed provisional navigation publishes the load error")
    func loadFailureIsPublished() {
        let session = BrowserSession(url: URL(string: "about:blank")!, initialTitle: "Loading")
        defer { session.stop() }

        #expect(session.loadError == nil)

        session.webView(session.view,
                        didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorCannotFindHost,
                                           userInfo: [NSLocalizedDescriptionKey: "The host could not be found"]))

        #expect(session.loadError == "The host could not be found")
    }

    @Test("a failure after commit also publishes the load error")
    func postCommitFailureIsPublished() {
        let session = BrowserSession(url: URL(string: "about:blank")!, initialTitle: "Loading")
        defer { session.stop() }

        session.webView(session.view,
                        didFail: nil,
                        withError: NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorNetworkConnectionLost,
                                           userInfo: [NSLocalizedDescriptionKey: "The connection was lost"]))

        #expect(session.loadError == "The connection was lost")
    }

    @Test("a committed navigation clears the load error")
    func commitClearsLoadError() {
        let session = BrowserSession(url: URL(string: "about:blank")!, initialTitle: "Loading")
        defer { session.stop() }

        session.webView(session.view,
                        didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain,
                                           code: NSURLErrorCannotConnectToHost,
                                           userInfo: [NSLocalizedDescriptionKey: "Could not connect"]))
        #expect(session.loadError != nil)

        session.webView(session.view, didCommit: nil)

        #expect(session.loadError == nil)
    }

    @Test("a cancelled load is not reported as a failure")
    func cancelledLoadIsNotAFailure() {
        let session = BrowserSession(url: URL(string: "about:blank")!, initialTitle: "Loading")
        defer { session.stop() }

        session.webView(session.view,
                        didFailProvisionalNavigation: nil,
                        withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))

        #expect(session.loadError == nil)
    }
}
