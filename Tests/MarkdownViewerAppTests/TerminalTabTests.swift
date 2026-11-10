import Foundation
import Testing
@testable import MarkdownViewer

extension DocumentStoreSuites {
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

        @Test("terminals open top-level and nested, and close cleanly")
        func terminalLifecycle() throws {
            let store = DocumentStore.shared
            let url = try makeTempFile("# Doc")
            defer { try? FileManager.default.removeItem(at: url) }

            store.open(url: url)
            let document = try #require(store.selectedDocument)
            defer { store.closeAll() }

            // Nested under a document.
            let nested = store.openTerminal(in: url.deletingLastPathComponent(),
                                            parent: .document(document.id))
            #expect(nested.parentID == .document(document.id))
            #expect(store.selectedTerminal?.id == nested.id)
            #expect(store.expandedParents.contains(.document(document.id)))
            // Selecting the terminal keeps the chat anchored to its parent.
            #expect(store.selectedDocument?.id == document.id)

            // Top-level.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let top = store.openTerminal(in: home)
            #expect(top.parentID == nil)
            #expect(store.selectedTerminal?.id == top.id)
            #expect(store.topLevelTerminals.map(\.id) == [top.id])

            // Titles stream back into the store.
            store.updateTerminalTitle(id: top.id, title: "opencode — project")
            #expect(store.terminals.first { $0.id == top.id }?.title == "opencode — project")

            // Closing the visible terminal returns to the document view.
            store.closeTerminal(id: top.id)
            #expect(store.selectedTerminal == nil)
            #expect(!store.terminals.contains { $0.id == top.id })

            // Closing the document takes its nested terminal with it.
            store.closeTerminal(id: nested.id) // clean up the selection first
            store.openTerminal(in: url.deletingLastPathComponent(), parent: .document(document.id))
            store.selectDocument(document.id)
            store.close(document.id)
            #expect(store.terminals.isEmpty)
        }

        @Test("terminal tabs persist in snapshots and restore with their IDs")
        func terminalPersistence() throws {
            let store = DocumentStore.shared
            let url = try makeTempFile("# Doc")
            defer { try? FileManager.default.removeItem(at: url) }

            store.open(url: url)
            let document = try #require(store.selectedDocument)
            defer { store.closeAll() }

            let nested = store.openTerminal(in: url.deletingLastPathComponent(),
                                            parent: .document(document.id))
            let top = store.openTerminal(in: FileManager.default.homeDirectoryForCurrentUser)
            store.select(terminalID: nested.id)

            let snapshots = store.tabSnapshots()
            #expect(snapshots.count == 1)
            #expect(snapshots[0].terminals?.map(\.id) == [nested.id])
            #expect(snapshots[0].terminals?.map(\.directory) == [url.deletingLastPathComponent().path])
            let topSnapshots = store.topLevelTerminals.map {
                TerminalTabSnapshot(id: $0.id, directory: $0.workingDirectory.path)
            }
            #expect(topSnapshots.map(\.id) == [top.id])

            store.closeAll()
            #expect(store.terminals.isEmpty)

            // Restore the tree plus the top-level terminals, then the selection.
            store.restore(from: snapshots)
            store.restoreTopLevelTerminals(from: topSnapshots)
            #expect(store.terminals.count == 2)
            let restoredNested = try #require(store.terminals.first { $0.id == nested.id })
            let restoredParentID = store.topLevelDocuments.first?.id
            #expect(restoredNested.parentID == .document(document.id)
                    || restoredNested.parentID == restoredParentID.map { .document($0) })
            #expect(store.terminals.first { $0.id == top.id }?.parentID == nil)
            // The persisted selection points at the restored tab by ID.
            store.select(terminalID: nested.id)
            #expect(store.selectedTerminal?.id == nested.id)

            store.closeAll()
        }
    }
}
