import Foundation

/// A serializable snapshot of one open tab and everything nested under it:
/// the web pages opened from its links, terminal tabs, and the Markdown files
/// they led to, recursively. Used by session restore and saved views.
struct TabSnapshot: Codable, Equatable {
    /// The Markdown file backing the tab.
    var path: String
    /// Whether the tab's nested items were expanded in the sidebar.
    var expanded: Bool
    /// URLs of the web pages opened from this document, in click order.
    var webPageURLs: [String]
    /// Markdown files opened through links, in click order.
    var markdownChildren: [TabSnapshot]
    /// Terminals nested under this document. Optional so snapshots saved
    /// before terminals existed still decode.
    var terminals: [TerminalTabSnapshot]?
}

/// A serializable snapshot of one terminal tab. The tab keeps its ID across
/// restores so the on-screen selection can be re-applied.
struct TerminalTabSnapshot: Codable, Equatable {
    var id: UUID
    var directory: String
}

/// A serializable snapshot of one workspace tab and everything nested under
/// it: the Markdown files opened from it and their subtrees, plus terminals.
struct WorkspaceSnapshot: Codable, Equatable {
    var id: UUID
    var directory: String
    var expanded: Bool
    var markdownChildren: [TabSnapshot]
    var terminals: [TerminalTabSnapshot]
}

/// Which item was on screen when a session or view was saved: the document,
/// and when one of its web pages or terminals was showing, that item.
struct SelectionSnapshot: Codable, Equatable {
    var documentPath: String?
    var webPageURL: String?
    var terminalID: UUID?
    /// The workspace that was showing, if any. Optional so snapshots saved
    /// before workspaces existed still decode.
    var workspaceID: UUID?
}
