import Foundation
import Testing
@testable import MarkdownViewer

extension DocumentStoreSuites {
    @Suite("Workspaces")
    @MainActor
    struct WorkspaceTests {

        /// Makes a temporary folder the tests can use as a workspace.
        private func makeTempDirectory() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("workspace-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @discardableResult
        private func write(_ contents: String, relativePath: String, in directory: URL) throws -> URL {
            let url = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        private func workspaceID(of target: DocumentStore.ChatTarget?) -> Workspace.ID? {
            if case .workspace(let workspace)? = target { return workspace.id }
            return nil
        }

        private func documentID(of target: DocumentStore.ChatTarget?) -> OpenDocument.ID? {
            if case .document(let document)? = target { return document.id }
            return nil
        }

        @Test("scan finds markdown files recursively, skipping hidden and build directories")
        func scanBehavior() throws {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            try write("# Top", relativePath: "README.md", in: directory)
            try write("# Guide", relativePath: "docs/guide.md", in: directory)
            try write("# Deep", relativePath: "docs/nested/deep.md", in: directory)
            try write("# Skipped", relativePath: "node_modules/skip.md", in: directory)
            try write("# Skipped", relativePath: ".git/description.md", in: directory)
            try write("not markdown", relativePath: "docs/notes.txt", in: directory)

            let id = UUID()
            let files = Workspace.scan(directory: directory, workspaceID: id)

            #expect(files.map(\.relativePath) == ["README.md", "docs/guide.md", "docs/nested/deep.md"])
            #expect(files.allSatisfy { $0.workspaceID == id })
            #expect(files.allSatisfy { $0.id == $0.relativePath })
            // Directory enumeration resolves firmlinks (/var → /private/var)
            // so the URL form differs from the folder's; the relative path is
            // the stable way to tie a file to its workspace.
            #expect(files.allSatisfy { $0.url.path.hasSuffix("/" + $0.relativePath) })

            // The workspace re-keys the scan to its own ID.
            let workspace = Workspace(url: directory)
            #expect(workspace.files.map(\.relativePath) == ["README.md", "docs/guide.md", "docs/nested/deep.md"])
            #expect(workspace.files.allSatisfy { $0.workspaceID == workspace.id })
            #expect(workspace.readme?.relativePath == "README.md")
            #expect(workspace.title == directory.lastPathComponent)
        }

        @Test("scan caps the file list at the limit")
        func scanCap() throws {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            for index in 0..<(Workspace.fileLimit + 10) {
                try write("# \(index)", relativePath: "file-\(index).md", in: directory)
            }

            let workspace = Workspace(url: directory)
            #expect(workspace.files.count == Workspace.fileLimit)
            #expect(workspace.hitFileLimit)
        }

        @Test("opening a folder creates a workspace tab; opening it again focuses it")
        func openWorkspaceTab() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Hello", relativePath: "hello.md", in: directory)
            defer {
                store.closeAll()
                try? FileManager.default.removeItem(at: directory)
            }

            // Folder URLs routed through open(urls:) become workspaces (this is
            // the drag & drop / Finder path).
            store.open(urls: [directory])
            let workspace = try #require(store.selectedWorkspace)
            #expect(workspace.url == directory)
            #expect(store.selectedID == nil) // the overview is showing, not a doc
            #expect(workspaceID(of: store.chatTarget) == workspace.id)

            // Selecting a document leaves the overview.
            let docURL = try write("# Outside", relativePath: "outside-\(UUID().uuidString).md",
                                   in: FileManager.default.temporaryDirectory)
            store.open(url: docURL)
            #expect(store.selectedWorkspace == nil)
            try? FileManager.default.removeItem(at: docURL)

            // Opening the same folder again focuses the existing workspace.
            store.select(workspaceID: workspace.id)
            store.openWorkspace(url: directory)
            #expect(store.workspaces.count == 1)
            #expect(store.selectedWorkspace?.id == workspace.id)
        }

        @Test("workspace files open as documents nested under the workspace")
        func filesNestUnderWorkspace() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Root", relativePath: "README.md", in: directory)
            let guideURL = try write("# Guide", relativePath: "docs/guide.md", in: directory)
            defer {
                store.closeAll()
                try? FileManager.default.removeItem(at: directory)
            }

            let workspace = store.openWorkspace(url: directory)
            // Open through the workspace's own file record, as the sidebar
            // and overview do.
            let file = try #require(workspace.files.first { $0.relativePath == "docs/guide.md" })
            let document = try #require(store.openFile(file))

            #expect(document.parentID == .workspace(workspace.id))
            #expect(store.selectedDocument?.id == document.id)
            #expect(store.selectedWorkspace == nil) // the document took over
            #expect(store.expandedParents.contains(.workspace(workspace.id)))
            #expect(store.topLevelDocuments.isEmpty) // it nests, not top-level

            // The chat rebinds to the document.
            #expect(documentID(of: store.chatTarget) == document.id)
        }

