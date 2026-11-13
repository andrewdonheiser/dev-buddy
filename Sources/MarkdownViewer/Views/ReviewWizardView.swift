import AppKit
import SwiftUI

/// The review-creation wizard: the PR URL and the optional linked issue go
/// in, and on confirmation the work unit comes out — the worktree clone, a
/// terminal in it, and the PR in the browser.
struct ReviewWizardView: View {
    @EnvironmentObject private var workUnits: WorkUnitStore
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var prURLString = ""
    @State private var issueReference = ""
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review a Pull Request")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pull Request URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://github.com/owner/repo/pull/123", text: $prURLString)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Issue (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Jira key or GitHub issue URL", text: $issueReference)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cloning the pull request…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(isCreating)
                Button("Review") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    /// Validates the input, creates the work unit, then opens the PR in the
    /// browser and a terminal in its worktree.
    @MainActor
    private func create() async {
        errorMessage = nil
        guard PullRequest.parse(url: prURLString) != nil else {
            showError(ReviewError.invalidPullRequestURL.errorDescription)
            return
        }
        isCreating = true
        do {
            let unit = try await workUnits.createReview(prURLString: prURLString,
                                                        issueReference: issueReference)
            // The review opens in the browser for reading, and a terminal
            // lands the user inside the worktree — the nested world the
            // review just created.
            NSWorkspace.shared.open(unit.prURL)
            store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
            dismiss()
        } catch {
            showError(error.localizedDescription)
        }
        isCreating = false
    }

    /// Shows the failure in the sheet and announces it, so assistive
    /// technology reports the error the sighted user reads.
    private func showError(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        errorMessage = message
        AccessibilityNotification.Announcement(message).post()
    }
}
