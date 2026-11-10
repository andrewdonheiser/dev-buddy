import Foundation

/// An embedded terminal tab running the OpenCode TUI. Terminal tabs can be
/// top-level or nested under the document or workspace they were opened from.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    /// What this terminal was opened from, when nested; `nil` for a top-level
    /// tab. A workspace-nested terminal runs in the workspace folder — the
    /// working directory opencode uses.
    let parentID: TabParent?
    /// The directory the terminal runs in.
    let workingDirectory: URL
    /// The tab label: the title the running program reports, or the
    /// directory name until then.
    var title: String

    init(id: UUID = UUID(),
         parentID: TabParent?,
         workingDirectory: URL,
         title: String? = nil) {
        self.id = id
        self.parentID = parentID
        self.workingDirectory = workingDirectory
        self.title = title ?? workingDirectory.lastPathComponent
    }
}
