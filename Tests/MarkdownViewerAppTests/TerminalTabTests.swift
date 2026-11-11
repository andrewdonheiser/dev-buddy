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
    /// suites use, so no test touches the shared singleton.
    private func makeStore() -> DocumentStore {
        DocumentStore()
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

        store.selectedID = document.id

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
}
