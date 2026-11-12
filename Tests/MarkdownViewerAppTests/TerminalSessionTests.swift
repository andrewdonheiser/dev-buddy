import Foundation
import Testing
@testable import MarkdownViewer

/// Covers the terminal session's launch-failure contract: an unstartable
/// shell must surface the failure state (not a normal exit), and a restart
/// must re-validate instead of spawning it. The shell path is injected, so
/// these tests never spawn the user's shell; the exit-code cases spawn only
/// a short-lived child that terminates immediately.
@Suite("Terminal session launch failures")
@MainActor
struct TerminalSessionTests {

    @Test("a bogus shell path produces the launch-failure state")
    func bogusShellPathFailsToLaunch() {
        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal,
                                      shellPath: "/nonexistent/shell-binary-\(UUID().uuidString)")

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
        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal,
                                      shellPath: FileManager.default.temporaryDirectory.path)

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

        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal, shellPath: script.path)

        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })

        #expect(session.hasExited)
        #expect(session.failureReason == "The shell at \(script.path) could not be run (it exited with code 127 at launch).")
        #expect(session.failureSuggestion != nil)
    }

    @Test("an exec-failure exit code of 126 also reports the failure state")
    func execFailureExitCode126ReportsFailureState() async {
        // A real spawn cannot be made to fail exec with 126 deterministically
        // (a permission problem is caught by pre-launch validation), so this
        // drives the termination callback SwiftTerm invokes — directly, with
        // the other exec-failure exit code — pinning that half of the check.
        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal, shellPath: "/usr/bin/false")
        // The wait is asserted so the test cannot pass vacuously if the
        // real termination callback stops firing: `failureReason` is nil
        // only while `/usr/bin/false` is still running.
        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })

        // /usr/bin/false ends on its own first, on the normal-exit path.
        #expect(session.failureReason == nil)

        session.processTerminated(source: session.view, exitCode: 126)

        #expect(session.failureReason == "The shell at /usr/bin/false could not be run (it exited with code 126 at launch).")
        #expect(session.failureSuggestion != nil)
    }

    @Test("a shell that starts and then exits nonzero is a normal exit")
    func nonzeroExitAfterRunningIsNormal() async {
        // /usr/bin/false starts fine and exits 1 — like a user running
        // `exit 1` — so it must keep the normal-exit path: only exit codes
        // 126 and 127 (the exec itself failed) are launch failures.
        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal, shellPath: "/usr/bin/false")

        #expect(await waitUntil(timeout: .seconds(5)) { session.hasExited })

        #expect(session.hasExited)
        #expect(session.failureReason == nil)
        #expect(session.failureSuggestion == nil)
    }
}
