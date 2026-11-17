import Foundation

/// A single open Markdown file and its rendered HTML.
struct OpenDocument: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// The review work unit the document is nested under, if any;
    /// documents without one appear as top-level tabs. Only "New Markdown
    /// in Worktree" opens documents nested — files opened any other way
    /// stay top-level.
    let workUnitID: WorkUnit.ID?
    var markdown: String
    var html: String
    var lastModified: Date?
    /// Incremented on every (re)render so the view can force a reload.
    var revision: Int

    init(id: UUID = UUID(), url: URL, markdown: String, html: String, lastModified: Date? = nil, revision: Int = 0, workUnitID: WorkUnit.ID? = nil) {
        self.id = id
        self.url = url
        self.workUnitID = workUnitID
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
