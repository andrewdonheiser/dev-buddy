import AppKit
import Combine
import SwiftTerm

/// The running terminal for one terminal tab: its `LocalProcessTerminalView`
/// plus the state the pane header needs. Sessions outlive the SwiftUI view,
/// so switching tabs and coming back preserves scrollback and the running
/// process.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {

    let view = LocalProcessTerminalView(frame: .zero)

    /// The title the running program reports, or the working directory name
    /// until it does.
    @Published var title: String
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

    init(terminal: TerminalTab, onTitleChange: (@MainActor (String) -> Void)? = nil) {
        self.workingDirectory = terminal.workingDirectory
        self.title = terminal.title
        self.onTitleChange = onTitleChange
        super.init()

        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        startProcess()
    }

    /// Starts (or restarts) the user's login shell.
    private func startProcess() {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "MarkdownViewer"
        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        let shell = Self.launchConfiguration()
        view.startProcess(executable: shell.path,
                          args: shell.arguments,
                          environment: env,
                          execName: shell.path,
                          currentDirectory: workingDirectory.path)
    }

    func restart() {
        guard hasExited else { return }
        hasExited = false
        failureReason = nil
        failureSuggestion = nil
        startProcess()
    }

    /// Runs the user's default shell as a login shell — so the user's PATH
    /// (Homebrew, etc.) is available to a GUI app — inside the tab's working
    /// directory.
    private static func launchConfiguration() -> (path: String, arguments: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (shell, ["-l"])
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
        failureSuggestion = Self.suggestion(for: error)
        announceEnd(failed: true)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // MARK: - Accessibility

    /// Announces the session's end to assistive technology, which otherwise
    /// has no signal that the terminal view changed state.
    private func announceEnd(failed: Bool) {
        let message = failed ? "Terminal failed to start" : "Terminal session ended"
        // Post from the terminal view itself: a nil element may not be
        // delivered to assistive technology.
        NSAccessibility.post(element: view, notification: .announcement,
                             userInfo: [.announcement: message])
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

    /// A next step for the launch failures that can have one. Spawning fails
    /// this way when the executable is missing or invalid, and the shell path
    /// comes from the SHELL environment variable — the other causes say the
    /// terminal, not the shell, is the problem.
    private static func suggestion(for error: LocalProcessError) -> String? {
        switch error {
        case .forkFailed:
            "Check that the SHELL environment variable points to an installed shell."
        case .alreadyRunning, .notRunning, .writeChannelFailed, .writeFailed:
            nil
        }
    }
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

    func removeSession(_ terminalID: TerminalTab.ID) {
        sessions[terminalID]?.view.terminate()
        sessions[terminalID] = nil
    }
}
