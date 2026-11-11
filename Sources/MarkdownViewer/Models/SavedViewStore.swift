import Foundation

/// A named snapshot of the files open in the tab list.
struct SavedView: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var paths: [String]
    var selectedPath: String?

    init(id: UUID = UUID(), name: String, paths: [String], selectedPath: String? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.selectedPath = selectedPath
    }

    /// How many files the snapshot stores.
    var fileCount: Int { paths.count }
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
    func save(name: String, paths: [String], selectedPath: String?) -> SavedView? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !paths.isEmpty else { return nil }
        let view = SavedView(name: trimmed, paths: paths, selectedPath: selectedPath)
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
