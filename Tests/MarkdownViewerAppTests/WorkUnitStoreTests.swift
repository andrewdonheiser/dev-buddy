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
        if arguments.first == "clone", arguments.count >= 5 {
            // The real clone-plus-worktree leaves the worktree directory on
            // disk; the fake creates both it and the bare clone directory.
            // The clone's destination is the argument after the URL.
            let repository = URL(fileURLWithPath: arguments[4])
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("work-unit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Reviews", isDirectory: true)
        reviewsDirectory = dir
        let recorder = GitRecorder()
        git = recorder
        store = WorkUnitStore(reviewsDirectory: dir, git: { arguments, directory in
            try recorder.run(arguments, in: directory)
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
        let pr = try #require(PullRequest.parse(url: "https://github.com/owner/repo/pull/123"))
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
            atPath: unit.worktreeURL.deletingLastPathComponent().path))

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("a failed worktree removal keeps the review so the failure stays visible")
    func failedRemovalKeepsUnit() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: nil)
        fixture.store.select(unit.id)

        // A read-only reviews folder makes the disk removal fail, the way a
        // locked or busy worktree would.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: fixture.reviewsDirectory.path)
        do {
            try fixture.store.delete(unit.id)
            Issue.record("expected delete to throw")
        } catch {
            // The expected failure.
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fixture.reviewsDirectory.path)

        // The record and selection survive the failure, so the overview —
        // and its error — stays on screen and the delete can be retried.
        #expect(fixture.store.units.map(\.id) == [unit.id])
        #expect(fixture.store.selectedWorkUnitID == unit.id)
        #expect(FileManager.default.fileExists(atPath: unit.worktreePath))

        // With the folder writable again, the retry succeeds.
        try fixture.store.delete(unit.id)
        #expect(fixture.store.units.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: unit.worktreeURL.deletingLastPathComponent().path))

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }

    @Test("an undecodable record file is rotated aside and reported, not overwritten")
    func undecodableRecordsAreRotatedAndReported() async throws {
        let fixture = WorkUnitFixture()
        try FileManager.default.createDirectory(at: fixture.storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{\"not\": \"valid\"}".data(using: .utf8)!.write(to: fixture.storageURL)

        let store = WorkUnitStore(reviewsDirectory: fixture.reviewsDirectory,
                                  git: { _, _ in "" })
        #expect(store.units.isEmpty)
        #expect(store.loadFailure != nil)

        // Creating a review persists a fresh record file; the unreadable
        // one must have been rotated aside, not destroyed.
        _ = try await store.createReview(prURLString: "https://github.com/owner/repo/pull/12",
                                         issueReference: nil)
        #expect(FileManager.default.fileExists(atPath: fixture.storageURL.path))
        let directory = fixture.storageURL.deletingLastPathComponent().path
        let rotated = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .first { $0.hasPrefix("reviews-unreadable-") }
        #expect(rotated != nil)
        if let rotated {
            let contents = try String(contentsOf: fixture.storageURL.deletingLastPathComponent()
                .appendingPathComponent(rotated), encoding: .utf8)
            #expect(contents.contains("not"))
        }

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory.deletingLastPathComponent())
    }

    @Test("an unreadable record file that cannot be rotated is never overwritten")
    func unrotatableRecordsAreNotOverwritten() async throws {
        let fixture = WorkUnitFixture()
        try FileManager.default.createDirectory(at: fixture.storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "{\"not\": \"valid\"}".data(using: .utf8)!.write(to: fixture.storageURL)
        // A read-only records folder keeps the unreadable file from being
        // rotated aside, the way a locked file would.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: fixture.storageURL.deletingLastPathComponent().path)

        let store = WorkUnitStore(reviewsDirectory: fixture.reviewsDirectory,
                                  git: { _, _ in "" })
        #expect(store.units.isEmpty)
        #expect(store.loadFailure != nil)

        // The store keeps working in memory, but nothing it does may
        // overwrite the file the unreadable records live in.
        _ = try await store.createReview(prURLString: "https://github.com/owner/repo/pull/12",
                                         issueReference: nil)
        #expect(store.units.count == 1)
        let contents = try String(contentsOf: fixture.storageURL, encoding: .utf8)
        #expect(contents.contains("not"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fixture.storageURL.deletingLastPathComponent().path)
        try? FileManager.default.removeItem(at: fixture.reviewsDirectory.deletingLastPathComponent())
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
    func activeUnitFollowsSelection() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: nil)
        let store = makeStore()
        defer { store.closeAll() }

        // Start with nothing selected.
        fixture.store.select(nil)
        #expect(fixture.store.activeUnit(forSelectedTerminal: nil) == nil)

        // A selected terminal pulls in the unit it is nested in — the
        // nested world the user is working in.
        let terminal = store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
        #expect(fixture.store.activeUnit(forSelectedTerminal: terminal) == unit)
        #expect(fixture.store.unit(of: terminal) == unit)

        // A selected unit wins even when a stray top-level terminal shows.
        fixture.store.select(unit.id)
        let stray = store.openTerminalTab()
        #expect(fixture.store.activeUnit(forSelectedTerminal: stray) == unit)
        #expect(fixture.store.unit(of: stray) == nil)

        // Unknown selection ids are ignored, like the other stores.
        fixture.store.select(UUID())
        #expect(fixture.store.selectedWorkUnitID == unit.id)

        try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
    }
}

@Suite("Detail-column selection precedence")
@MainActor
struct SelectionPrecedenceTests {

    /// Makes a temporary Markdown file the tests can open.
    private func makeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-tests-\(UUID().uuidString).md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An isolated document store, mirroring the fixture pattern the other
    /// suites use so no test touches the shared singleton.
    private func makeStore() -> DocumentStore {
        let scratchLabels = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-tests-labels-\(UUID().uuidString).json")
        return DocumentStore(labels: LabelStore(storageURL: scratchLabels))
    }

    @Test("selecting a document or terminal through any path clears the work unit selection")
    func documentAndTerminalSelectionClearUnit() async throws {
        let fixture = WorkUnitFixture()
        let unit = try await fixture.store.createReview(
            prURLString: "https://github.com/owner/repo/pull/12",
            issueReference: nil)
        let store = makeStore()
        // Keep the coordinator alive for the whole test: its subscriptions
        // are what enforces the rule under test.
        let coordinator = SelectionCoordinator(store: store, workUnits: fixture.store)
        let documentURL = try makeTempFile("# Hello")
        defer {
            store.closeAll()
            try? FileManager.default.removeItem(at: documentURL)
            try? FileManager.default.removeItem(at: fixture.reviewsDirectory)
        }

        withExtendedLifetime(coordinator) {
            // The wizard's unit is selected; its overview owns the detail
            // column.
            #expect(fixture.store.selectedWorkUnitID == unit.id)

            // Opening a document — the path File > Open, drag-and-drop and
            // an "Open With" from the Finder all take, none of which go
            // through the sidebar's selection binding — hands the column to
            // the document instead of leaving it stuck on the review
            // overview.
            store.open(url: documentURL)

            #expect(store.selectedDocument?.url.path == documentURL.path)
            #expect(fixture.store.selectedWorkUnitID == nil)

            // Re-selecting the unit and then opening a terminal (the ⌘T
            // path) hands the column to the terminal the same way.
            fixture.store.select(unit.id)
            let terminal = store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)

            #expect(store.selectedTerminal?.id == terminal.id)
            #expect(fixture.store.selectedWorkUnitID == nil)
        }
    }
}
