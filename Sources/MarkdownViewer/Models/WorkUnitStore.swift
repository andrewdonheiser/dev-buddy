import Foundation

/// Why creating a review failed — each case carries the plain-language reason
/// the wizard shows.
enum ReviewError: LocalizedError, Equatable {
    /// The URL is not a GitHub pull request URL.
    case invalidPullRequestURL
    /// Git could not clone the repository or create the worktree; the
    /// associated value is git's own message.
    case worktreeCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPullRequestURL:
            "That is not a GitHub pull request URL. Use the PR's own address, e.g. https://github.com/owner/repo/pull/123."
        case .worktreeCreationFailed(let message):
            "The pull request could not be checked out into a worktree. \(message)"
        }
    }
}

/// Owns the review work units: creating their git worktrees, tracking the
/// selected unit and archive state, and persisting the unit records so
/// reviews survive relaunches. Worktrees stay on disk until the user deletes
/// the review.
@MainActor
final class WorkUnitStore: ObservableObject {

    static let shared = WorkUnitStore()

    @Published private(set) var units: [WorkUnit] = []
    /// The work unit selected in the sidebar, if any. A selected unit shows
    /// its review overview in the detail column (a selected terminal still
    /// wins the column, exactly as it does over the selected document) and
    /// scopes new terminals to its worktree. Selecting a document or
    /// terminal clears it — `SelectionCoordinator` watches every selection
    /// path, not just sidebar clicks.
    @Published private(set) var selectedWorkUnitID: WorkUnit.ID?

    /// Runs one git command — arguments plus the directory to run it in —
    /// returning its output. Injectable so tests can fake worktree creation
    /// without the network.
    typealias GitRunner = @Sendable ([String], URL?) throws -> String

    private let git: GitRunner
    /// The managed folder every review's worktree lives under.
    private let reviewsDirectory: URL
    /// Where the unit records persist, next to the reviews folder.
    private let storageURL: URL
    private let fileManager = FileManager.default
    private let now: () -> Date

    init(reviewsDirectory: URL = WorkUnitStore.defaultReviewsDirectory,
         git: @escaping GitRunner = { arguments, directory in
             try WorkUnitStore.runGit(arguments, in: directory)
         },
         now: @escaping () -> Date = { Date() }) {
        self.reviewsDirectory = reviewsDirectory
        self.storageURL = reviewsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("reviews.json")
        self.git = git
        self.now = now
        self.units = WorkUnitStore.load(from: storageURL)
    }

