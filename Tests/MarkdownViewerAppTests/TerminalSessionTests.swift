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
        // executable bit) yet fails at exec: SwiftTerm reports that as an
        // ordinary termination with exit code 127, which the session must
        // route to the failure overlay, not the normal-exit one.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-interpreter-\(UUID().uuidString)")
        try "#!/nonexistent/interpreter-\(UUID().uuidString)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal, shellPath: script.path)

        await waitUntilExited(session)

        #expect(session.hasExited)
        #expect(session.failureReason != nil)
        #expect(session.failureSuggestion != nil)
    }

    @Test("a shell that starts and then exits nonzero is a normal exit")
    func nonzeroExitAfterRunningIsNormal() async {
        // /usr/bin/false starts fine and exits 1 — like a user running
        // `exit 1` — so it must keep the normal-exit path: only exit codes
        // 126 and 127 (the exec itself failed) are launch failures.
        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal, shellPath: "/usr/bin/false")

        await waitUntilExited(session)

        #expect(session.hasExited)
        #expect(session.failureReason == nil)
        #expect(session.failureSuggestion == nil)
    }
}

/// Waits for the session's asynchronous termination callback, bounded so a
/// missing callback fails the assertions instead of hanging the suite.
@MainActor
private func waitUntilExited(_ session: TerminalSession, timeout: TimeInterval = 5) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !session.hasExited && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
