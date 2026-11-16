import SwiftUI
import WebKit

/// The embedded browser shown in the detail column when a browser tab is
/// selected: navigation controls above the web view.
struct BrowserPane: View {
    @EnvironmentObject private var store: DocumentStore
    let browser: BrowserTab

    /// Resolved on first appear. Creating a session starts loading the
    /// page, so a speculatively constructed view value must not do it in
    /// its initializer.
    @State private var session: BrowserSession?

    var body: some View {
        Group {
            if let session {
                BrowserPaneContent(browser: browser, session: session)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if session == nil {
                // Everything browser flows through the store: it owns the
                // tab list, receives the session's title updates, and keeps
                // the session cache behind its injected seam — the view
                // never reaches into a shared singleton itself.
                session = store.browserSession(browser.id)
            }
        }
    }
}

/// The pane's content once its session is resolved.
private struct BrowserPaneContent: View {
    @EnvironmentObject private var store: DocumentStore
    let browser: BrowserTab
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                BrowserHostingView(session: session)
                if let loadError = session.loadError {
                    loadFailureMessage(loadError)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
    }

    /// The pane's distinct failure state: a failed load leaves the web
    /// view blank, so the pane says so in plain language — with the
    /// failure's reason and a way to retry — instead of looking like an
    /// empty page under the address.
    private func loadFailureMessage(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Couldn't load the page")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                session.reload()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "safari")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                session.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!session.canGoBack)
            .help("Go back to the previous page")
            .accessibilityLabel("Go back")
            Button {
                session.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!session.canGoForward)
            .help("Go forward to the next page")
            .accessibilityLabel("Go forward")
            Button {
                session.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload the page")
            .accessibilityLabel("Reload page")
            Button {
                store.closeBrowser(browser.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close browser tab")
            .accessibilityLabel("Close browser tab")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Bridges the session's long-lived web view into SwiftUI.
private struct BrowserHostingView: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> WKWebView {
        session.view
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
