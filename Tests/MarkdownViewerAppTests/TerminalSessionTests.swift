import Foundation
import Testing
@testable import MarkdownViewer

/// Covers the terminal session contract: an unstartable shell must surface
/// the failure state (not a normal exit), a restart must re-validate
/// instead of spawning it, title updates stream through `setTerminalTitle`,
/// and the manager keeps one session (and one title callback) per tab. The
/// shell path or session factory is injected, so these tests never spawn a
/// real process.
@Suite("Terminal session")
@MainActor
struct TerminalSessionTests {

    /// A terminal tab rooted at the system temporary directory.
    private func makeTerminal() -> TerminalTab {
        TerminalTab(workingDirectory: FileManager.default.temporaryDirectory)
    }

    /// A session against a bogus shell path (or the given one), so no
    /// process ever spawns.
    private func makeSession(terminal: TerminalTab? = nil,
                             onTitleChange: (@MainActor (String) -> Void)? = nil,
                             shellPath: String? = nil) -> TerminalSession {
        TerminalSession(terminal: terminal ?? makeTerminal(),
                        onTitleChange: onTitleChange,
                        shellPath: shellPath ?? "/nonexistent/shell-\(UUID().uuidString)")
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
