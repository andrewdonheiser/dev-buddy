import MarkdownViewerKit
import SwiftUI

/// Root view: the vertical tab bar on the left, rendered Markdown in the
/// middle and the document chat panel on the right.
struct MainView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var labels: LabelStore
    @EnvironmentObject private var options: ViewOptions

    /// Whether the right-hand chat panel is showing.
    @AppStorage(ChatPanel.visibleKey) private var chatVisible = true

    var body: some View {
        NavigationSplitView {
            TabSidebarView()
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    chatVisible.toggle()
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .help(chatVisible ? "Hide chat panel" : "Show chat panel")
            }
            ToolbarItem(placement: .primaryAction) {
                ViewOptionsMenu()
            }
        }
        .tint(options.currentTheme.map { HexColor.color($0.accent) })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            store.handleDrop(providers: providers)
        }
        .onOpenURL { url in
            store.open(url: url)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let terminal = store.selectedTerminal {
            // A terminal tab keeps the chat panel on screen, bound to the
            // selected document, or to the workspace it was opened from.
            if chatVisible, let target = store.chatTarget {
                HSplitView {
                    TerminalPane(terminal: terminal)
                        .id(terminal.id)
                    chatPanel(for: target)
                }
            } else {
                TerminalPane(terminal: terminal)
                    .id(terminal.id)
            }
        } else if let page = store.selectedWebPage, let document = store.selectedDocument {
            // A nested web page keeps the chat panel on screen, bound to its
            // parent document's conversation.
            if chatVisible {
                HSplitView {
                    BrowserPane(page: page)
                        .id(page.id)
                    chatPanel(for: .document(document))
                }
            } else {
                BrowserPane(page: page)
                    .id(page.id)
            }
        } else if let workspace = store.selectedWorkspace {
            // The workspace overview keeps the chat panel on screen, bound to
            // the workspace: its README plus every file as context.
            if chatVisible {
                HSplitView {
                    WorkspaceOverviewView(workspace: workspace)
                        .id(workspace.id)
                    chatPanel(for: .workspace(workspace))
                }
            } else {
                WorkspaceOverviewView(workspace: workspace)
                    .id(workspace.id)
            }
        } else if let document = store.selectedDocument {
            if chatVisible {
                HSplitView {
                    documentColumn(for: document)
                    chatPanel(for: .document(document))
                }
            } else {
                documentColumn(for: document)
            }
        } else {
            EmptyStateView()
        }
    }

    /// The chat panel for a document or workspace. For a document,
    /// attachments cover the files checked in the sidebar plus everything
    /// nested under it — linked Markdown files and web pages. For a
    /// workspace, the README is the main document and every other Markdown
    /// file in the folder is attached (within a size budget).
    private func chatPanel(for target: DocumentStore.ChatTarget) -> some View {
        Group {
            switch target {
            case .document(let document):
                ChatSidebarView(documentPath: document.url.path,
                                documentName: document.fileName,
                                documentText: store.draft(for: document.id) ?? document.markdown,
                                attachedDocuments: store.chatContextAttachments(for: document),
                                contextRefresher: { await store.refreshedChatContext(for: document) })
            case .workspace(let workspace):
                ChatSidebarView(documentPath: workspace.url.path,
                                documentName: workspace.title,
                                documentText: store.readmeText(for: workspace),
                                attachedDocuments: store.workspaceChatAttachments(for: workspace),
                                contextRefresher: nil)
            }
        }
        .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
    }

    private func documentColumn(for document: OpenDocument) -> some View {
        VStack(spacing: 0) {
            header(for: document)
            Divider()
            if store.isEditing(document.id) {
                MarkdownEditorView(text: draftBinding(for: document))
                    .id(document.id)
            } else {
                MarkdownWebView(html: document.html,
                                revision: document.revision,
                                baseURL: document.url) { url in
                    store.openLink(url, in: document)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
        .overlay(alignment: .bottomTrailing) {
            if !store.isEditing(document.id) {
                ThemeCycleButton()
                    .padding(20)
            }
        }
    }

    /// Two-way binding between the editor and the document's edit buffer.
    private func draftBinding(for document: OpenDocument) -> Binding<String> {
        Binding(
            get: { store.draft(for: document.id) ?? document.markdown },
            set: { store.updateDraft(document.id, text: $0) }
        )
    }

    private func header(for document: OpenDocument) -> some View {
        let names = labels.labels(containing: document.url.path).map(\.name).sorted()
        let editing = store.isEditing(document.id)
        return HStack(spacing: 8) {
            Text(document.fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if !names.isEmpty {
                LabelPills(names: names)
            }
            Menu {
                LabelMenuItems(path: document.url.path)
            } label: {
                Image(systemName: "tag")
                    .font(.system(size: 11))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Labels")
            Spacer()
            if editing {
                editControls(for: document)
            }
            Button {
                store.toggleEditing(document.id)
            } label: {
                Image(systemName: editing ? "doc.text" : "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help(editing ? "Finish editing" : "Edit the Markdown source")
            Text(document.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Save/discard controls shown in the header while the document is edited.
    private func editControls(for document: OpenDocument) -> some View {
        HStack(spacing: 8) {
            if store.isDraftDirty(document.id) {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Cancel") {
                store.endEditing(document.id)
            }
            .controlSize(.small)
            Button("Save") {
                store.save(document.id)
            }
            .controlSize(.small)
            .disabled(!store.isDraftDirty(document.id))
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No Markdown file open")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Open File…") {
                store.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("Open Workspace…") {
                store.presentWorkspacePanel()
            }
            Text("or drag a .md file or a folder here")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
