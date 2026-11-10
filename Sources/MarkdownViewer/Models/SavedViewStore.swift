import Foundation

/// A named snapshot of the files open in the tab list.
struct SavedView: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var paths: [String]
    var selectedPath: String?
    /// The full tab tree including nested links and web pages. `nil` in views
    /// saved before nesting existed; those restore as flat tab lists.
    var tree: [TabSnapshot]?
    /// Top-level terminal tabs. Nested terminals live inside `tree`.
    var topLevelTerminals: [TerminalTabSnapshot]?
    /// Workspace tabs and everything nested under them.
    var workspaces: [WorkspaceSnapshot]?
    /// The web page that was showing when the view was saved, if any.
    var selectedWebPageURL: String?
    /// The terminal that was showing when the view was saved, if any.
    var selectedTerminalID: UUID?
    /// The workspace that was showing when the view was saved, if any.
    var selectedWorkspaceID: UUID?

    init(id: UUID = UUID(),
         name: String,
         paths: [String],
         selectedPath: String? = nil,
         tree: [TabSnapshot]? = nil,
         topLevelTerminals: [TerminalTabSnapshot]? = nil,
         workspaces: [WorkspaceSnapshot]? = nil,
         selectedWebPageURL: String? = nil,
         selectedTerminalID: UUID? = nil,
         selectedWorkspaceID: UUID? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.selectedPath = selectedPath
        self.tree = tree
        self.topLevelTerminals = topLevelTerminals
        self.workspaces = workspaces
        self.selectedWebPageURL = selectedWebPageURL
        self.selectedTerminalID = selectedTerminalID
        self.selectedWorkspaceID = selectedWorkspaceID
    }

    /// How many tabs the snapshot stores (files plus workspaces).
    var fileCount: Int { paths.count + (workspaces?.count ?? 0) }
}

/// Owns the named snapshots of the open tab list. State is persisted as JSON
/// in Application Support so saved views survive launches.
@MainActor
final class SavedViewStore: ObservableObject {

    static let shared = SavedViewStore()

    @Published private(set) var views: [SavedView]

    private let storageURL: URL
    private let fileManager = FileManager.default

    init(storageURL: URL = SavedViewStore.defaultStorageURL) {
        self.storageURL = storageURL
        self.views = SavedViewStore.load(from: storageURL)
    }

    nonisolated static var defaultStorageURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("saved-views.json")
    }

    /// Stores a snapshot, replacing any existing view with the same name.
    /// Returns nil when the name is blank or there is nothing to save.
    @discardableResult
    func save(name: String,
              paths: [String],
              selectedPath: String?,
              tree: [TabSnapshot]? = nil,
              topLevelTerminals: [TerminalTabSnapshot]? = nil,
              workspaces: [WorkspaceSnapshot]? = nil,
              selectedWebPageURL: String? = nil,
              selectedTerminalID: UUID? = nil,
              selectedWorkspaceID: UUID? = nil) -> SavedView? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !paths.isEmpty || !(workspaces ?? []).isEmpty else { return nil }
        let view = SavedView(name: trimmed,
                             paths: paths,
                             selectedPath: selectedPath,
                             tree: tree,
                             topLevelTerminals: topLevelTerminals,
                             workspaces: workspaces,
                             selectedWebPageURL: selectedWebPageURL,
                             selectedTerminalID: selectedTerminalID,
                             selectedWorkspaceID: selectedWorkspaceID)
        views.removeAll { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
        views.insert(view, at: 0)
        persist()
        return view
    }

    func delete(id: SavedView.ID) {
        views.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(views).write(to: storageURL, options: .atomic)
        } catch {
            // Persistence is best-effort; in-memory state remains authoritative.
        }
    }

    private static func load(from url: URL) -> [SavedView] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SavedView].self, from: data)) ?? []
    }
}