    nonisolated static var defaultReviewsDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("Reviews", isDirectory: true)
    }

    // MARK: - Creating reviews

    /// Creates a review work unit for the PR URL: clones the repository and
    /// checks the PR out into a git worktree under the managed reviews
    /// folder, then records and selects the unit. The git commands run off
    /// the main actor so the UI stays responsive while the clone runs.
    @discardableResult
    func createReview(prURLString: String, issueReference: String?) async throws -> WorkUnit {
        guard let pr = PullRequest.parse(url: prURLString) else {
            throw ReviewError.invalidPullRequestURL
        }
        // A unique directory per unit, so the same PR can be reviewed again
        // without colliding with an earlier review's worktree.
        let unitDirectory = reviewsDirectory
            .appendingPathComponent("\(pr.repository)-\(pr.number)-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        let issue = issueReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let runner = git
        let worktree = try await Task.detached(priority: .userInitiated) {
            try WorkUnitStore.createWorktree(for: pr, in: unitDirectory, git: runner)
        }.value
        let unit = WorkUnit(prURL: pr.url,
                            issueReference: (issue?.isEmpty == true) ? nil : issue,
                            title: pr.title,
                            worktreePath: worktree.path,
                            createdAt: now())
        units.append(unit)
        selectedWorkUnitID = unit.id
        persist()
        return unit
    }

    /// Clones `pr`'s repository into `unitDirectory` and checks the PR out
    /// into a `worktree` folder beside the clone. A failed attempt removes
    /// the half-created unit directory so a retry starts fresh.
    nonisolated private static func createWorktree(for pr: PullRequest,
                                                   in unitDirectory: URL,
                                                   git: GitRunner) throws -> URL {
        let repository = unitDirectory.appendingPathComponent("repo", isDirectory: true)
        let worktree = unitDirectory.appendingPathComponent("worktree", isDirectory: true)
        do {
            // Quiet flags keep the pipe small; errors still reach stderr.
            _ = try git(["clone", "--quiet", "--no-checkout", pr.cloneURL.absoluteString,
                         repository.path], nil)
            _ = try git(["fetch", "--quiet", "origin", "pull/\(pr.number)/head"], repository)
            _ = try git(["worktree", "add", worktree.path, "FETCH_HEAD"], repository)
            return worktree
        } catch {
            try? FileManager.default.removeItem(at: unitDirectory)
            throw ReviewError.worktreeCreationFailed(error.localizedDescription)
        }
    }

    /// Runs git, returning its combined output; a nonzero exit throws with
    /// git's own message so failures can be shown to the user.
    nonisolated static func runGit(_ arguments: [String], in directory: URL?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WorkUnitStore.git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    // MARK: - Selection

    var selectedWorkUnit: WorkUnit? {
        units.first { $0.id == selectedWorkUnitID }
    }

    /// Selects a work unit (or nil, clearing the selection); unknown ids are
    /// ignored, mirroring `DocumentStore.selectDocument(_:)`.
    func select(_ id: WorkUnit.ID?) {
        guard id == nil || units.contains(where: { $0.id == id }) else { return }
        selectedWorkUnitID = id
    }

    /// Clears the work unit selection — called when another kind of tab is
    /// selected, the way selecting a document clears the terminal selection.
    /// `SelectionCoordinator` covers the selection paths that do not go
    /// through the sidebar.
    func deselect() {
        selectedWorkUnitID = nil
    }

    /// The work unit new terminals belong to: the selected one, or when a
    /// terminal is showing, the unit that terminal is nested in — the nested
    /// world the user is working in.
    func activeUnit(forSelectedTerminal terminal: TerminalTab?) -> WorkUnit? {
        selectedWorkUnit ?? terminal.flatMap(unit(of:))
    }

    /// The work unit a terminal belongs to, if it is a nested one.
    func unit(of terminal: TerminalTab) -> WorkUnit? {
        guard let id = terminal.workUnitID else { return nil }
        return units.first { $0.id == id }
    }

    // MARK: - Archiving and deleting

    var activeUnits: [WorkUnit] { units.filter { !$0.isArchived } }
    var archivedUnits: [WorkUnit] { units.filter { $0.isArchived } }

    /// Archives the review: it leaves the open list but keeps its worktree
    /// on disk, so the review can be reopened later.
    func archive(_ id: WorkUnit.ID) {
        setArchived(id, date: now())
    }

    /// Returns an archived review to the open list.
    func unarchive(_ id: WorkUnit.ID) {
        setArchived(id, date: nil)
    }

    private func setArchived(_ id: WorkUnit.ID, date: Date?) {
        guard let index = units.firstIndex(where: { $0.id == id }) else { return }
        units[index].archivedAt = date
        if date != nil, selectedWorkUnitID == id { selectedWorkUnitID = nil }
        persist()
    }

    /// Deletes the review's record and its whole unit directory — clone and
    /// worktree — from disk. This is the only path that removes a worktree.
    /// The disk removal happens first and throws on failure with the record
    /// and selection intact, so the failure stays visible in the review's
    /// overview and the delete can be retried; the unit's terminals are the
    /// caller's to close once the removal has succeeded.
    func delete(_ id: WorkUnit.ID) throws {
        guard let index = units.firstIndex(where: { $0.id == id }) else { return }
        let unit = units[index]
        // Only ever remove directories the store manages, whatever the
        // record happens to contain. A directory that is already gone
        // still lets the record be deleted.
        let unitDirectory = unit.worktreeURL.deletingLastPathComponent()
        if unitDirectory.path.hasPrefix(reviewsDirectory.path),
           fileManager.fileExists(atPath: unitDirectory.path) {
            try fileManager.removeItem(at: unitDirectory)
        }
        units.remove(at: index)
        if selectedWorkUnitID == id { selectedWorkUnitID = nil }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try encoder.encode(units).write(to: storageURL, options: .atomic)
        } catch {
            // Persistence is best-effort; in-memory state remains authoritative.
        }
    }

    private static func load(from url: URL) -> [WorkUnit] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WorkUnit].self, from: data)) ?? []
    }
}
