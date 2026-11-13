import Foundation
import Testing
@testable import MarkdownViewer

/// A git runner that fakes worktree creation — creating the directories the
/// real one would — while recording every command it is asked to run. The
/// store runs git on a background thread, so the recorder is thread-safe.
final class GitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [[String]] = []
    /// Command names (e.g. "clone") that should fail, simulating a git error.
    var failingCommands: Set<String> = []

    /// The `WorkUnitStore.GitRunner` closure handed to the store.
    func run(_ arguments: [String], in directory: URL?) throws -> String {
        lock.lock()
        commands.append(arguments)
        let shouldFail = failingCommands.contains(arguments.first ?? "")
        lock.unlock()
        if shouldFail {
            throw NSError(domain: "GitRecorder", code: 128,
                          userInfo: [NSLocalizedDescriptionKey: "fatal: repository not found"])
        }
        if arguments.first == "clone", arguments.count >= 4 {
            // The real clone-plus-worktree leaves the worktree directory on
            // disk; the fake creates both it and the bare clone directory.
            let repository = URL(fileURLWithPath: arguments[3])
            let worktree = repository.deletingLastPathComponent()
                .appendingPathComponent("worktree", isDirectory: true)
            try? FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        }
        return ""
    }
}

/// A store wired to a temporary reviews folder and a recording git runner.
@MainActor
private struct WorkUnitFixture {
    let reviewsDirectory: URL
    let git: GitRecorder
    let store: WorkUnitStore

    init() {
        reviewsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-unit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Reviews", isDirectory: true)
        git = GitRecorder()
        store = WorkUnitStore(reviewsDirectory: reviewsDirectory, git: { arguments, directory in
            try git.run(arguments, in: directory)
        })
    }

    var storageURL: URL {
        reviewsDirectory.deletingLastPathComponent()
            .appendingPathComponent("reviews.json")
    }
}

@Suite("Pull request URL parsing")
struct PullRequestTests {

    @Test("parses a plain https pull request URL")
    func parsesHTTPSURL() throws {
        let pr = #require(PullRequest.parse(url: "https://github.com/owner/repo/pull/123"))
        #expect(pr.repository == "owner/repo")
        #expect(pr.number == 123)
        #expect(pr.title == "owner/repo #123")
        #expect(pr.url.absoluteString == "https://github.com/owner/repo/pull/123")
        #expect(pr.cloneURL.absoluteString == "https://github.com/owner/repo.git")
    }

    @Test("tolerates a missing scheme, www, trailing slash and /files suffix")
    func parsesURLVariants() {
        for string in ["github.com/owner/repo/pull/9",
                       "https://www.github.com/owner/repo/pull/9/",
                       " https://github.com/owner/repo/pull/9/files ",
                       "https://github.com/owner/repo/pulls/9"] {
            #expect(PullRequest.parse(url: string) != nil, "expected \(string) to parse")
        }
        #expect(PullRequest.parse(url: "github.com/owner/repo/pull/9")?.number == 9)
    }

    @Test("rejects URLs that are not pull requests")
    func rejectsNonPullRequestURLs() {
        for string in ["",
                       "not a url",
                       "https://github.com/owner/repo",
                       "https://github.com/owner/repo/issues/5",
                       "https://example.com/owner/repo/pull/1",
                       "https://github.com/owner/repo/pull/notanumber",
                       "https://github.com/owner/repo/pull/0"] {
            #expect(PullRequest.parse(url: string) == nil, "expected \(string) to be rejected")
        }
    }
}

@Suite("Review work units")
@MainActor
struct WorkUnitStoreTests {

    @Test("creating a review clones the PR into a managed worktree and records it")
    func createReviewRecordsUnit() async throws {
        let fixture = WorkUnitFixture()

        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: " PROJ-341 ")

