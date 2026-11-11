import MarkdownViewerChat
import Testing
@testable import MarkdownViewer

@Suite("Chat store")
@MainActor
struct ChatStoreTests {

    private let path = "/docs/note.md"

    private func messages(_ chat: ChatStore) -> [ChatStore.Message] {
        chat.conversation(for: path).messages
    }

    @Test("a reply is streamed into a single assistant message")
    func streamsReply() async {
        let fixture = ChatFixture()
        fixture.recorder.handler = { _ in StreamRecorder.immediate(["Hello", " world"]) }

        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)

        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        let result = messages(fixture.chat)
        #expect(result.count == 2)
        #expect(result.first?.role == .user)
        #expect(result.first?.text == "hi")
        #expect(result.last?.role == .assistant)
        #expect(result.last?.text == "Hello world")
    }

    @Test("the assistant message records the model that produced it")
    func recordsModel() async {
        let fixture = ChatFixture()
        fixture.settings.model = "gpt-4o-mini"
        fixture.recorder.handler = { _ in StreamRecorder.immediate(["ok"]) }

        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)

        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        #expect(messages(fixture.chat).last?.model == "gpt-4o-mini")
    }

    @Test("the request carries the system prompt, model and coalesced turns")
    func buildsRequest() async {
        let fixture = ChatFixture()
        fixture.settings.model = "gpt-4o-mini"
        fixture.recorder.handler = { _ in StreamRecorder.immediate(["ok"]) }

        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: "# Title")
        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })

        let request = fixture.recorder.requests.first
        #expect(request?.model == "gpt-4o-mini")
        #expect(request?.system?.contains("# Title") == true)
        #expect(request?.turns == [.init(role: "user", content: "hi")])
    }

    @Test("stopping a reply keeps the text that had already streamed")
    func stopKeepsPartial() async {
        let fixture = ChatFixture()
        let stream = ManualStream()
        fixture.recorder.handler = { _ in stream.stream }

        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)
        stream.emit("partial")
        #expect(await waitUntil { fixture.chat.conversation(for: self.path).streamingText == "partial" })

        fixture.chat.stopStreaming(in: path)

        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        #expect(messages(fixture.chat).last?.text == "partial")
    }

    @Test("a failure keeps the partial reply and surfaces the error")
    func failureKeepsPartial() async {
        let fixture = ChatFixture()
        let stream = ManualStream()
        fixture.recorder.handler = { _ in stream.stream }

        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)
        stream.emit("half")
        #expect(await waitUntil { fixture.chat.conversation(for: self.path).streamingText == "half" })

        stream.fail(LLMClient.ClientError.invalidResponse)

        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        let conversation = fixture.chat.conversation(for: path)
        #expect(conversation.messages.last?.text == "half")
        #expect(conversation.errorMessage != nil)
    }

    @Test("a failed send leaves the next request with alternating turns")
    func coalescesAfterFailure() async {
        let fixture = ChatFixture()
        fixture.recorder.handler = { _ in StreamRecorder.immediate([]) }

        // First send fails before any text arrives, leaving a lone user turn.
        fixture.chat.send("first", in: path, documentName: "note.md", documentText: nil)
        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })

        fixture.chat.send("second", in: path, documentName: "note.md", documentText: nil)
        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })

        let request = fixture.recorder.requests.last
        #expect(request?.turns.count == 1)
        #expect(request?.turns.first?.role == "user")
        #expect(request?.turns.first?.content == "first\n\nsecond")
    }

    @Test("sending without a key still posts, for local servers that need none")
    func sendsWithoutKey() async {
        let fixture = ChatFixture(apiKey: nil)
        fixture.recorder.handler = { _ in StreamRecorder.immediate([]) }

        let started = fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)

        #expect(started)
        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        let request = fixture.recorder.requests.first
        #expect(request?.apiKey == "")
    }

    @Test("a whitespace-only prompt is ignored")
    func blankPrompt() async {
        let fixture = ChatFixture()

        fixture.chat.send("   \n  ", in: path, documentName: "note.md", documentText: nil)

        #expect(fixture.chat.conversation(for: path).messages.isEmpty)
        #expect(fixture.recorder.requests.isEmpty)
    }

    @Test("clearing forgets the conversation")
    func clearResets() async {
        let fixture = ChatFixture()
        fixture.recorder.handler = { _ in StreamRecorder.immediate(["ok"]) }
        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)
        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })

        fixture.chat.clear(for: path)

        #expect(fixture.chat.conversation(for: path).messages.isEmpty)
        #expect(fixture.chat.conversation(for: path).streamingText == nil)
    }

    @Test("clearing mid-stream then resending yields only the new reply")
    func clearThenResend() async {
        let fixture = ChatFixture()
        let first = ManualStream()
        let second = ManualStream()
        fixture.recorder.handler = { _ in first.stream }

        fixture.chat.send("one", in: path, documentName: "note.md", documentText: nil)
        first.emit("x")
        #expect(await waitUntil { fixture.chat.conversation(for: self.path).streamingText == "x" })

        fixture.chat.clear(for: path)
        fixture.recorder.handler = { _ in second.stream }
        fixture.chat.send("two", in: path, documentName: "note.md", documentText: nil)
        second.emit("b")
        second.emit("c")
        second.finish()

        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        #expect(messages(fixture.chat).map(\.text) == ["two", "bc"])
    }

    @Test("a replaced stream's chunks and completion are ignored")
    func replacedStreamIsIgnored() {
        let fixture = ChatFixture()

        // Two runs for the same document: the second replaces the first, as
        // when a reply is cleared and a new one is started.
        let first = fixture.chat.beginStream(for: path, model: "m1")
        let second = fixture.chat.beginStream(for: path, model: "m2")

        fixture.chat.append("stale", in: first)
        fixture.chat.finishStreaming(first)

        fixture.chat.append("live", in: second)
        fixture.chat.finishStreaming(second)

        #expect(fixture.chat.conversation(for: path).messages.map(\.text) == ["live"])
        #expect(fixture.chat.conversation(for: path).messages.first?.model == "m2")
    }

    @Test("sending while a reply is streaming is refused")
    func sendWhileStreaming() async {
        let fixture = ChatFixture()
        let stream = ManualStream()
        fixture.recorder.handler = { _ in stream.stream }

        fixture.chat.send("one", in: path, documentName: "note.md", documentText: nil)
        #expect(await waitUntil { fixture.chat.conversation(for: self.path).isStreaming })

        let started = fixture.chat.send("two", in: path, documentName: "note.md", documentText: nil)
        #expect(started == false)

        stream.finish()
        #expect(await waitUntil { !fixture.chat.conversation(for: self.path).isStreaming })
        #expect(messages(fixture.chat).map(\.text) == ["one"])
    }

    @Test("the in-flight model is reported while a reply streams")
    func reportsActiveStreamModel() async {
        let fixture = ChatFixture()
        fixture.settings.model = "gpt-x"
        let stream = ManualStream()
        fixture.recorder.handler = { _ in stream.stream }

        fixture.chat.send("hi", in: path, documentName: "note.md", documentText: nil)

        #expect(await waitUntil { fixture.chat.activeStreamModel(for: self.path) == "gpt-x" })
        stream.finish()
        #expect(await waitUntil { fixture.chat.activeStreamModel(for: self.path) == nil })
    }
}
