import AppKit
import Combine
import SwiftUI
import SwiftTerm

/// The running terminal for one terminal tab: its `LocalProcessTerminalView`
/// plus the state the pane header needs. Sessions outlive the SwiftUI view,
/// so switching tabs and coming back preserves scrollback and the running
/// process.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {

    /// The terminal view this session hosts, exposed read-only for
    /// `TerminalHostingView` — the SwiftUI bridge that mounts it in the
    /// pane; everything else reaches the terminal through the session.
    private(set) var view: LocalProcessTerminalView

    /// The title the running program reports, or the working directory name
    /// until it does; assignments flow through `setTerminalTitle`.
    @Published private(set) var title: String
    @Published private(set) var hasExited = false
    /// A plain-language reason the shell failed to launch, set only when the
    /// process failed to start (as opposed to exiting normally).
    @Published private(set) var failureReason: String?
    /// A next step for the launch failures that have one, shown alongside the
    /// reason instead of a hint that may not apply.
    @Published private(set) var failureSuggestion: String?

    private let workingDirectory: URL
    /// Receives title updates from the running program, wired by whoever
    /// creates the session — the session never reaches into a store itself.
    private let onTitleChange: (@MainActor (String) -> Void)?
    /// The shell executable to run. Injectable so tests can exercise the
    /// launch-failure path without mutating the process environment;
    /// `nil` runs the user's default shell from the SHELL variable.
    private let shellPath: String

    init(terminal: TerminalTab,
         onTitleChange: (@MainActor (String) -> Void)? = nil,
         shellPath: String? = nil) {
        self.workingDirectory = terminal.workingDirectory
        self.title = terminal.title
        self.onTitleChange = onTitleChange
        self.shellPath = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.view = LocalProcessTerminalView(frame: .zero)
        super.init()

        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        startProcess()
    }

    /// Starts (or restarts) the session's shell.
    private func startProcess() {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "MarkdownViewer"
        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let shell = Self.launchConfiguration(for: shellPath)
        // SwiftTerm reports a failed exec — e.g. a missing shell — as an
        // ordinary termination with exit code 127, not as a launch failure,
        // so the executable is validated up front: an unstartable shell must
        // reach the launch-failure overlay, not the normal-exit one. The
        // POSIX x bit only means search permission on a directory, so a
        // directory path is rejected here too — it would otherwise fail at
        // exec with the same conflation.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: shell.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: shell.path) else {
            hasExited = true
            failureReason = "The shell at \(shell.path) could not be found or run."
            failureSuggestion = Self.shellSuggestion
            announceEnd(failed: true)
            return
        }
        view.startProcess(executable: shell.path,
                          args: shell.arguments,
                          environment: env,
                          execName: shell.path,
                          currentDirectory: workingDirectory.path)
    }

    /// Restarts the shell after it exited or failed to start, clearing any
    /// launch-failure state first — the shell is re-validated, so a restart
    /// of an unstartable shell fails the same way instead of spawning it.
    func restart() {
        guard hasExited else { return }
        hasExited = false
        failureReason = nil
        failureSuggestion = nil
        startProcess()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        onTitleChange?(title)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasExited = true
        announceEnd(failed: false)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        hasExited = true
        failureReason = Self.describe(error)
        announceEnd(failed: true)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // MARK: - Accessibility

    /// Announces the session's end to assistive technology, which otherwise
    /// has no signal that the terminal view changed state. A launch failure
    /// includes its reason and next step so screen-reader users learn why
    /// the terminal ended without navigating the overlay.
    private func announceEnd(failed: Bool) {
        var message = failed ? "Terminal failed to start" : "Terminal session ended"
        if failed, let failureReason {
            message += ". \(failureReason)"
            if let failureSuggestion {
                message += " \(failureSuggestion)"
            }
        }
        // Post from the terminal view itself: a nil element may not be
        // delivered to assistive technology.
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Helpers

    /// Runs the configured shell as a login shell — so the user's PATH
    /// (Homebrew, etc.) is available to a GUI app — inside the tab's working
    /// directory.
    private static func launchConfiguration(for shellPath: String) -> (path: String, arguments: [String]) {
        (shellPath, ["-l"])
    }

    /// A plain-language rendering of a launch failure.
    private static func describe(_ error: LocalProcessError) -> String {
        switch error {
        case .alreadyRunning:
            "A process is already running in this terminal."
        case .notRunning:
            "No shell process is running in this terminal."
        case .forkFailed:
            "The operating system could not start a new process."
        case .writeChannelFailed:
            "The terminal's input channel could not be set up."
        case .writeFailed:
            "The terminal could not write to the shell process."
        }
    }

    /// The next step when the shell path itself is the problem: the path
    /// comes from the SHELL environment variable, and an unstartable shell
    /// is caught before launch (the other failure causes carry no
    /// suggestion, since they say the terminal, not the shell, is at fault).
    private static let shellSuggestion = "Check that the SHELL environment variable points to an installed shell."
}

/// Keeps one session per terminal tab for the life of the app.
@MainActor
final class TerminalSessionManager {

    static let shared = TerminalSessionManager()

    /// Creates a tab's session. Injectable through the initializer
    /// (mirroring `DocumentStore`'s seams) so tests can exercise the reuse
    /// logic with bogus-shell sessions instead of spawning real processes.
    typealias SessionFactory = @MainActor (TerminalTab, (@MainActor (String) -> Void)?) -> TerminalSession

    private var sessions: [TerminalTab.ID: TerminalSession] = [:]
    private let sessionFactory: SessionFactory

    /// Creates a manager, defaulting to real terminal sessions.
    init(sessionFactory: @escaping SessionFactory = { terminal, onTitleChange in
        TerminalSession(terminal: terminal, onTitleChange: onTitleChange)
    }) {
        self.sessionFactory = sessionFactory
    }

    /// Returns the tab's session, creating it (and spawning the shell) on
    /// first request. `onTitleChange` receives title updates from the running
    /// program and is only stored when a session is created.
    func session(_ terminal: TerminalTab,
                 onTitleChange: (@MainActor (String) -> Void)? = nil) -> TerminalSession {
        if let existing = sessions[terminal.id] { return existing }
        let session = sessionFactory(terminal, onTitleChange)
        sessions[terminal.id] = session
        return session
    }

    /// Whether the tab's shell is still running. Does not create a session.
    func hasLiveProcess(_ terminalID: TerminalTab.ID) -> Bool {
        guard let session = sessions[terminalID] else { return false }
        return !session.hasExited
    }

    /// Forgets the tab's session, terminating its shell (and the programs it
    /// runs) if one is still alive.
    func removeSession(_ terminalID: TerminalTab.ID) {
        sessions[terminalID]?.view.terminate()
        sessions[terminalID] = nil
    }
}