        // The unit records what the wizard collected.
        #expect(unit.title == "owner/repo #12")
        #expect(unit.prURL.absoluteString == "https://github.com/owner/repo/pull/12")
        #expect(unit.issueReference == "PROJ-341")
        #expect(!unit.isArchived)
        // The worktree lives under the managed reviews folder and exists.
        #expect(unit.worktreePath.hasPrefix(fixture.reviewsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: unit.worktreePath))
        // The unit is in the store and selected.
        #expect(fixture.store.units.map(\.id) == [unit.id])
        #expect(fixture.store.selectedWorkUnitID == unit.id)
        #expect(fixture.store.activeUnits.map(\.id) == [unit.id])
        // The record persists.
        #expect(FileManager.default.fileExists(atPath: fixture.storageURL.path))

        // Git was asked to clone the repository, fetch the PR head and add
        // the worktree — in that order, against the right paths.
        let commands = fixture.git.commands
        #expect(commands.count == 3)
        #expect(commands[0][0] == "clone")
        #expect(commands[0].contains("https://github.com/owner/repo.git"))
        #expect(commands[1][0] == "fetch")
        #expect(commands[1].contains("pull/12/head"))
        #expect(commands[2][0] == "worktree")
        #expect(commands[2].contains("FETCH_HEAD"))
        #expect(commands[2].contains(unit.worktreePath))

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("an empty or invalid PR URL is a distinct error that creates nothing")
    func invalidURLCreatesNothing() async {
        let fixture = WorkUnitFixture()

        for input in ["https://github.com/owner/repo", "   "] {
            do {
                _ = try await fixture.store.createReview(prURLString: input, issueReference: nil)
                Issue.record("expected createReview to throw for \(input)")
            } catch let error as ReviewError {
                #expect(error == .invalidPullRequestURL)
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }

        #expect(fixture.store.units.isEmpty)
        #expect(fixture.store.selectedWorkUnitID == nil)
        #expect(fixture.git.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.storageURL.path))

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("a failed clone surfaces git's error and leaves no half-created unit")
    func failedCloneCleansUp() async {
        let fixture = WorkUnitFixture()
        fixture.git.failingCommands = ["clone"]

        do {
            _ = try await fixture.store.createReview(prURLString: "https://github.com/owner/repo/pull/12",
                                                     issueReference: nil)
            Issue.record("expected createReview to throw")
        } catch let error as ReviewError {
            guard case .worktreeCreationFailed = error else {
                Issue.record("expected a worktreeCreationFailed error, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        // Nothing was recorded and no unit directory lingers on disk.
        #expect(fixture.store.units.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: fixture.reviewsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty)

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("archiving saves the review away but keeps its worktree")
    func archiveKeepsWorktree() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: nil)

        fixture.store.archive(unit.id)

        #expect(fixture.store.activeUnits.isEmpty)
        #expect(fixture.store.archivedUnits.map(\.id) == [unit.id])
        #expect(fixture.store.selectedWorkUnitID == nil)
        // The worktree survives archiving so the review can be reopened.
        #expect(FileManager.default.fileExists(atPath: unit.worktreePath))

        fixture.store.unarchive(unit.id)

        #expect(fixture.store.activeUnits.map(\.id) == [unit.id])
        #expect(fixture.store.archivedUnits.isEmpty)
        #expect(FileManager.default.fileExists(atPath: unit.worktreePath))

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("deleting a review removes its record and its worktree from disk")
    func deleteRemovesWorktree() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: nil)

        fixture.store.select(unit.id)
        try fixture.store.delete(unit.id)

        #expect(fixture.store.units.isEmpty)
        #expect(fixture.store.selectedWorkUnitID == nil)
        #expect(!FileManager.default.fileExists(atPath: unit.worktreePath))
        #expect(!FileManager.default.fileExists(
            at: unit.worktreeURL.deletingLastPathComponent().path))

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("unit records survive a new store reading the same folder")
    func recordsPersistAcrossStores() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: "PROJ-1")
        fixture.store.archive(unit.id)

        let reopened = WorkUnitStore(reviewsDirectory: fixture.reviewsDirectory,
                                     git: { _, _ in "" })

        // The record survives the relaunch with everything the wizard
        // collected (dates round-trip at second precision, so compare
        // the fields rather than whole values).
        #expect(reopened.units.count == 1)
        #expect(reopened.units.first?.id == unit.id)
        #expect(reopened.units.first?.title == "owner/repo #12")
        #expect(reopened.units.first?.issueReference == "PROJ-1")
        #expect(reopened.units.first?.worktreePath == unit.worktreePath)
        #expect(reopened.units.first?.isArchived == true)
        #expect(reopened.selectedWorkUnitID == nil)

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("selection ignores unknown ids and can be cleared")
    func selectionGuards() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: nil)

