import Foundation

/// What a nested tab belongs to: either the document it was opened from, or
/// the workspace it lives under.
enum TabParent: Hashable {
    case document(OpenDocument.ID)
    case workspace(Workspace.ID)
}

/// One Markdown file found inside a workspace folder.
struct WorkspaceFile: Identifiable, Equatable {
    /// The path relative to the workspace folder; unique within it.
    let id: String
    let workspaceID: Workspace.ID
    let url: URL
    let relativePath: String

    var fileName: String { url.lastPathComponent }
}

/// A workspace: a folder on disk presented as a top-level tab whose children
/// are the Markdown files it contains. Files open as documents nested under
/// the workspace, with the full editing / watching / chat machinery.
struct Workspace: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// The Markdown files found in the folder, sorted by relative path.
    var files: [WorkspaceFile]

    /// Caps the scan so an enormous tree cannot flood the sidebar.
    static let fileLimit = 500
    /// Directory names skipped while scanning.
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "dist", "vendor", ".venv"]

    init(id: UUID = UUID(), url: URL, files: [WorkspaceFile]? = nil) {
        self.id = id
        self.url = url
        self.files = files ?? Workspace.scan(directory: url, workspaceID: id)
    }

    /// The folder name, used as the tab label.
    var title: String { url.lastPathComponent }

    /// Re-reads the folder's Markdown files.
    mutating func rescan() {
        files = Workspace.scan(directory: url, workspaceID: id)
    }

    /// Whether the scan hit the file cap (some files may be unlisted).
    var hitFileLimit: Bool { files.count >= Self.fileLimit }

    /// The workspace's README, when one sits at the folder root.
    var readme: WorkspaceFile? {
        files.first {
            $0.relativePath.lowercased().hasPrefix("readme.")
        }
    }

    /// Finds `.md` / `.markdown` files under `directory`, depth-first,
    /// skipping hidden entries and noisy build directories. Sorted by
    /// relative path. The scan caps at `fileLimit` results.
    static func scan(directory: URL, workspaceID: UUID) -> [WorkspaceFile] {
        var results: [WorkspaceFile] = []
        var stack: [(prefix: String, url: URL)] = [("", directory)]
        let manager = FileManager.default

        while let entry = stack.popLast(), results.count < fileLimit {
            let contents = try? manager.contentsOfDirectory(
                at: entry.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for url in contents ?? [] {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let relative = entry.prefix.isEmpty
                    ? url.lastPathComponent
                    : entry.prefix + "/" + url.lastPathComponent
                if isDirectory {
                    guard !skippedDirectories.contains(url.lastPathComponent) else { continue }
                    stack.append((relative, url))
                } else if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                    results.append(WorkspaceFile(id: relative,
                                                 workspaceID: workspaceID,
                                                 url: url,
                                                 relativePath: relative))
                }
            }
        }

        results.sort { $0.relativePath < $1.relativePath }
        return Array(results.prefix(fileLimit))
    }
}
