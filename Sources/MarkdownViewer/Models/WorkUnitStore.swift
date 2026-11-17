import Foundation

/// Why creating a review failed — each case carries the plain-language reason
/// the wizard shows.
enum ReviewError: LocalizedError, Equatable {
    /// The URL is not a GitHub pull request URL.
    case invalidPullRequestURL
    /// Git could not clone the repository or create the worktree; the
    /// associated value is git's own message.
    case worktreeCreationFailed(String)
    /// A raw git command failed; the values are its exit status and its
    /// combined output, shown to the user verbatim.
    case gitFailed(exitStatus: Int, output: String)

    var errorDescription: String? {
        switch self {
        case .invalidPullRequestURL:
            "That is not a GitHub pull request URL. Use the PR's own address, e.g. https://github.com/owner/repo/pull/123."
        case .worktreeCreationFailed(let message):
            "The pull request could not be checked out into a worktree. \(message)"
        case .gitFailed(let exitStatus, let output):
            "A git command failed (exit status \(exitStatus)). \(output)"
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
    /// Why the saved review records could not be loaded, if they could not:
    /// the user needs to know their reviews were not read and that the
    /// unreadable file was kept on disk rather than replaced.
    @Published private(set) var loadFailure: String?
    /// Why the review records could not be saved, if a save failed: the
    /// user needs to know their reviews will not survive a relaunch even
    /// though they remain open now.
    @Published private(set) var saveFailure: String?

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
    /// True while an unreadable record file that could not be rotated
    /// aside is still in place: writing a new one would destroy it, so
    /// persistence stays withheld. Re-checked on every save, so resolving
    /// the file resumes saving without a relaunch.
    private var persistenceWithheld: Bool

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
        let records = WorkUnitStore.load(from: storageURL)
        self.units = records.units
        self.loadFailure = records.failure
        self.persistenceWithheld = records.unreadableFileWasLeftInPlace
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
        // without colliding with an earlier review's worktree. The
        // repository slug's "/" is flattened to "-" so each unit is a
        // single component under Reviews (a nested one would leave an
        // empty owner folder behind on delete); `parse(url:)` has already
        // constrained the slug to filesystem-safe characters.
        let unitDirectory = reviewsDirectory
            .appendingPathComponent("\(pr.repository.replacingOccurrences(of: "/", with: "-"))-\(pr.number)-\(UUID().uuidString.prefix(8))",
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
        } catch let error as ReviewError {
            // A typed git failure already carries its user-facing message.
            try? FileManager.default.removeItem(at: unitDirectory)
            throw error
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
            throw ReviewError.gitFailed(exitStatus: Int(process.terminationStatus), output: output)
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
        return unit(id)
    }

    /// The work unit with the given id, if it is still recorded.
    func unit(_ id: WorkUnit.ID) -> WorkUnit? {
        units.first { $0.id == id }
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
        if isManagedUnitDirectory(unitDirectory),
           fileManager.fileExists(atPath: unitDirectory.path) {
            try fileManager.removeItem(at: unitDirectory)
        }
        units.remove(at: index)
        if selectedWorkUnitID == id { selectedWorkUnitID = nil }
        persist()
    }

    /// Whether `directory` is one this store may remove: a direct child of
    /// the managed reviews folder whose name createReview generated — or,
    /// for units created before the slug was flattened, the generated
    /// folder inside its owner folder. Records can be tampered with, so
    /// the shape on disk, not the record, decides what delete removes.
    private func isManagedUnitDirectory(_ directory: URL) -> Bool {
        let reviewsPath = reviewsDirectory.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        // Containment with a component boundary, so a sibling sharing the
        // prefix (Reviews-backup) does not match.
        guard directoryPath.hasPrefix(reviewsPath + "/") else { return false }
        let components = directoryPath.dropFirst(reviewsPath.count + 1)
            .split(separator: "/")
        switch components.count {
        case 1:
            return Self.isGeneratedUnitDirectoryName(String(components[0]))
        case 2:
            // The legacy layout: <owner>/<repo>-<number>-<id>, from before
            // the slug's slash was flattened into the name — the slash in
            // "owner/repo" became a path separator, so the inner component
            // carries only the repository name.
            return PullRequest.isValidName(String(components[0]))
                && Self.isLegacyUnitDirectoryName(String(components[1]))
        default:
            return false
        }
    }

    /// Whether `name` matches the `<slug>-<number>-<uuid prefix>` shape
    /// createReview generates, e.g. `owner-repo-12-1A2B3C4D`.
    nonisolated static func isGeneratedUnitDirectoryName(_ name: String) -> Bool {
        isUnitTailName(name, minimumParts: 4)
    }

    /// Whether `name` matches the inner component of the pre-flattening
    /// layout, `<repo>-<number>-<uuid prefix>` — e.g. `repo-12-1A2B3C4D`,
    /// with no owner prefix, so one dash fewer than the current shape.
    nonisolated static func isLegacyUnitDirectoryName(_ name: String) -> Bool {
        isUnitTailName(name, minimumParts: 3)
    }

    /// The shared tail of both generated shapes: a positive PR number
    /// followed by an 8-character hex uuid prefix, with at least
    /// `minimumParts` dash-separated components before them.
    private nonisolated static func isUnitTailName(_ name: String, minimumParts: Int) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count >= minimumParts,
              let number = Int(parts[parts.count - 2]), number > 0 else { return false }
        let uuidPrefix = parts[parts.count - 1]
        return uuidPrefix.count == 8 && uuidPrefix.allSatisfy(\.isHexDigit)
    }

    // MARK: - Persistence

    private func persist() {
        // An unreadable record file that could not be rotated aside must
        // not be overwritten — but the user may resolve it while the app
        // runs, so every save re-checks instead of staying withheld for
        // the whole session.
        if persistenceWithheld {
            retryReadingWithheldRecords()
        }
        guard !persistenceWithheld else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try encoder.encode(units).write(to: storageURL, options: .atomic)
            saveFailure = nil
        } catch {
            // In-memory state remains authoritative, but a user whose
            // reviews silently stop being saved gets no signal — report
            // it the way load failures are reported.
            saveFailure = "Reviews could not be saved: \(error.localizedDescription) They remain open, but will not be restored on relaunch until saving works."
        }
    }

