import Foundation
import MarkdownViewerChat

/// Holds one conversation per document and drives streaming replies.
///
/// Conversations are kept in memory for the life of the app, keyed by the
/// document's path, so switching tabs (or reopening a file) keeps its chat.
@MainActor
final class ChatStore: ObservableObject {

    static let shared = ChatStore()

    /// Opens a chat completion and yields the reply text as it streams in.
    /// Injectable so tests can supply a scripted reply instead of the network.
    typealias Streamer = (LLMClient.Request) -> AsyncThrowingStream<String, Error>

    enum Role: String, Sendable {
        case user
        case assistant
    }

    struct Message: Identifiable, Equatable {
        let id: UUID
        var role: Role
        var text: String
        var createdAt: Date
        /// The model that produced an assistant reply, so a past reply keeps
        /// its own label even after the user switches models.
        var model: String?

        init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date(), model: String? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.createdAt = createdAt
            self.model = model
        }
    }

    struct Conversation: Identifiable, Equatable {
        /// The document path this conversation belongs to.
        let id: String
        var messages: [Message] = []
        /// The reply so far while a request is streaming; `nil` when idle.
        var streamingText: String?
        var errorMessage: String?

        var isStreaming: Bool { streamingText != nil }
    }

    @Published private(set) var conversations: [String: Conversation] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Identifies the current stream per document, so a finishing task never
    /// clears the handle of a newer one that has already replaced it.
    private var streamIDs: [String: UUID] = [:]
    /// The model the in-flight request is using, so the streaming row can be
    /// labelled with it even if the user switches models mid-reply.
    private var streamModels: [String: String] = [:]
    private let settings: ChatSettings
    private let keys: APIKeyStore
    private let stream: Streamer

    init(settings: ChatSettings? = nil,
         keys: APIKeyStore? = nil,
         stream: @escaping Streamer = { LLMClient.stream($0) }) {
        self.settings = settings ?? .shared
        self.keys = keys ?? .shared
        self.stream = stream
    }

    // MARK: - Reading

    func conversation(for path: String) -> Conversation {
        conversations[path] ?? Conversation(id: path)
    }

    /// The model the reply currently streaming for `path` is being written by.
    func activeStreamModel(for path: String) -> String? {
        streamModels[path]
    }

    // MARK: - Editing

    func dismissError(for path: String) {
        update(path) { $0.errorMessage = nil }
    }

    /// Forgets the conversation, keeping the document open.
    func clear(for path: String) {
        tasks[path]?.cancel()
        tasks[path] = nil
        streamIDs[path] = nil
        streamModels[path] = nil
        conversations[path] = Conversation(id: path)
    }

    // MARK: - Sending

    /// Appends `prompt` as a user message and starts streaming a reply.
    /// Returns `false` when nothing was sent (a blank prompt, or a reply already
    /// streaming), so the caller can keep the draft.
    @discardableResult
    func send(_ prompt: String,
              in path: String,
              documentName: String,
              documentText: String?) -> Bool {
        var conversation = conversation(for: path)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !conversation.isStreaming else { return false }

        let apiKey = keys.secret() ?? ""

        conversation.messages.append(Message(role: .user, text: prompt))
        conversation.errorMessage = nil
        conversation.streamingText = ""
        conversations[path] = conversation

        let request = LLMClient.Request(
            model: settings.resolvedModel,
            baseURL: settings.resolvedBaseURL,
            apiKey: apiKey,
            system: systemPrompt(documentName: documentName, documentText: documentText),
            turns: LLMClient.coalescing(conversation.messages.map {
                LLMClient.Turn(role: $0.role.rawValue, content: $0.text)
            })
        )

        startStreaming(request, in: path)
        return true
    }

    /// Cancels an in-flight reply, keeping whatever text has arrived so far.
    func stopStreaming(in path: String) {
        tasks[path]?.cancel()
    }

    private func startStreaming(_ request: LLMClient.Request, in path: String) {
        tasks[path]?.cancel()

        let run = beginStream(for: path, model: request.model)
        tasks[path] = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.stream(request) {
                    self.append(chunk, in: run)
                }
                self.finishStreaming(run)
            } catch {
                if Task.isCancelled || error is CancellationError || Self.isCancellation(error) {
                    self.finishStreaming(run)
                } else {
                    self.fail(with: error, in: run)
                }
            }
            // Only the newest stream for this document owns the handle.
            self.release(run)
        }
    }

    // MARK: - Streaming steps
    //
    // A run identifies one stream for a document. Every step checks that its
    // run still owns the document, so a task that was cancelled and replaced
    // (see `clear`) can never touch the conversation its successor now owns.

    /// The identity of one streaming run for a document.
    struct StreamRun: Equatable {
        let path: String
        let id: UUID
        let model: String
    }

    /// Registers a new run for `path`, replacing any current one.
    @discardableResult
    func beginStream(for path: String, model: String) -> StreamRun {
        let run = StreamRun(path: path, id: UUID(), model: model)
        streamIDs[path] = run.id
        streamModels[path] = model
        return run
    }

    func append(_ chunk: String, in run: StreamRun) {
        guard streamIDs[run.path] == run.id else { return }
        update(run.path) { $0.streamingText = ($0.streamingText ?? "") + chunk }
    }

    /// Turns the streamed text into an assistant message.
    func finishStreaming(_ run: StreamRun) {
        guard streamIDs[run.path] == run.id else { return }
        update(run.path) { conversation in
            let reply = conversation.streamingText ?? ""
            conversation.streamingText = nil
            guard !reply.isEmpty else { return }
            conversation.messages.append(Message(role: .assistant, text: reply, model: run.model))
        }
    }

    /// Keeps the partial reply, then surfaces the failure.
    func fail(with error: Error, in run: StreamRun) {
        guard streamIDs[run.path] == run.id else { return }
        update(run.path) { conversation in
            let reply = conversation.streamingText ?? ""
            conversation.streamingText = nil
            if !reply.isEmpty {
                conversation.messages.append(Message(role: .assistant, text: reply, model: run.model))
            }
            conversation.errorMessage = Self.describe(error)
        }
    }

    /// Releases `run`'s handle once it finishes, if it is still the current one.
    private func release(_ run: StreamRun) {
        guard streamIDs[run.path] == run.id else { return }
        streamIDs[run.path] = nil
        tasks[run.path] = nil
        streamModels[run.path] = nil
    }

    // MARK: - Helpers

    private func update(_ path: String, _ change: (inout Conversation) -> Void) {
        var conversation = conversation(for: path)
        change(&conversation)
        conversations[path] = conversation
    }

    private static func isCancellation(_ error: Error) -> Bool {
        (error as? URLError)?.code == .cancelled
    }

    private static func describe(_ error: Error) -> String {
        if error is LLMClient.ClientError { return error.localizedDescription }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection."
            case .timedOut:
                return "The request timed out."
            case .cannotFindHost, .cannotConnectToHost:
                return "Could not reach the API endpoint. Check the base URL in Settings."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// The prompt preamble: how to answer, plus the document itself when the
    /// user has asked for it to be included.
    private func systemPrompt(documentName: String, documentText: String?) -> String {
        var prompt = """
        You are a helpful assistant discussing the Markdown document "\(documentName)" with the user. \
        Answer in Markdown, be concise, and stay focused on the document unless asked otherwise.
        """

        guard settings.includeDocument,
              let text = documentText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return prompt
        }

        let limit = 20_000
        let body = text.count > limit
            ? String(text.prefix(limit)) + "\n\n…[document truncated]"
            : text

        prompt += "\n\nThe document's current contents are below, between the markers.\n"
        prompt += "<document name=\"\(documentName)\">\n\(body)\n</document>"
        return prompt
    }
}
