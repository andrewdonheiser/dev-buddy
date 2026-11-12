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
    /// until it does.
    @Published var title: String
    @Published private(set) var hasExited = false
    /// A plain-language reason the shell failed to launch, set on any of
    /// the three launch-failure paths — pre-launch validation, a process
    /// that failed to start, or an exec-failure exit code (126/127) — never
    /// for a normal exit.
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
    /// The clock that timestamps each launch, so an exec-failure exit
    /// (reaped near-instantly) can be told apart from a healthy shell the
    /// user deliberately left via `exit 126`/`exit 127`. Injectable so
    /// tests can move time past the launch window without sleeping.
    private let now: () -> Date
    /// When the shell was last launched, per `now`; `nil` until a launch
    /// passes pre-launch validation.
    private var launchedAt: Date?

    init(terminal: TerminalTab,
         onTitleChange: (@MainActor (String) -> Void)? = nil,
         shellPath: String? = nil,
         now: @escaping () -> Date = { Date() }) {
        self.workingDirectory = terminal.workingDirectory
        self.title = terminal.title
        self.onTitleChange = onTitleChange
        self.shellPath = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.now = now
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
            failLaunch(reason: "The shell at \(shell.path) could not be found or run.",
                       suggestion: Self.shellSuggestion)
            return
        }
        launchedAt = now()
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
        // A shell that ran and then exited nonzero (`exit 1`) ended
        // normally. Exit codes 126 and 127 mean the exec itself failed —
        // bad interpreter, corrupt or wrong-architecture binary — which
        // the up-front validation cannot catch, so those reach the
        // launch-failure overlay instead of the benign "session ended".
        // The exit code alone cannot distinguish this from a healthy shell
        // the user deliberately left via `exit 126`/`exit 127`, so a 126/127
        // termination only counts as an exec failure while it arrives
        // within the launch window: a failed exec is reaped
        // near-instantly, a deliberate exit almost never is. The
        // exec-failure branch lets `failLaunch` own the whole
        // failure-state transition, so `hasExited` is only set here on the
        // normal-exit path.
        if let code = exitCode, code == 126 || code == 127, let launchedAt,
           now().timeIntervalSince(launchedAt) <= Self.execFailureWindow {
            // Resolved the same way as the pre-launch validation message,
            // so the two failure reasons always name the same executable.
            let shell = Self.launchConfiguration(for: shellPath)
            failLaunch(reason: "The shell at \(shell.path) could not be run (it exited with code \(code) at launch).",
                       suggestion: Self.shellSuggestion)
            return
        }
        hasExited = true
        announceEnd(failed: false)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        failLaunch(reason: Self.describe(error))
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

    /// Marks the session as ended by a launch failure: records the
    /// plain-language reason and optional next step, then announces the
    /// failure to assistive technology.
    private func failLaunch(reason: String, suggestion: String? = nil) {
        hasExited = true
        failureReason = reason
        failureSuggestion = suggestion
        announceEnd(failed: true)
    }

    /// How long after launch a 126/127 termination still counts as an exec
    /// failure (see `processTerminated`): a failed exec is reaped
    /// near-instantly, while a healthy shell the user deliberately leaves
    /// via `exit 126`/`exit 127` almost never ends this quickly.
    private static let execFailureWindow: TimeInterval = 2

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

    /// The next step when the shell path itself is the problem. The path
    /// comes from the SHELL environment variable, and an unstartable shell
    /// is caught before launch (the other failure causes say the terminal,
    /// not the shell, is the problem, so they carry no suggestion).
    private static let shellSuggestion = "Check that the SHELL environment variable points to an installed shell."
}

/// Keeps one session per terminal tab for the life of the app.
@MainActor
final class TerminalSessionManager {

    static let shared = TerminalSessionManager()

    private var sessions: [TerminalTab.ID: TerminalSession] = [:]

    /// Returns the tab's session, creating it (and spawning the shell) on
    /// first request. `onTitleChange` receives title updates from the running
    /// program and is only stored when a session is created.
    func session(for terminal: TerminalTab,
                 onTitleChange: (@MainActor (String) -> Void)? = nil) -> TerminalSession {
        if let existing = sessions[terminal.id] { return existing }
        let session = TerminalSession(terminal: terminal, onTitleChange: onTitleChange)
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