        fixture.store.select(UUID())
        #expect(fixture.store.selectedWorkUnitID == unit.id)

        fixture.store.select(nil)
        #expect(fixture.store.selectedWorkUnitID == nil)

        fixture.store.select(unit.id)
        fixture.store.deselect()
        #expect(fixture.store.selectedWorkUnitID == nil)

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }
}

@Suite("Terminals nested in review work units")
@MainActor
struct WorkUnitTerminalTests {

    private func makeStore() -> DocumentStore {
        DocumentStore(labels: LabelStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("work-unit-terminal-tests-\(UUID().uuidString).json")))
    }

    @Test("terminals opened with a work unit nest under it")
    func terminalsNestUnderUnit() {
        let store = makeStore()
        let workUnitID = UUID()
        defer { store.closeAll() }

        let nested = store.openTerminal(in: URL(fileURLWithPath: "/tmp/worktree"),
                                        workUnitID: workUnitID)
        let topLevel = store.openTerminalTab()

        #expect(nested.workUnitID == workUnitID)
        #expect(topLevel.workUnitID == nil)
        #expect(store.terminals.map(\.id) == [nested.id, topLevel.id])
        #expect(store.terminals(inWorkUnit: workUnitID).map(\.id) == [nested.id])
        #expect(store.terminals(inWorkUnit: UUID()).isEmpty)
    }

    @Test("closing one terminal in a work unit leaves the unit and its other terminals intact")
    func closingOneTerminalKeepsTheRest() {
        let store = makeStore()
        let workUnitID = UUID()
        defer { store.closeAll() }

        let first = store.openTerminal(in: URL(fileURLWithPath: "/tmp/worktree"),
                                       workUnitID: workUnitID)
        let second = store.openTerminal(in: URL(fileURLWithPath: "/tmp/worktree"),
                                        workUnitID: workUnitID)

        store.closeTerminal(first.id)

        #expect(store.terminals.map(\.id) == [second.id])
        #expect(store.terminals(inWorkUnit: workUnitID).map(\.id) == [second.id])
        // The surviving terminal still belongs to the unit.
        #expect(second.workUnitID == workUnitID)
    }

    @Test("the active unit scopes new terminals to the selected work unit's worktree")
    func activeUnitFollowsSelection() {
        let reviewsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-unit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Reviews", isDirectory: true)
        let workUnits = WorkUnitStore(reviewsDirectory: reviewsDirectory, git: { _, _ in "" })
        let store = makeStore()
        defer { store.closeAll() }

        let unit = WorkUnit(prURL: URL(string: "https://github.com/owner/repo/pull/1")!,
                            title: "owner/repo #1",
                            worktreePath: "/tmp/reviews/owner-repo-1/worktree")
        workUnits.insertForTesting(unit)

        // With nothing selected there is no active unit.
        #expect(workUnits.activeUnit(forSelectedTerminal: nil) == nil)

        // A selected terminal pulls in the unit it is nested in — the
        // nested world the user is working in.
        let terminal = store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
        #expect(workUnits.activeUnit(forSelectedTerminal: terminal) == unit)
        #expect(workUnits.unit(of: terminal) == unit)

        // A selected unit wins even when a stray top-level terminal shows.
        workUnits.select(unit.id)
        let stray = store.openTerminalTab()
        #expect(workUnits.activeUnit(forSelectedTerminal: stray) == unit)
        #expect(workUnits.unit(of: stray) == nil)

        // Unknown selection ids are ignored, like the other stores.
        workUnits.select(UUID())
        #expect(workUnits.selectedWorkUnitID == unit.id)

        try? FileManager.default.removeItem(at: reviewsDirectory)
    }
}