        @Test("a terminal opened from a workspace runs in the workspace folder")
        func workspaceTerminalCWD() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Root", relativePath: "README.md", in: directory)
            defer {
                store.closeAll()
                try? FileManager.default.removeItem(at: directory)
            }

            let workspace = store.openWorkspace(url: directory)
            let terminal = store.openTerminal(in: workspace)

            #expect(terminal.parentID == .workspace(workspace.id))
            #expect(terminal.workingDirectory == workspace.url) // opencode's cwd
            #expect(store.selectedTerminal?.id == terminal.id)
            // The chat follows the workspace, not a document.
            #expect(workspaceID(of: store.chatTarget) == workspace.id)
            #expect(store.selectedDocument == nil)
        }

        @Test("closing a workspace cascades to its documents and terminals")
        func closeCascades() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Root", relativePath: "README.md", in: directory)
            let guideURL = try write("# Guide", relativePath: "docs/guide.md", in: directory)
            defer { try? FileManager.default.removeItem(at: directory) }

            let workspace = store.openWorkspace(url: directory)
            _ = try #require(store.openFile(guideURL, in: workspace))
            _ = store.openTerminal(in: workspace)
            #expect(store.documents.count == 1)
            #expect(store.terminals.count == 1)

            store.close(workspaceID: workspace.id)
            #expect(store.workspaces.isEmpty)
            #expect(store.documents.isEmpty)
            #expect(store.terminals.isEmpty)
            #expect(store.selectedWorkspace == nil)
            #expect(!store.expandedParents.contains(.workspace(workspace.id)))
        }

        @Test("workspace snapshots round-trip with stable IDs and children")
        func snapshotRoundTrip() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Root", relativePath: "README.md", in: directory)
            let guideURL = try write("# Guide", relativePath: "docs/guide.md", in: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            defer { store.closeAll() }

            let workspace = store.openWorkspace(url: directory)
            _ = try #require(store.openFile(guideURL, in: workspace))
            let terminal = store.openTerminal(in: workspace)
            store.select(workspaceID: workspace.id)
            #expect(store.expandedParents.contains(.workspace(workspace.id)))

            let snapshots = store.workspaceSnapshots()
            #expect(snapshots.count == 1)
            #expect(snapshots[0].id == workspace.id)
            #expect(snapshots[0].directory == directory.path)
            #expect(snapshots[0].expanded)
            #expect(snapshots[0].markdownChildren.map(\.path) == [guideURL.path])
            #expect(snapshots[0].terminals.map(\.id) == [terminal.id])

            store.closeAll()
            #expect(store.workspaces.isEmpty)

            store.restoreWorkspaces(from: snapshots)
            let restored = try #require(store.workspaces.first)
            #expect(restored.id == workspace.id) // stable across restores
            #expect(restored.files.contains { $0.relativePath == "docs/guide.md" })
            let restoredDoc = try #require(store.documents.first { $0.url.path == guideURL.path })
            #expect(restoredDoc.parentID == .workspace(restored.id))
            #expect(store.terminals.first?.parentID == .workspace(restored.id))
            #expect(store.terminals.first?.workingDirectory == directory)

            // The saved selection re-applies by ID.
            store.select(workspaceID: restored.id)
            #expect(store.selectedWorkspace?.id == restored.id)
        }

        @Test("workspace chat context carries the README and other files within budget")
        func workspaceChatContext() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Project\n\nThe readme.", relativePath: "README.md", in: directory)
            try write("# A\n\nfile-a", relativePath: "a.md", in: directory)
            try write("# B\n\nfile-b", relativePath: "sub/b.md", in: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            defer { store.closeAll() }

            let workspace = store.openWorkspace(url: directory)
            let attachments = store.workspaceChatAttachments(for: workspace)
            #expect(attachments.map(\.name) == ["a.md", "sub/b.md"]) // README is separate
            #expect(attachments.allSatisfy { !$0.text.isEmpty })
            #expect(store.readmeText(for: workspace)?.contains("The readme.") == true)
        }

        @Test("rescan picks up files added after the workspace opened")
        func rescan() throws {
            let store = DocumentStore.shared
            let directory = try makeTempDirectory()
            try write("# Root", relativePath: "README.md", in: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            defer { store.closeAll() }

            let workspace = store.openWorkspace(url: directory)
            #expect(workspace.files.count == 1)

            try write("# New", relativePath: "new.md", in: directory)
            store.rescanWorkspace(id: workspace.id)
            let rescanned = try #require(store.workspaces.first { $0.id == workspace.id })
            #expect(rescanned.files.map(\.relativePath) == ["README.md", "new.md"])
        }
    }
}
