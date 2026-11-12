import AppKit
import SwiftTerm
import SwiftUI

/// The embedded terminal shown in the detail column when a terminal tab is
/// selected: a small header above the terminal view.
struct TerminalPane: View {
    @EnvironmentObject private var store: DocumentStore
    let terminal: TerminalTab

    /// Resolved on first appear. Creating a session spawns the shell
    /// process, so a speculatively constructed view value must not do it in
    /// its initializer.
    @State private var session: TerminalSession?

    var body: some View {
        Group {
            if let session {
                TerminalPaneContent(terminal: terminal, session: session)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if session == nil {
                // Everything terminal flows through the store: it owns the
                // tab list, receives the session's title updates, and hides
                // the session manager behind its injected seam — the view
                // never reaches into a shared singleton itself.
                session = store.session(for: terminal)
            }
        }
    }
}

/// The pane's content once its session is resolved.
private struct TerminalPaneContent: View {
    @EnvironmentObject private var store: DocumentStore
    let terminal: TerminalTab
    @ObservedObject var session: TerminalSession
    /// Lands keyboard focus on the overlay's action button when the shell
    /// exits or fails to start — the terminal view behind it is dead and
    /// would silently drop keystrokes.
    @FocusState private var overlayFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalHostingView(session: session)
                .overlay {
                    if session.hasExited {
                        if session.failureReason != nil {
                            failedOverlay
                        } else {
                            exitedOverlay
                        }
                    }
                }
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
        .onAppear { focusOverlayIfExited() }
        .onChange(of: session.hasExited) { _, exited in
            if exited { focusOverlayIfExited() }
        }
    }

    /// Focuses the overlay's action button when the overlay is showing.
    private func focusOverlayIfExited() {
        if session.hasExited { overlayFocused = true }
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
            .accessibilityLabel("Restart terminal")
            Button {
                store.requestCloseTerminal(terminal.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close terminal tab (terminates the shell and its running programs)")
            .accessibilityLabel("Close terminal tab")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Offer a restart when the shell exits (e.g. with `exit` or Ctrl+D).
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
            .focused($overlayFocused)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
    }

    /// A launch failure is not a normal exit: say what went wrong instead of
    /// pretending the user typed `exit`.
    private var failedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Terminal failed to start")
                .font(.headline)
            if let reason = session.failureReason {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // Only the launch failures that can have a next step show one,
            // so the hint never contradicts the stated reason.
            if let suggestion = session.failureSuggestion {
                Text(suggestion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try Again") {
                session.restart()
            }
            .focused($overlayFocused)
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
