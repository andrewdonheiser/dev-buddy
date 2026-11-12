import Foundation
import Testing
@testable import MarkdownViewer

/// Covers the terminal session contract: an unstartable shell must surface
/// the failure state (not a normal exit), a restart must re-validate
/// instead of spawning it, exec-failure exit codes route to the failure
/// overlay, title updates stream through `setTerminalTitle`, and the
/// manager keeps one session (and one title callback) per tab. The shell
/// path, clock, or session factory is injected, so most tests never spawn a real
/// process; the exit-code cases spawn only a short-lived child that fails
/// exec or terminates immediately.
@Suite("Terminal session")
@MainActor
struct TerminalSessionTests {

    /// A terminal tab rooted at the system temporary directory.
    private func makeTerminal() -> TerminalTab {
        TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
    }

    /// A session against a bogus shell path (or the given one), so no
    /// process ever spawns unless the test asks for one; `now` injects the
    /// clock the launch-window tests need.
    private func makeSession(terminal: TerminalTab? = nil,
                             onTitleChange: (@MainActor (String) -> Void)? = nil,
                             shellPath: String? = nil,
                             now: @escaping () -> Date = { Date() }) -> TerminalSession {
        TerminalSession(terminal: terminal ?? makeTerminal(),
                        onTitleChange: onTitleChange,
                        shellPath: shellPath ?? "/nonexistent/shell-\(UUID().uuidString)",
                        now: now)
    }

    @Test("a bogus shell path produces the launch-failure state")
    func bogusShellPathFailsToLaunch() {
        let session = makeSession()

        #expect(session.hasExited)
        #expect(session.failureReason != nil)
        #expect(session.failureSuggestion != nil)

        // Restart re-validates the shell: the broken path fails again
        // instead of spawning a process.
        session.restart()

        #expect(session.hasExited)
        #expect(session.failureReason != nil)
        #expect(session.failureSuggestion != nil)
    }

    @Test("a directory is not a runnable shell")
    func directoryShellPathFailsToLaunch() {
        // Directories carry the POSIX x bit (search permission), so the
        // executable check alone would let one through to a failed exec.
        let session = makeSession(shellPath: FileManager.default.temporaryDirectory.path)

        #expect(session.hasExited)
        #expect(session.failureReason != nil)
        #expect(session.failureSuggestion != nil)
    }

    @Test("a shell that passes validation but fails at exec reports the failure state")
    func execFailureAfterValidationFails() async throws {
        // An executable-marked script whose `#!` interpreter is missing
        // passes every pre-launch check (exists, not a directory,
        // executable bit) yet fails at exec. SwiftTerm (1.99.3) launches
        // via forkpty and reports only fork/write-channel failures through
        // `processFailedToStart`; a failed exec in the child exits 127 and
        // is reaped as an ordinary termination — verified against the
        // pinned dependency source, which documents that an exec failure
        // is delivered through `processTerminated` with exit code 127 —
        // so the session must route it to the failure overlay, not the
        // normal-exit one.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-interpreter-\(UUID().uuidString)")
        try "#!/nonexistent/interpreter-\(UUID().uuidString)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let session = makeSession(shellPath: script.path)

        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })

        #expect(session.hasExited)
        #expect(session.failureReason == "The shell at \(script.path) exited with code 127 immediately after launch.")
        #expect(session.failureSuggestion != nil)
    }

    @Test("an exec-failure exit code of 126 also reports the failure state")
    func execFailureExitCode126ReportsFailureState() async {
        // A real spawn cannot be made to fail exec with 126 deterministically
        // (a permission problem is caught by pre-launch validation), so this
        // drives the termination callback SwiftTerm invokes — directly, with
        // the other exec-failure exit code — pinning that half of the check.
        // The clock is fixed so the callback is deterministically inside the
        // launch window, however long the real process took to exit.
        let session = makeSession(shellPath: "/usr/bin/false",
                                  now: { Date(timeIntervalSinceReferenceDate: 0) })
        // The wait is asserted so the test cannot pass vacuously if the
        // real termination callback stops firing: `failureReason` is nil
        // only while `/usr/bin/false` is still running.
        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })

        // /usr/bin/false ends on its own first, on the normal-exit path.
        #expect(session.failureReason == nil)

        session.processTerminated(source: session.view, exitCode: 126)

        #expect(session.failureReason == "The shell at /usr/bin/false exited with code 126 immediately after launch.")
        #expect(session.failureSuggestion != nil)
    }

    @Test("a 126/127 exit after the launch window is a normal exit")
    func execFailureExitCodeAfterLaunchWindowIsNormalExit() async {
        // A healthy shell the user deliberately leaves via `exit 127` — or
        // after a command that returned 126/127 — must not show the
        // launch-failure overlay. The clock is injected and advanced past
        // the launch window, standing in for a session that ran for a
        // while before the user typed `exit`.
        var currentTime = Date(timeIntervalSinceReferenceDate: 0)
        let session = makeSession(shellPath: "/usr/bin/false", now: { currentTime })

        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })
        #expect(session.failureReason == nil)

        // Well past the launch window, as a deliberate `exit 127` would be.
        currentTime = currentTime.addingTimeInterval(60)
        session.processTerminated(source: session.view, exitCode: 127)

        #expect(session.failureReason == nil)
        #expect(session.failureSuggestion == nil)
    }

    @Test("a shell that starts and then exits nonzero is a normal exit")
    func nonzeroExitAfterRunningIsNormal() async {
        // /usr/bin/false starts fine and exits 1 — like a user running
        // `exit 1` — so it must keep the normal-exit path: only exit codes
        // 126 and 127 (the exec itself failed) are launch failures.
        let session = makeSession(shellPath: "/usr/bin/false")

        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })

        #expect(session.hasExited)
        #expect(session.failureReason == nil)
        #expect(session.failureSuggestion == nil)
    }

    @Test("setTerminalTitle publishes the title and forwards it to the onTitleChange callback")
    func setTerminalTitleStreamsToCallback() {
        var received: [String] = []
        let session = makeSession(onTitleChange: { received.append($0) })

        session.setTerminalTitle(source: session.view, title: "vim — notes")

        #expect(session.title == "vim — notes")
        #expect(received == ["vim — notes"])

        // Empty titles are ignored, matching the tab-list update rule.
        session.setTerminalTitle(source: session.view, title: "")

        #expect(session.title == "vim — notes")
        #expect(received == ["vim — notes"])
    }

    @Test("the manager reuses a tab's session and keeps the first title callback")
    func managerReusesSessionAndKeepsFirstCallback() {
        // The factory builds real sessions against a bogus shell path, so
        // the manager's own reuse logic runs without spawning a process.
        let manager = TerminalSessionManager(sessionFactory: { terminal, onTitleChange in
            makeSession(terminal: terminal, onTitleChange: onTitleChange)
        })
        let terminal = makeTerminal()
        var firstTitles: [String] = []
        var secondTitles: [String] = []

        let first = manager.session(terminal, onTitleChange: { firstTitles.append($0) })
        let second = manager.session(terminal, onTitleChange: { secondTitles.append($0) })

        // The second call returns the tab's existing session — and drops its
        // callback — so title updates keep flowing through the closure the
        // first call stored. The store passes an idempotent per-tab closure
        // on every call, which is what makes that safe.
        #expect(first === second)
        first.setTerminalTitle(source: first.view, title: "vim — notes")
        #expect(firstTitles == ["vim — notes"])
        #expect(secondTitles.isEmpty)
    }
}
