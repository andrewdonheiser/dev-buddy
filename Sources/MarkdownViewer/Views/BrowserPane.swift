import Combine
import SwiftUI
import WebKit

/// The browsing session for one nested web page: its `WKWebView` plus the
/// navigation state the toolbar needs. Sessions outlive the SwiftUI view, so
/// switching to another tab and back preserves history and scroll position.
@MainActor
final class WebPageSession: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {

    let pageID: LinkedWebPage.ID
    let webView = WKWebView()

    @Published var title: String?
    @Published var currentURL: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false

    /// Streams the page title into the sidebar as the browser reports it.
    var onTitleChange: ((String) -> Void)?
    /// Streams the page's visible text into the store so the chat can quote it.
    var onTextChange: ((String) -> Void)?
    /// Opens `target="_blank"` links as new nested pages instead of popups.
    var onNewWindow: ((URL) -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init(page: LinkedWebPage) {
        self.pageID = page.id
        super.init()

        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.load(URLRequest(url: page.url))
        currentURL = page.url

        webView.publisher(for: \.title)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self, let title, !title.isEmpty else { return }
                self.title = title
                self.onTitleChange?(title)
            }
            .store(in: &cancellables)

        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.currentURL = url }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canGoBack = value }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canGoForward = value }
            .store(in: &cancellables)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            onNewWindow?(url)
        }
        return nil
    }

    // MARK: Text extraction

    /// The page's visible text, re-read from the live page. Used just before
    /// a chat message is sent so the prompt carries current content.
    func currentText() async -> String? {
        let result = try? await webView.evaluateJavaScript("document.body.innerText")
        return result as? String
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Whenever a page finishes loading (or navigating back and forward),
        // refresh the stored text for the chat.
        Task { [weak self] in
            guard let text = await self?.currentText(), !text.isEmpty else { return }
            self?.onTextChange?(text)
        }
    }
}

/// Keeps one session per nested web page, wiring it to the document store.
@MainActor
final class WebPageSessionManager {

    static let shared = WebPageSessionManager()

    private var sessions: [LinkedWebPage.ID: WebPageSession] = [:]

    func session(for page: LinkedWebPage) -> WebPageSession {
        if let existing = sessions[page.id] { return existing }
        let session = WebPageSession(page: page)
        session.onTitleChange = { title in
            DocumentStore.shared.updateWebPageTitle(id: page.id, title: title)
        }
        session.onTextChange = { text in
            DocumentStore.shared.updateWebPageText(id: page.id, text: text)
        }
        session.onNewWindow = { url in
            guard let parent = DocumentStore.shared.document(id: page.parentID) else { return }
            DocumentStore.shared.openLink(url, in: parent)
        }
        sessions[page.id] = session
        return session
    }

    func removeSession(pageID: LinkedWebPage.ID) {
        sessions[pageID] = nil
    }
}

/// The embedded browser shown in the detail column when a nested web page is
/// selected: a small toolbar (back, forward, reload) above the page.
struct BrowserPane: View {
    @EnvironmentObject private var store: DocumentStore
    let page: LinkedWebPage
    @ObservedObject private var session: WebPageSession

    init(page: LinkedWebPage) {
        self.page = page
        self._session = ObservedObject(wrappedValue: WebPageSessionManager.shared.session(for: page))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            BrowserWebView(session: session)
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                session.webView.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!session.canGoBack)
            .help("Back")

            Button {
                session.webView.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!session.canGoForward)
            .help("Forward")

            Button {
                session.webView.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload page")

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title ?? page.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.currentURL?.host ?? page.url.host ?? page.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(session.currentURL ?? page.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open in default browser")
            Button {
                store.closeWebPage(id: page.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close page")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Bridges the session's long-lived `WKWebView` into SwiftUI.
private struct BrowserWebView: NSViewRepresentable {
    let session: WebPageSession

    func makeNSView(context: Context) -> WKWebView {
        session.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
