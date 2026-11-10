import AppKit
import SwiftUI
import SwiftTerm

/// The running terminal for one terminal tab: its `LocalProcessTerminalView`
/// plus the state the pane header needs. Sessions outlive the SwiftUI view,
/// so switching tabs and coming back preserves scrollback and the running
/// process.
@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {

    let terminalID: TerminalTab.ID
    let view = LocalProcessTerminalView(frame: .zero)

    /// The title the running program reports (opencode sets the terminal
    /// title), or the working directory name until it does.
    @Published var title: String
    @Published var hasExited = false

    private let workingDirectory: URL

    init(terminal: TerminalTab) {
        self.terminalID = terminal.id
        self.workingDirectory = terminal.workingDirectory
        self.title = terminal.title
        super.init()

        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        startProcess()
    }

    /// Starts (or restarts) the OpenCode TUI.
    private func startProcess() {
        let (shell, args) = Self.launchConfiguration(workingDirectory: workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM_PROGRAM"] = "MarkdownViewer"
        let env = environment.map { "\($0.key)=\($0.value)" }.sorted()
        view.startProcess(executable: shell,
                          args: args,
                          environment: env,
                          execName: shell,
                          currentDirectory: workingDirectory.path)
    }

    func restart() {
        guard hasExited else { return }
        hasExited = false
        startProcess()
    }

    /// Runs the OpenCode TUI through a login shell — so the user's PATH
    /// (Homebrew, etc.) is available to a GUI app — inside the tab's working
    /// directory.
    static func launchConfiguration(workingDirectory: URL) -> (shell: String, args: [String]) {
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        let opencode = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "opencode"
        let escaped = workingDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
        return ("/bin/zsh", ["-l", "-c", "cd '\(escaped)' && exec \(opencode)"])
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        DocumentStore.shared.updateTerminalTitle(id: terminalID, title: title)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasExited = true
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        hasExited = true
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Keeps one session per terminal tab for the life of the app.
@MainActor
final class TerminalSessionManager {

    static let shared = TerminalSessionManager()

    private var sessions: [TerminalTab.ID: TerminalSession] = [:]

    func session(for terminal: TerminalTab) -> TerminalSession {
        if let existing = sessions[terminal.id] { return existing }
        let session = TerminalSession(terminal: terminal)
        sessions[terminal.id] = session
        return session
    }

    func removeSession(terminalID: TerminalTab.ID) {
        sessions[terminalID]?.view.terminate()
        sessions[terminalID] = nil
    }
}

/// The embedded terminal shown in the detail column when a terminal tab is
/// selected: a small header above the terminal view.
struct TerminalPane: View {
    @EnvironmentObject private var store: DocumentStore
    let terminal: TerminalTab
    @ObservedObject private var session: TerminalSession

    init(terminal: TerminalTab) {
        self.terminal = terminal
        self._session = ObservedObject(wrappedValue: TerminalSessionManager.shared.session(for: terminal))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalHostingView(session: session)
                .overlay {
                    if session.hasExited {
                        exitedOverlay
                    }
                }
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(terminal.workingDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                session.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!session.hasExited)
            .help(session.hasExited ? "Restart the terminal" : "Terminal is running")
            Button {
                store.closeTerminal(id: terminal.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close terminal tab")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Offer a restart when the process exits (e.g. quitting the TUI with
    /// Ctrl+C or `q`).
    private var exitedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Terminal session ended")
                .font(.headline)
            Button("Restart") {
                session.restart()
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
    }
}

/// Bridges the session's long-lived terminal view into SwiftUI.
private struct TerminalHostingView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {}
}
