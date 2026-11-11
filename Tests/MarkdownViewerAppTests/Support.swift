import Foundation
import MarkdownViewerChat
@testable import MarkdownViewer

/// A `Keychain` that keeps secrets in memory so tests never touch the real one.
final class InMemoryKeychain: Keychain {
    private var storage: [String: String] = [:]

    func setSecret(_ secret: String, account: String) throws {
        storage[account] = secret
    }

    func secret(account: String) throws -> String? {
        storage[account]
    }

    func contains(account: String) -> Bool {
        storage[account] != nil
    }

    func deleteSecret(account: String) {
        storage[account] = nil
    }
}

/// A `UserDefaults` suite scoped to one test.
func makeScratchDefaults() -> UserDefaults {
    let name = "MarkdownViewerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Captures the requests a `ChatStore` makes and lets each test decide how the
/// reply streams back.
@MainActor
final class StreamRecorder {
    private(set) var requests: [LLMClient.Request] = []

    var handler: (LLMClient.Request) -> AsyncThrowingStream<String, Error> = { _ in
        AsyncThrowingStream { $0.finish() }
    }

    func stream(_ request: LLMClient.Request) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        return handler(request)
    }

    /// A reply that delivers `chunks` immediately and finishes.
    static func immediate(_ chunks: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

/// A stream whose delivery the test controls, for exercising in-flight state.
@MainActor
final class ManualStream {
    let stream: AsyncThrowingStream<String, Error>
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    init() {
        var captured: AsyncThrowingStream<String, Error>.Continuation?
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func emit(_ chunk: String) { continuation?.yield(chunk) }
    func finish() { continuation?.finish() }
    func fail(_ error: Error) { continuation?.finish(throwing: error) }
}

/// A chat store wired to scratch storage, an in-memory keychain and a recorder.
@MainActor
struct ChatFixture {
    let defaults: UserDefaults
    let keychain: InMemoryKeychain
    let settings: ChatSettings
    let keys: APIKeyStore
    let recorder: StreamRecorder
    let chat: ChatStore

    init(apiKey: String? = "sk-test") {
        defaults = makeScratchDefaults()
        keychain = InMemoryKeychain()
        settings = ChatSettings(defaults: defaults)
        keys = APIKeyStore(defaults: defaults, keychain: keychain)
        recorder = StreamRecorder()
        if let apiKey {
            try? keys.save(secret: apiKey)
        }
        chat = ChatStore(settings: settings, keys: keys, stream: { [recorder] in recorder.stream($0) })
    }
}

/// Polls `condition` until it holds or `timeout` elapses. Tests run on the main
/// actor, so yielding here lets the store's streaming task make progress.
@MainActor
@discardableResult
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
