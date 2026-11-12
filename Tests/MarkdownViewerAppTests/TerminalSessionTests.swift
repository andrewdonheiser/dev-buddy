import Foundation
import Testing
@testable import MarkdownViewer

/// Covers the terminal session's launch-failure contract: an unstartable
/// shell must surface the failure state (not a normal exit), and a restart
/// must re-validate instead of spawning it. The shell path is injected, so
/// these tests never spawn a real process.
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

    @Test("setTerminalTitle publishes the title and forwards it to the store")
    func setTerminalTitleStreamsToCallback() {
        var received: [String] = []
        let terminal = TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
        let session = TerminalSession(terminal: terminal,
                                      onTitleChange: { received.append($0) },
                                      shellPath: "/nonexistent/shell-\(UUID().uuidString)")

        session.setTerminalTitle(source: session.view, title: "vim — notes")

        #expect(session.title == "vim — notes")
        #expect(received == ["vim — notes"])

        // Empty titles are ignored, matching the tab-list update rule.
        session.setTerminalTitle(source: session.view, title: "")

        #expect(session.title == "vim — notes")
        #expect(received == ["vim — notes"])
    }
}
