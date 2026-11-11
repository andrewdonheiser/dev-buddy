import Foundation

/// An embedded terminal tab running the user's login shell.
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    /// The directory the terminal runs in.
    let workingDirectory: URL
    /// The tab label: the title the running program reports, or the
    /// directory name until then.
    var title: String

    init(id: UUID = UUID(), workingDirectory: URL, title: String? = nil) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.title = title ?? workingDirectory.lastPathComponent
    }
}
