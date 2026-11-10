import Foundation
import Testing
@testable import MarkdownViewer

extension DocumentStoreSuites {
    @Suite("Document editing")
    @MainActor
    struct DocumentStoreEditingTests {

        /// Makes a temporary Markdown file the tests can open and overwrite.
        private func makeTempFile(_ contents: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("editing-tests-\(UUID().uuidString).md")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @Test("saving writes the draft to disk and clears the dirty flag")
        func saveWritesDraft() throws {
            let store = DocumentStore.shared
            let url = try makeTempFile("# Original")
            defer { try? FileManager.default.removeItem(at: url) }

            store.open(url: url)
            let id = try #require(store.selectedID)
            defer { store.discardDraft(id); store.close(id) }

            store.beginEditing(id)
            #expect(store.isEditing(id))
            #expect(!store.isDraftDirty(id))
            #expect(store.draft(for: id) == "# Original")

            store.updateDraft(id, text: "# Changed")
            #expect(store.isDraftDirty(id))
            #expect(store.canSaveSelected)

            #expect(store.save(id))
            #expect(try String(contentsOf: url, encoding: .utf8) == "# Changed")
            #expect(!store.isDraftDirty(id))
            // The editor stays open after saving, with the saved text as buffer.
            #expect(store.isEditing(id))
            #expect(store.draft(for: id) == "# Changed")
            #expect(store.selectedDocument?.markdown == "# Changed")
            #expect(store.selectedDocument?.html.contains("Changed") == true)
        }

        @Test("leaving edit mode without changes drops the draft")
        func endEditingClean() throws {
            let store = DocumentStore.shared
            let url = try makeTempFile("# Untouched")
            defer { try? FileManager.default.removeItem(at: url) }

            store.open(url: url)
            let id = try #require(store.selectedID)
            defer { store.discardDraft(id); store.close(id) }

            store.beginEditing(id)
            store.endEditing(id) // clean buffer: no confirmation dialog
            #expect(!store.isEditing(id))

            // Updates after leaving edit mode are ignored.
            store.updateDraft(id, text: "# Ignored")
            #expect(store.draft(for: id) == nil)
            #expect(try String(contentsOf: url, encoding: .utf8) == "# Untouched")
        }

        @Test("editing a file that is not open does nothing")
        func unknownDocument() {
            let store = DocumentStore.shared
            let id = OpenDocument.ID()

            store.beginEditing(id)
            store.updateDraft(id, text: "nope")

            #expect(!store.isEditing(id))
            #expect(store.draft(for: id) == nil)
            #expect(!store.save(id))
            #expect(!store.isDraftDirty(id))
        }

        @Test("quitting is unblocked when no document has unsaved changes")
        func quitClean() throws {
            let store = DocumentStore.shared
            let url = try makeTempFile("# Fine")
            defer { try? FileManager.default.removeItem(at: url) }

            store.open(url: url)
            let id = try #require(store.selectedID)
            defer { store.discardDraft(id); store.close(id) }

            // Untouched buffer, then no buffer at all: neither blocks a quit.
            store.beginEditing(id)
            #expect(store.resolveUnsavedEdits(quitting: true))
            store.discardDraft(id)
            #expect(store.resolveUnsavedEdits(quitting: true))
        }
    }
}
