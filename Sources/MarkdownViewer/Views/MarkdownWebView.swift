import AppKit
import SwiftUI
import WebKit

/// A `WKWebView` that displays rendered Markdown HTML. Internal (fragment and
/// `#`-anchor) navigation stays in the web view; external links go to
/// `onOpenLink` when one is given, otherwise to the user's default browser.
struct MarkdownWebView: NSViewRepresentable {

    let html: String
    /// Bumped whenever the document is (re)rendered. Ensures a manual refresh
    /// reloads the web view even when the HTML string is unchanged.
    var revision: Int = 0
    /// Receives external link clicks — the seam the in-app browser tabs
    /// route through. When nil, links open in the user's default browser.
    var onOpenLink: ((URL) -> Void)? = nil

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
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.load(html: html, revision: revision, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.load(html: html, revision: revision, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastHTML: String?
        private var lastRevision: Int?
        var onOpenLink: ((URL) -> Void)?

        func load(html: String, revision: Int, in webView: WKWebView) {
            guard lastHTML != html || lastRevision != revision else { return }
            lastHTML = html
            lastRevision = revision
            webView.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if url.scheme == "about", url.fragment != nil {
                decisionHandler(.allow)
                return
            }

            if let onOpenLink {
                onOpenLink(url)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
