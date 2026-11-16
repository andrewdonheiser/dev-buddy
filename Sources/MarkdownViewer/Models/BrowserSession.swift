import Combine
import WebKit

/// The running web page for one browser tab: its `WKWebView` plus the state
/// the pane header needs. Sessions outlive the SwiftUI view, so switching
/// tabs and coming back preserves the page, its history and its scroll
/// position.
///
/// Unlike the Markdown web view, the browser runs with JavaScript enabled:
/// the pages it shows need it, while rendered Markdown does not — the two
/// stay separate views so neither configuration leaks into the other.
@MainActor
final class BrowserSession: ObservableObject {

    /// The web view this session hosts, exposed read-only for
    /// `BrowserHostingView` — the SwiftUI bridge that mounts it in the
    /// pane; everything else reaches the page through the session.
    private(set) var view: WKWebView

    /// The page's title, or the URL's host until it loads.
    @Published private(set) var title: String
    /// The page currently showing, updated as the user navigates.
    @Published private(set) var url: URL
    /// Whether the page can go back / forward in its history.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    /// Receives title updates as the page loads, wired by whoever creates
    /// the session — the session never reaches into a store itself.
    private let onTitleChange: (@MainActor (String) -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL,
         initialTitle: String,
         onTitleChange: (@MainActor (String) -> Void)? = nil) {
        self.title = initialTitle
        self.url = url
        self.onTitleChange = onTitleChange
        // JavaScript stays enabled: the browser pane shows real web pages,
        // unlike the Markdown web view, which renders trusted local HTML
        // with it off.
        self.view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        observePageState()
    }

    // MARK: - Navigation

    func goBack() { view.goBack() }
    func goForward() { view.goForward() }
    func reload() { view.reload() }

    /// Stops loading and blanks the page so a closed tab releases its
    /// resources.
    func stop() {
        for observation in observations { observation.invalidate() }
        observations = []
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    // MARK: - Page state

    /// Streams the web view's title, address and history state into the
    /// published properties, and the page title into the tab list.
    /// `WKWebView` delivers key-value observation on the main thread, so
    /// the handlers re-enter the main actor explicitly.
    private func observePageState() {
        observations = [
            view.observe(\.title, options: [.initial, .new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let title = change.newValue ?? nil, !title.isEmpty else { return }
                    self?.setTitle(title)
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    if let url = change.newValue ?? nil { self?.url = url }
                }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.canGoBack = change.newValue ?? false }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.canGoForward = change.newValue ?? false }
            },
        ]
    }

    private func setTitle(_ title: String) {
        guard title != self.title else { return }
        self.title = title
        onTitleChange?(title)
    }
}
