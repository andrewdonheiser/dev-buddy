import Foundation
import Testing
@testable import MarkdownViewer

extension DocumentStoreSuites {
    @Suite("Nested structure persistence & chat context")
    @MainActor
    struct TabTreePersistenceTests {

        /// Makes a temporary Markdown file the tests can open and link to.
        private func makeTempFile(_ contents: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tree-tests-\(UUID().uuidString).md")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        @Test("snapshots capture the nested structure and restore rebuilds it")
        func snapshotRoundTrip() throws {
            let store = DocumentStore.shared
            let parentURL = try makeTempFile("# Parent")
            let childURL = try makeTempFile("# Child")
            let grandchildURL = try makeTempFile("# Grandchild")
            defer {
                try? FileManager.default.removeItem(at: parentURL)
                try? FileManager.default.removeItem(at: childURL)
                try? FileManager.default.removeItem(at: grandchildURL)
            }

            store.open(url: parentURL)
            let parent = try #require(store.selectedDocument)
            defer { store.closeAll() }

            store.openLink(URL(string: "https://example.com/page")!, in: parent)
            store.openLink(childURL, in: parent)
            let child = try #require(store.documents.first { $0.url.path == childURL.path })
            store.openLink(grandchildURL, in: child) // nesting two levels deep

            #expect(store.documents.count == 3)
            #expect(store.webPages.count == 1)

            let snapshots = store.tabSnapshots()
            #expect(snapshots.count == 1)
            #expect(snapshots[0].path == parentURL.path)
            #expect(snapshots[0].webPageURLs == ["https://example.com/page"])
            #expect(snapshots[0].markdownChildren.count == 1)
            #expect(snapshots[0].markdownChildren[0].path == childURL.path)
            #expect(snapshots[0].markdownChildren[0].markdownChildren.map(\.path) == [grandchildURL.path])

            store.closeAll()
            #expect(store.documents.isEmpty)
            #expect(store.webPages.isEmpty)

            store.restore(from: snapshots)
            #expect(store.documents.count == 3)
            let restoredParent = try #require(store.documents.first { $0.url.path == parentURL.path })
            let restoredChild = try #require(store.documents.first { $0.url.path == childURL.path })
            let restoredGrandchild = try #require(store.documents.first { $0.url.path == grandchildURL.path })
            #expect(restoredChild.parentID == .document(restoredParent.id))
            #expect(restoredGrandchild.parentID == .document(restoredChild.id))
            #expect(store.topLevelDocuments.map(\.id) == [restoredParent.id])

            let restoredPage = try #require(store.webPages.first)
            #expect(restoredPage.parentID == restoredParent.id)
            #expect(restoredPage.url.absoluteString == "https://example.com/page")

            store.closeAll()
        }

        @Test("session save and restore keeps the nested structure and selection")
        func sessionRoundTrip() throws {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: "saveFilesOnExit")
            defer {
                for key in ["saveFilesOnExit", "savedTabTree", "savedTabSelection",
                            "savedOpenFilePaths", "savedSelectedFilePath", "savedChatContextPaths",
                            "savedTopLevelTerminals", "savedWorkspaces"] {
                    defaults.removeObject(forKey: key)
                }
            }

            let store = DocumentStore.shared
            let parentURL = try makeTempFile("# Parent")
            let childURL = try makeTempFile("# Child")
            defer {
                store.closeAll()
                try? FileManager.default.removeItem(at: parentURL)
                try? FileManager.default.removeItem(at: childURL)
            }

            store.open(url: parentURL)
            let parent = try #require(store.selectedDocument)
            let pageURL = URL(string: "https://example.com/session")!
            store.openLink(pageURL, in: parent)
            let page = try #require(store.webPages.first)
            store.openLink(childURL, in: parent)
            // Leave the web page on screen when the session is saved.
            store.select(webPageID: page.id)

            store.saveSession()
            store.closeAll()
            #expect(store.documents.isEmpty)

            store.restoreSession()
            #expect(store.documents.count == 2)
            let restoredParent = try #require(store.documents.first { $0.url.path == parentURL.path })
            let restoredChild = try #require(store.documents.first { $0.url.path == childURL.path })
            #expect(restoredChild.parentID == .document(restoredParent.id))
            let restoredPage = try #require(store.webPages.first)
            #expect(restoredPage.url == pageURL)
            #expect(restoredPage.parentID == restoredParent.id)
            // The web page that was showing is selected again.
            #expect(store.selectedWebPage?.id == restoredPage.id)
            #expect(store.selectedDocument?.id == restoredParent.id)
        }

        @Test("chat context includes nested documents and web page text")
        func chatContextIncludesNestedAndWeb() throws {
            let store = DocumentStore.shared
            let parentURL = try makeTempFile("# Parent")
            let childURL = try makeTempFile("# Child body")
            defer {
                store.closeAll()
                try? FileManager.default.removeItem(at: parentURL)
                try? FileManager.default.removeItem(at: childURL)
            }

            store.open(url: parentURL)
            let parent = try #require(store.selectedDocument)
            store.openLink(childURL, in: parent)
            store.openLink(URL(string: "https://example.com/context")!, in: parent)

            // The browser session reports the page's text.
            let page = try #require(store.webPages.first)
            store.updateWebPageText(id: page.id, text: "Welcome to Example.")

            let attachments = store.chatContextAttachments(for: parent)
            let names = attachments.map(\.name)
            #expect(names.contains(childURL.lastPathComponent))
            #expect(names.contains(page.title))
            let webAttachment = try #require(attachments.first { $0.name == page.title })
            #expect(webAttachment.text == "Welcome to Example.")
            let childAttachment = try #require(attachments.first { $0.name == childURL.lastPathComponent })
            #expect(childAttachment.text.contains("Child body"))

            // A page with no text yet is left out rather than sent empty.
            store.updateWebPageText(id: page.id, text: "")
            #expect(store.webPages.first?.text == "Welcome to Example.") // empty text is ignored
        }
    }
}
