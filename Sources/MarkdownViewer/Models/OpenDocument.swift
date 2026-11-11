import Foundation

/// A single open Markdown file and its rendered HTML.
struct OpenDocument: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var markdown: String
    var html: String
    var lastModified: Date?
    /// Incremented on every (re)render so the view can force a reload.
    var revision: Int

    init(id: UUID = UUID(), url: URL, markdown: String, html: String, lastModified: Date? = nil, revision: Int = 0) {
        self.id = id
        self.url = url
        self.markdown = markdown
        self.html = html
        self.lastModified = lastModified
        self.revision = revision
    }

    /// The file name without extension, used as the tab label.
    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// The file name including extension.
    var fileName: String {
        url.lastPathComponent
    }
}
