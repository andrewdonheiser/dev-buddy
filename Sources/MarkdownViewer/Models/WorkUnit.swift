import Foundation

/// A pull request URL and the pieces needed to check it out, parsed from the
/// GitHub URL the user pastes into the review wizard.
struct PullRequest: Equatable {
    /// The `owner/repo` slug of the repository the PR lives in.
    let repository: String
    /// The pull request number.
    let number: Int

    /// Creates a pull request reference from an `owner/repo` slug and a PR
    /// number, or nil when the slug is not a well-formed GitHub repository
    /// slug — two plain components of GitHub's character set, never `.`,
    /// `..` or anything else that could escape the managed reviews folder.
    /// This is the guarantee that keeps `url` and `cloneURL` valid URLs.
    init?(repository: String, number: Int) {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard number > 0,
              components.count == 2,
              components.allSatisfy({ Self.isRepositoryComponent(String($0)) })
        else { return nil }
        self.repository = repository
        self.number = number
    }

    /// Whether a path component is a legal GitHub owner or repository name:
    /// ASCII letters, digits, `.`, `-` or `_` — plain characters that cannot
    /// form a path fragment.
    private static func isRepositoryComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "." && component != ".."
            && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

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
        return PullRequest(repository: "\(parts[0])/\(repository)", number: number)
    }

    /// The canonical `https` URL of the PR, for opening in the browser.
    var url: URL {
        // The initializer validated the slug and number, so this string is
        // always a valid URL.
        URL(string: "https://github.com/\(repository)/pull/\(number)")!
    }

    /// The URL the repository is cloned from.
    var cloneURL: URL {
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