    /// Re-reads the record file that blocked persistence: the user may
    /// have removed or repaired it while the app was running. A file that
    /// is gone, or that can now be read, unblocks persistence — and units
    /// recovered from a repaired file join the in-memory list instead of
    /// being overwritten by it.
    private func retryReadingWithheldRecords() {
        let records = Self.load(from: storageURL)
        persistenceWithheld = records.unreadableFileWasLeftInPlace
        loadFailure = records.failure
        guard !persistenceWithheld else { return }
        let known = Set(units.map(\.id))
        for unit in records.units where !known.contains(unit.id) {
            units.append(unit)
        }
    }

    /// What `load(from:)` read: the units, and when the record file could
    /// not be decoded, the failure to show the user and whether the
    /// unreadable file had to be left in place (so it must not be
    /// overwritten).
    private struct LoadedRecords {
        var units: [WorkUnit] = []
        var failure: String?
        var unreadableFileWasLeftInPlace = false
    }

    private static func load(from url: URL) -> LoadedRecords {
        let fileManager = FileManager.default
        // A missing file is an empty store; an existing file that cannot
        // be read is not — overwriting it would destroy whatever it
        // holds, so it goes through the same rotate-aside path as an
        // undecodable one.
        guard fileManager.fileExists(atPath: url.path) else { return LoadedRecords() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return Self.setAsideUnreadableRecords(at: url, fileManager: fileManager)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var records = LoadedRecords()
            records.units = try decoder.decode([WorkUnit].self, from: data)
            return records
        } catch {
            return Self.setAsideUnreadableRecords(at: url, fileManager: fileManager)
        }
    }

    /// Rotates an unreadable record file aside so it is not overwritten,
    /// telling the user what was kept; when even that fails, marks the
    /// records as one persistence must not touch.
    private static func setAsideUnreadableRecords(at url: URL,
                                                  fileManager: FileManager) -> LoadedRecords {
        // A record file that cannot be read must not be silently
        // discarded: starting from an empty store would let the next
        // persist() overwrite it, permanently destroying every review
        // record while the worktrees live on. Rotate it aside so the
        // records stay recoverable, and say so — an empty sidebar with
        // no explanation reads as if the reviews never existed.
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("reviews-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        var records = LoadedRecords()
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: rotated)
            records.failure = "Saved reviews could not be read. The unreadable record file was kept as \(rotated.lastPathComponent) beside reviews.json so it can be recovered."
        } catch {
            records.unreadableFileWasLeftInPlace = true
            records.failure = "Saved reviews could not be read, and the unreadable record file could not be set aside. It was left untouched so it can be recovered; reviews will not be saved until it is resolved."
        }
        return records
    }
}
