import AppKit
import SwiftUI
import WebKit

/// A `WKWebView` that displays rendered Markdown HTML. In-page anchors stay
/// in the web view; every other link is handed to `onLinkClick` so the app
/// can open it nested under the document in the sidebar. When no callback is
/// given, links fall back to the user's default browser.
struct MarkdownWebView: NSViewRepresentable {

    let html: String
    /// Bumped whenever the document is (re)rendered. Ensures a manual refresh
    /// reloads the web view even when the HTML string is unchanged.
    var revision: Int = 0
    /// The document's own URL. Used as the page's base URL so relative links
    /// resolve to real file URLs and `#anchor` links stay in-page.
    var baseURL: URL? = nil
    /// Called with the destination of a clicked link.
    var onLinkClick: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.onLinkClick = onLinkClick
        context.coordinator.load(html: html, revision: revision, baseURL: baseURL, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLinkClick = onLinkClick
        context.coordinator.load(html: html, revision: revision, baseURL: baseURL, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastHTML: String?
        private var lastRevision: Int?
        private var lastBaseURL: URL?
        /// Kept current by the representable so the delegate always invokes
        /// the latest closure from SwiftUI's view update.
        var onLinkClick: ((URL) -> Void)?

        func load(html: String, revision: Int, baseURL: URL?, in webView: WKWebView) {
            guard lastHTML != html || lastRevision != revision || lastBaseURL != baseURL else { return }
            lastHTML = html
            lastRevision = revision
            lastBaseURL = baseURL
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if isSamePageAnchor(url, in: webView) {
                decisionHandler(.allow)
                return
            }

            if let onLinkClick {
                onLinkClick(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        /// True for `#fragment` links that point at the page already on
        /// screen; those scroll in place instead of navigating.
        private func isSamePageAnchor(_ url: URL, in webView: WKWebView) -> Bool {
            guard url.fragment?.isEmpty == false, let current = webView.url else { return false }
            return strippedFragment(url) == strippedFragment(current)
        }

        private func strippedFragment(_ url: URL) -> String {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url.absoluteString
            }
            components.fragment = nil
            return components.url?.absoluteString ?? url.absoluteString
        }
    }
}
