import Foundation

/// A pull request URL and the pieces needed to check it out, parsed from the
/// GitHub URL the user pastes into the review wizard.
struct PullRequest: Equatable {
    /// The `owner/repo` slug of the repository the PR lives in.
    let repository: String
    /// The pull request number.
    let number: Int

    /// Parses a GitHub pull request URL such as
    /// `https://github.com/owner/repo/pull/123`, returning nil for anything
    /// else. The scheme is optional, `www.` is tolerated, and trailing path
    /// segments after the number (e.g. `/files`) are accepted.
    static func parse(url string: String) -> PullRequest? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://" + trimmed
        guard let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        // owner / repo / pull / number — the PR's own URL, not its files tab.
        guard parts.count >= 4,
              parts[2].lowercased() == "pull" || parts[2].lowercased() == "pulls",
              let number = Int(parts[3]), number > 0 else { return nil }
        let repository = parts[1].lowercased().hasSuffix(".git")
            ? String(parts[1].dropLast(4))
            : parts[1]
        // Path components arrive percent-decoded, so a pasted slug can
        // contain characters GitHub never allows (spaces, encoded slashes,
        // "..") — and everything later built from the slug (the PR URL,
        // the clone URL, the unit's directory name) assumes it cannot.
        // Reject anything outside GitHub's own name alphabet.
        guard Self.isValidName(parts[0]), Self.isValidName(repository) else { return nil }
        return PullRequest(repository: "\(parts[0])/\(repository)", number: number)
    }

    /// The characters GitHub allows in owner and repository names.
    private static let nameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Whether `name` is a possible GitHub owner or repository name. This
    /// is also the guarantee that keeps the URLs and directory names built
    /// from a parsed slug well-formed.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { nameCharacters.contains($0) }
    }

    /// The canonical `https` URL of the PR, for opening in the browser.
    var url: URL {
        // `parse(url:)` rejects names outside GitHub's alphabet, so the
        // interpolated slug is always URL-safe and this cannot be nil.
        URL(string: "https://github.com/\(repository)/pull/\(number)")!
    }

    /// The URL the repository is cloned from.
    var cloneURL: URL {
        // Same guarantee as `url`: the slug is name-alphabet only.
        URL(string: "https://github.com/\(repository).git")!
    }

    /// The work unit's sidebar label, e.g. "owner/repo #123".
    var title: String {
        "\(repository) #\(number)"
    }
}

/// One PR review: the nested world the wizard creates — its git worktree on
/// disk, the terminals opened in it, and the metadata the wizard collected.
struct WorkUnit: Identifiable, Codable, Equatable {
    let id: UUID
    /// The pull request under review, as the wizard received it.
    let prURL: URL
    /// The optional Jira key or GitHub issue the reviewer linked, verbatim.
    var issueReference: String?
    /// The label shown in the sidebar, e.g. "owner/repo #123".
    var title: String
    /// Where the unit's git worktree lives, under the managed reviews folder.
    let worktreePath: String
    /// When the review was created.
    let createdAt: Date
    /// When the review was archived, if it was — archiving keeps the
    /// worktree so the review can be reopened later.
    var archivedAt: Date?

    init(id: UUID = UUID(),
         prURL: URL,
         issueReference: String? = nil,
         title: String,
         worktreePath: String,
         createdAt: Date = Date(),
         archivedAt: Date? = nil) {
        self.id = id
        self.prURL = prURL
        self.issueReference = issueReference
        self.title = title
        self.worktreePath = worktreePath
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    /// The worktree directory as a URL.
    var worktreeURL: URL { URL(fileURLWithPath: worktreePath) }

    /// Whether the review has been archived away.
    var isArchived: Bool { archivedAt != nil }
}
