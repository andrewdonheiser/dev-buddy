import Foundation
import Testing
@testable import MarkdownViewer

@Suite("Terminal tabs")
@MainActor
struct TerminalTabTests {

    /// Makes a temporary Markdown file the tests can open.
    private func makeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tests-\(UUID().uuidString).md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An isolated store per test, mirroring the fixture pattern the other
    /// suites use, so no test touches the shared singleton. Opening a
    /// document registers it with the label store, so the registry persists
    /// to a scratch file instead of the real labels.json.
    private func makeStore() -> DocumentStore {
        let scratchLabels = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-tests-labels-\(UUID().uuidString).json")
        return DocumentStore(labels: LabelStore(storageURL: scratchLabels))
    }

    @Test("terminals open as top-level tabs and close cleanly")
    func terminalLifecycle() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)

        // The terminal opens in the selected document's folder and takes over
        // the detail column without disturbing open documents.
        let terminal = store.openTerminalTab()
        #expect(terminal.workingDirectory == document.url.deletingLastPathComponent())
        #expect(store.selectedTerminal?.id == terminal.id)
        #expect(store.documents.count == 1)

        // A second terminal coexists with the first.
        let second = store.openTerminalTab()
        #expect(store.terminals.map(\.id) == [terminal.id, second.id])
        #expect(store.selectedTerminal?.id == second.id)

        // Titles stream back into the tab list.
        store.updateTerminalTitle(second.id, title: "vim — notes")
        #expect(store.terminals.first { $0.id == second.id }?.title == "vim — notes")

        // Closing the visible terminal returns to the document view.
        store.closeTerminal(second.id)
        #expect(store.selectedTerminal == nil)
        #expect(store.selectedDocument?.id == document.id)
        #expect(!store.terminals.contains { $0.id == second.id })

        store.closeTerminal(terminal.id)
        #expect(store.terminals.isEmpty)
        #expect(store.selectedDocument?.id == document.id)
    }

    @Test("terminals default to the home folder when no document is open")
    func homeFallback() {
        let store = makeStore()
        defer { store.closeAll() }

        let terminal = store.openTerminalTab()

        #expect(terminal.workingDirectory == FileManager.default.homeDirectoryForCurrentUser)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("closing a terminal with no document open falls back to another terminal")
    func fallbackToSiblingTerminal() {
        let store = makeStore()
        defer { store.closeAll() }

        let first = store.openTerminalTab()
        let second = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == second.id)

        store.closeTerminal(second.id)

        #expect(store.selectedTerminal?.id == first.id)
        #expect(store.terminals.map(\.id) == [first.id])
    }

    @Test("closing the last document falls back to an open terminal")
    func fallbackToTerminalAfterLastDocument() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == terminal.id)

        store.close(document.id)

        #expect(store.documents.isEmpty)
        #expect(store.selectedDocument == nil)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("closing the last document keeps the visible terminal selected")
    func closingLastDocumentKeepsVisibleTerminalSelected() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let first = store.openTerminalTab()
        let second = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == second.id)

        store.close(document.id)

        // The fallback to the first terminal must not displace the terminal
        // that is selected and visible.
        #expect(store.documents.isEmpty)
        #expect(store.selectedTerminal?.id == second.id)
        #expect(store.terminals.map(\.id) == [first.id, second.id])
    }

    @Test("closing the selected document keeps the visible terminal on screen")
    func closingDocumentKeepsTerminalVisible() throws {
        let store = makeStore()
        let first = try makeTempFile("# One")
        let second = try makeTempFile("# Two")
        defer { try? FileManager.default.removeItem(at: first) }
        defer { try? FileManager.default.removeItem(at: second) }
        defer { store.closeAll() }

        store.open(urls: [first, second])
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == terminal.id)

        // Closing the selected document re-selects its neighbor without
        // dismissing the visible terminal.
        store.close(document.id)

        #expect(store.documents.count == 1)
        #expect(store.selectedDocument != nil)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("selecting a document leaves the terminal pane")
    func selectingDocumentClearsTerminal() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        store.openTerminalTab()
        #expect(store.selectedTerminal != nil)

        store.selectDocument(document.id)

        #expect(store.selectedTerminal == nil)
        #expect(store.selectedDocument?.id == document.id)
        #expect(store.terminals.count == 1)
    }

    @Test("next and previous tab cycle through documents and terminals")
    func tabCycling() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let first = store.openTerminalTab()
        let second = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == second.id)

        // Documents come first in the open order, then terminals.
        store.selectNext()
        #expect(store.selectedDocument?.id == document.id)
        store.selectNext()
        #expect(store.selectedTerminal?.id == first.id)
        store.selectNext()
        #expect(store.selectedTerminal?.id == second.id)

        // Wrap around both ways.
        store.selectNext()
        #expect(store.selectedDocument?.id == document.id)
        store.selectPrevious()
        #expect(store.selectedTerminal?.id == second.id)
        store.selectPrevious()
        #expect(store.selectedTerminal?.id == first.id)
    }

    @Test("close selected closes the visible terminal first")
    func closeSelectedPrefersTerminal() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        #expect(store.canCloseSelected)

        store.closeSelected()

        #expect(store.terminals.isEmpty)
        #expect(store.selectedTerminal == nil)
        #expect(store.selectedDocument?.id == document.id)
    }

    @Test("closing a terminal without a live process skips the confirmation")
    func closeWithoutLiveProcessClosesImmediately() {
        let store = makeStore()
        defer { store.closeAll() }

        let terminal = store.openTerminalTab()
        store.requestCloseTerminal(terminal.id)

        #expect(store.pendingCloseTerminalID == nil)
        #expect(store.terminals.isEmpty)
        #expect(store.selectedTerminal == nil)
    }

    @Test("closing a terminal with a live process asks for confirmation")
    func closeWithLiveProcessAsksForConfirmation() {
        // Pretend the shell is running so no real process is spawned.
        let store = DocumentStore(hasLiveTerminalProcess: { _ in true })
        defer { store.closeAll() }

        let terminal = store.openTerminalTab()

        store.requestCloseTerminal(terminal.id)

        // The close waits for confirmation instead of killing the shell.
        #expect(store.pendingCloseTerminalID == terminal.id)
        #expect(store.terminals.map(\.id) == [terminal.id])
        #expect(store.selectedTerminal?.id == terminal.id)

        store.confirmCloseTerminal()

        #expect(store.pendingCloseTerminalID == nil)
        #expect(store.terminals.isEmpty)
        #expect(store.selectedTerminal == nil)
    }

    @Test("canceling the close confirmation keeps the terminal open")
    func cancelCloseConfirmationKeepsTerminal() {
        // Pretend the shell is running so no real process is spawned.
        let store = DocumentStore(hasLiveTerminalProcess: { _ in true })
        defer { store.closeAll() }

        let terminal = store.openTerminalTab()

        store.requestCloseTerminal(terminal.id)
        store.cancelCloseTerminal()

        #expect(store.pendingCloseTerminalID == nil)
        #expect(store.terminals.map(\.id) == [terminal.id])
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("close all clears terminals alongside documents")
    func closeAllClearsTerminals() {
        let store = makeStore()

        store.openTerminalTab()
        store.openTerminalTab()
        #expect(store.terminals.count == 2)

        store.closeAll()

        #expect(store.terminals.isEmpty)
        #expect(store.selectedTerminal == nil)
        #expect(store.canCloseSelected == false)
    }

    @Test("selecting an unknown document id is ignored")
    func selectingUnknownDocumentIsIgnored() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        #expect(store.selectedTerminal?.id == terminal.id)

        // An id that is not an open document changes nothing — most
        // importantly, it must not clear the visible terminal, matching
        // `selectTerminal(_: )`'s guard on unknown ids.
        store.selectDocument(UUID())

        #expect(store.selectedDocument?.id == document.id)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("closing every document falls back to an open terminal")
    func closeAllDocumentsFallsBackToTerminal() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let document = try #require(store.selectedDocument)
        let terminal = store.openTerminalTab()
        store.selectDocument(document.id)
        #expect(store.selectedTerminal == nil)

        store.closeAllDocuments()

        #expect(store.documents.isEmpty)
        #expect(store.selectedDocument == nil)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("opening a saved view whose files are gone falls back to the open terminal")
    func savedViewWithMissingFilesFallsBackToTerminal() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let terminal = store.openTerminalTab()

        // The saved view points at files that no longer exist, so no
        // document is restored and the terminal keeps the detail column
        // instead of the empty state.
        let view = SavedView(name: "Gone", paths: [url.path], selectedPath: url.path)
        try FileManager.default.removeItem(at: url)
        store.open(view)

        #expect(store.documents.isEmpty)
        #expect(store.selectedDocument == nil)
        #expect(store.selectedTerminal?.id == terminal.id)
    }

    @Test("opening a saved view keeps terminal tabs and their shells running")
    func openingSavedViewKeepsTerminals() throws {
        let store = makeStore()
        let url = try makeTempFile("# Doc")
        defer { try? FileManager.default.removeItem(at: url) }
        defer { store.closeAll() }

        store.open(url: url)
        let terminal = store.openTerminalTab()
        let view = SavedView(name: "Test", paths: [url.path], selectedPath: url.path)

        store.open(view)

        // The view replaces the document list without terminating the
        // terminal's shell — closing a live shell always asks first.
        #expect(store.documents.count == 1)
        #expect(store.terminals.map(\.id) == [terminal.id])
        #expect(store.selectedDocument?.url.path == url.path)
        #expect(store.selectedTerminal == nil)
    }
}
