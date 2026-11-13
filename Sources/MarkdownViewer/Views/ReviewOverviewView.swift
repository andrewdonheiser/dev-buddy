import AppKit
import SwiftUI

/// The detail column for a selected review work unit: what the wizard
/// recorded, where its worktree lives, and the actions on the review.
struct ReviewOverviewView: View {
    @EnvironmentObject private var workUnits: WorkUnitStore
    @EnvironmentObject private var store: DocumentStore
    let unit: WorkUnit

    @State private var isDeleteConfirmPresented = false
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    factRows
                    Divider()
                    actions
                    if let deleteError {
                        Text(deleteError)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
            }
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
        .confirmationDialog("Delete this review?",
                            isPresented: $isDeleteConfirmPresented,
                            titleVisibility: .visible) {
            Button("Delete Review and Worktree", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The worktree at \(unit.worktreePath) will be removed from disk, and terminals running in it will be closed. This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(unit.isArchived ? "Archived review" : "Pull request review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The wizard's inputs and their results, as read-only rows.
    @ViewBuilder
    private var factRows: some View {
        factRow("Pull request", value: unit.prURL.absoluteString,
                help: "Open the pull request in your browser") {
            openInBrowser()
        }
        if let issue = unit.issueReference, !issue.isEmpty {
            factRow("Linked issue", value: issue, action: nil)
        }
        factRow("Worktree", value: unit.worktreePath,
                help: "Reveal the worktree in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([unit.worktreeURL])
        }
    }

    private func factRow(_ label: String,
                         value: String,
                         help: String? = nil,
                         action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let action {
                Button(action: action) {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.link)
                .help(help ?? value)
            } else {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    openInBrowser()
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button {
                    store.openTerminal(in: unit.worktreeURL, workUnitID: unit.id)
                } label: {
                    Label("New Terminal in Worktree", systemImage: "terminal")
                }
            }
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([unit.worktreeURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                if unit.isArchived {
                    Button {
                        workUnits.unarchive(unit.id)
                        workUnits.select(unit.id)
                    } label: {
                        Label("Restore Review", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        workUnits.archive(unit.id)
                    } label: {
                        Label("Archive Review", systemImage: "archivebox")
                    }
                    .help("Archiving saves the review away but keeps its worktree on disk")
                }
                Spacer()
                Button(role: .destructive) {
                    isDeleteConfirmPresented = true
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
        }
    }

    private func openInBrowser() {
        NSWorkspace.shared.open(unit.prURL)
    }

    /// Deletes the review: its terminals close first (the confirmation above
    /// says they will), then the record and the worktree go.
    private func delete() {
        deleteError = nil
        for terminal in store.terminals where terminal.workUnitID == unit.id {
            store.closeTerminal(terminal.id)
        }
        do {
            try workUnits.delete(unit.id)
        } catch {
            deleteError = "The review's files could not be removed: \(error.localizedDescription)"
        }
    }
}
