import AppKit
import SwiftUI

/// What shows in the detail column when a workspace tab is selected: the
/// folder's header, quick actions (terminal in the workspace folder, reveal,
/// rescan), the README, and the folder's Markdown files. Clicking a file
/// opens it as a document nested under the workspace.
struct WorkspaceOverviewView: View {
    @EnvironmentObject private var store: DocumentStore
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    readmeSection
                    fileList
                    if workspace.hitFileLimit {
                        Text("File list capped at \(Workspace.fileLimit) files. Use Reveal in Finder to browse the rest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(workspace.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                // The terminal runs in the workspace folder; opencode uses it
                // as its working directory.
                store.openTerminal(in: workspace)
            } label: {
                Label("Open Terminal", systemImage: "terminal")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([workspace.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Reveal the workspace folder in Finder")
            Button {
                store.rescanWorkspace(id: workspace.id)
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Re-read the folder's Markdown files")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - README

    @ViewBuilder
    private var readmeSection: some View {
        if let readme = workspace.readme {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    store.openFile(readme.url, in: workspace)
                } label: {
                    Label("Open \(readme.fileName)", systemImage: "book")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                Text("The README anchors the workspace chat; every other file is attached too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workspace.files.count == 1 ? "1 File" : "\(workspace.files.count) Files")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if workspace.files.isEmpty {
                Text("No Markdown files found in this folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ForEach(workspace.files) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func fileRow(_ file: WorkspaceFile) -> some View {
        let isOpen = store.documents.contains { $0.url == file.url }
        return Button {
            store.openFile(file)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOpen ? "doc.text.fill" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(isOpen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if isOpen {
                    Text("Open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { store.openFile(file) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
    }
}
