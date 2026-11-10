import Foundation

/// A web page opened by clicking a link inside a rendered document. Shown as
/// a nested item under that document in the sidebar and displayed in the
/// embedded browser pane.
struct LinkedWebPage: Identifiable, Equatable {
    let id: UUID
    /// The document whose link was clicked.
    let parentID: OpenDocument.ID
    let url: URL
    /// The page title, updated as the embedded browser loads it.
    var title: String
    /// The page's visible text, extracted by the browser session so the chat
    /// can quote it. `nil` until the page has loaded.
    var text: String?

    init(id: UUID = UUID(), parentID: OpenDocument.ID, url: URL, title: String? = nil, text: String? = nil) {
        self.id = id
        self.parentID = parentID
        self.url = url
        self.title = title ?? url.host ?? url.absoluteString
        self.text = text
    }
}
