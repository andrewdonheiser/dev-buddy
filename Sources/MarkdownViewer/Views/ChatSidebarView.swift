import MarkdownViewerKit
import SwiftUI

/// The right-hand vertical panel: a full chat interface for discussing the
/// selected document with an LLM.
///
/// The prompt being typed lives in `ChatDraftStore`, and every row is an
/// `Equatable` view. Typing still re-runs this view's body, but SwiftUI skips
/// the unchanged rows' bodies, so a keystroke — or a streamed chunk — does not
/// re-parse the rest of the transcript.
struct ChatSidebarView: View {
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var settings: ChatSettings
    @EnvironmentObject private var keys: APIKeyStore
    @EnvironmentObject private var drafts: ChatDraftStore

    /// Identifies the conversation (the document's path).
    let documentPath: String
    let documentName: String
    /// The document's current Markdown, sent along when context is enabled.
    let documentText: String?

    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "Summarize this document",
        "List the key points as bullets",
        "Explain the structure and headings"
    ]

    private var conversation: ChatStore.Conversation {
        chat.conversation(for: documentPath)
    }

    private var draft: String {
        drafts.draft(for: documentPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Discuss")
                        .font(.headline)
                    Text(documentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                contextToggle
                Button {
                    chat.clear(for: documentPath)
                    drafts.clear(for: documentPath)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(conversation.messages.isEmpty && !conversation.isStreaming)
                .help("Start a new chat")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Chat and API key settings")
            }

            HStack(spacing: 6) {
                Label(settings.resolvedModel, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Model for this conversation — change it in Settings")
                if !keys.hasKey {
                    SettingsLink {
                        Label("Add API key", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .help("No API key saved — open Settings to add one")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Whether the document's text is attached to each prompt.
    private var contextToggle: some View {
        Toggle(isOn: $settings.includeDocument) {
            Image(systemName: settings.includeDocument ? "doc.text.fill" : "doc.text")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(settings.includeDocument
              ? "The document is sent with every message"
              : "Document text is not sent; the assistant sees the conversation only")
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty, !conversation.isStreaming {
                        emptyState
                    }
                    ForEach(conversation.messages) { message in
                        row(for: message)
                    }
                    if let streaming = conversation.streamingText {
                        AssistantRow(text: streaming,
                                     model: chat.activeStreamModel(for: documentPath)
                                         ?? settings.resolvedModel,
                                     isStreaming: true)
                            .equatable()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: conversation.messages.count) { scrollToBottom(proxy) }
            .onChange(of: conversation.streamingText) { scrollToBottom(proxy) }
        }
    }

    private static let bottomID = "chat-bottom"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Ask this document anything")
                .font(.headline)
            Text("Replies stream in as they are written. \(settings.includeDocument ? "The document's text is sent with each message." : "Only the conversation is sent to the model.")")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        drafts.setDraft(suggestion, for: documentPath)
                        inputFocused = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(for message: ChatStore.Message) -> some View {
        switch message.role {
        case .user:
            UserRow(text: message.text)
                .equatable()
        case .assistant:
            AssistantRow(text: message.text,
                         model: message.model ?? "",
                         isStreaming: false)
                .equatable()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = conversation.errorMessage {
                errorBanner(error)
            }
            HStack(alignment: .top, spacing: 8) {
                promptField
                sendButton
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            PromptEditor(text: draftBinding, isFocused: $inputFocused) {
                send()
            }
            .frame(height: 72)

            if draft.isEmpty {
                Text("Ask about \(documentName)…")
                    .foregroundStyle(.placeholder)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private var sendButton: some View {
        Button {
            if conversation.isStreaming {
                chat.stopStreaming(in: documentPath)
            } else {
                send()
            }
        } label: {
            Image(systemName: conversation.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !conversation.isStreaming)
        .help(conversation.isStreaming ? "Stop" : "Send (Return)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                chat.dismissError(for: documentPath)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    // MARK: - Actions

    private var draftBinding: Binding<String> {
        Binding(
            get: { drafts.draft(for: documentPath) },
            set: { drafts.setDraft($0, for: documentPath) }
        )
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !conversation.isStreaming
    }

    private func send() {
        guard canSend else { return }
        let prompt = draft
        // Keep the draft if the send did not start (a blank prompt or a reply
        // already streaming).
        if chat.send(prompt, in: documentPath, documentName: documentName, documentText: documentText) {
            drafts.clear(for: documentPath)
        }
        inputFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !conversation.messages.isEmpty || conversation.isStreaming else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
}

// MARK: - Rows

/// A prompt bubble. `Equatable` so it is not re-rendered when other messages
/// change.
private struct UserRow: View, Equatable {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 28)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                )
        }
    }
}

/// An assistant reply. `Equatable` so an unchanged reply is not re-rendered (or
/// re-parsed) when a new chunk arrives for the streaming row or the user types.
private struct AssistantRow: View, Equatable {
    let text: String
    let model: String
    let isStreaming: Bool

    /// Shared so a transcript redrawn for another reason reuses rendered replies.
    private static let markdown = ChatMarkdownCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    Text(model)
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }

            if text.isEmpty, isStreaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                // While streaming, the text changes every chunk, so caching its
                // prefixes would only churn the cache; render it directly.
                let rendered = isStreaming
                    ? ChatMarkdown.attributedString(from: text)
                    : Self.markdown.attributedString(from: text)
                Text(rendered)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
