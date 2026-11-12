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
        .alert("Close this terminal?",
               isPresented: Binding(
                   get: { store.pendingCloseTerminalID != nil },
                   set: { if !$0 { store.cancelCloseTerminal() } }
               ),
               presenting: store.pendingCloseTerminal) { _ in
            Button("Close Terminal", role: .destructive) { store.confirmCloseTerminal() }
            Button("Cancel", role: .cancel) { store.cancelCloseTerminal() }
        } message: { terminal in
            Text("\"\(terminal.title)\" — \(terminal.workingDirectory.path). The shell and its running programs will be terminated.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let terminal = store.selectedTerminal {
            // A terminal tab keeps the chat panel on screen, bound to the
            // selected document when one is open.
            chatSplit(TerminalPane(terminal: terminal)
                .id(terminal.id),
                document: store.selectedDocument)
        } else if let document = store.selectedDocument {
            chatSplit(documentColumn(for: document), document: document)
        } else {
            EmptyStateView()
        }
    }

    /// The chat panel beside `content`, sharing `document`'s chat context.
    /// Used by both the document and terminal detail columns so the panel's
    /// frame and bindings live in one place.
    @ViewBuilder
    private func chatSplit<Content: View>(_ content: Content, document: OpenDocument?) -> some View {
        if chatVisible, let document {
            HSplitView {
                content
                ChatSidebarView(documentPath: document.url.path,
                                documentName: document.fileName,
                                documentText: document.markdown)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            }
        } else {
            content
        }
    }

    private func documentColumn(for document: OpenDocument) -> some View {
        VStack(spacing: 0) {
            header(for: document)
            Divider()
            MarkdownWebView(html: document.html, revision: document.revision)
        }
        .frame(minWidth: 380, idealWidth: 720, minHeight: 300)
        .overlay(alignment: .bottomTrailing) {
            ThemeCycleButton()
                .padding(20)
        }
    }

    private func header(for document: OpenDocument) -> some View {
        let names = labels.labels(containing: document.url.path).map(\.name).sorted()
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
            Button("New Terminal") {
                store.openTerminalTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            Text("or drag a .md file here")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
