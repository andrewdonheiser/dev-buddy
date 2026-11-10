import Foundation
import Testing
@testable import MarkdownViewer

extension DocumentStoreSuites {
    @Suite("Nested links")
    @MainActor
    struct DocumentStoreLinkTests {

        /// Makes a temporary Markdown file the tests can open and link to.
        private func makeTempFile(_ contents: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("link-tests-\(UUID().uuidString).md")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @Test("a web link becomes a nested page under the document")
        func webLinkNests() throws {
            let store = DocumentStore.shared
            let url = try makeTempFile("# Doc")
            defer { try? FileManager.default.removeItem(at: url) }

            store.open(url: url)
            let id = try #require(store.selectedID)
            let document = try #require(store.selectedDocument)
            defer { store.close(id) }

            let link = URL(string: "https://example.com/intro")!
            store.openLink(link, in: document)

            #expect(store.webPages.count == 1)
            let page = try #require(store.selectedWebPage)
            #expect(page.parentID == document.id)
            #expect(page.url == link)
            #expect(store.expandedParents.contains(.document(document.id)))

            // Clicking the same link again selects it rather than duplicating it.
            store.selectDocument(document.id)
            #expect(store.selectedWebPage == nil)
            store.openLink(link, in: document)
            #expect(store.webPages.count == 1)

            store.closeWebPage(id: page.id)
            #expect(store.webPages.isEmpty)
            #expect(store.selectedWebPage == nil)
            #expect(store.selectedDocument?.id == document.id)
        }

        @Test("a markdown link opens as a document nested under its parent")
        func markdownLinkNests() throws {
            let store = DocumentStore.shared
            let parentURL = try makeTempFile("[child](child.md)")
            let childURL = try makeTempFile("# Child")
            // The link must resolve against the parent's directory.
            let realChildURL = parentURL.deletingLastPathComponent()
                .appendingPathComponent("link-tests-child-\(UUID().uuidString).md")
            try FileManager.default.moveItem(at: childURL, to: realChildURL)
            defer {
                try? FileManager.default.removeItem(at: parentURL)
                try? FileManager.default.removeItem(at: realChildURL)
            }

            store.open(url: parentURL)
            let parentID = try #require(store.selectedID)
            let parent = try #require(store.selectedDocument)
            defer { store.close(parentID) }

            store.openLink(realChildURL, in: parent)

            let child = try #require(store.selectedDocument)
            #expect(child.parentID == .document(parent.id))
            #expect(child.url == realChildURL)
            #expect(store.topLevelDocuments.map(\.id) == [parent.id])
            #expect(store.expandedParents.contains(.document(parent.id)))

            // Closing the parent takes its nested children with it.
            store.close(parentID)
            #expect(store.documents.isEmpty)
        }

        @Test("markdown file recognition covers common extensions")
        func markdownExtensions() {
            func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

            #expect(DocumentStore.isMarkdownFile(url("/tmp/readme.md")))
            #expect(DocumentStore.isMarkdownFile(url("/tmp/README.MARKDOWN")))
            #expect(DocumentStore.isMarkdownFile(url("/tmp/notes.mdown")))
            #expect(!DocumentStore.isMarkdownFile(url("/tmp/image.png")))
            #expect(!DocumentStore.isMarkdownFile(url("/tmp/report.pdf")))
        }
    }
}
