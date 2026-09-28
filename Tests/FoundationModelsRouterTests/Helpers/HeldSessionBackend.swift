import FoundationModels

@testable import FoundationModelsRouter

/// A backend whose generation call does not return until the test releases
/// it: a model call that hangs.
///
/// The call sends ``entered`` when it starts, so a test knows that the
/// submission is open and waits in the backend. The call then waits for
/// ``release``. The two waits are real signals, not the clock: a busy
/// machine makes a wait longer, never wrong. A test that never releases the
/// call cancels it, and the call throws ``EventNeverArrived``.
///
/// Each ``AwaitedEvent`` allows one waiter, so the backend serves one
/// generation call.
final class HeldSessionBackend: LanguageModelSessionBackend {
    /// Sent when the generation call starts.
    let entered = AwaitedEvent()

    /// Sent by the test to let the generation call return.
    let release = AwaitedEvent()

    /// The backend that gives the answer and the transcript after the
    /// release.
    private let inner = StubSessionBackend()

    /// Whether the stream of ``streamResponse(to:maxTokens:)`` gave its one
    /// chunk.
    private let streamed = FirstCallFlag()

    /// Sends ``entered``, waits for ``release``, then answers as a
    /// ``StubSessionBackend`` does.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        entered.signal()
        try await release.wait()
        return try await inner.respond(to: prompt, maxTokens: maxTokens)
    }

    /// Streams the answer of ``respond(to:maxTokens:)`` as one chunk.
    ///
    /// The stream is pull-based, so no relay task outlives the consumer.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [streamed] in
            guard streamed.take() else { return nil }
            return try await self.respond(to: prompt, maxTokens: maxTokens)
        }
    }

    /// Answers as a ``StubSessionBackend`` does, with no hold: a guided call
    /// is not the call that the test holds.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
    }

    /// Forks the inner backend.
    func makeFork() -> any LanguageModelSessionBackend {
        inner.makeFork()
    }

    /// The transcript of the inner backend.
    func transcriptEntries() -> [Transcript.Entry] {
        inner.transcriptEntries()
    }

    /// The usage of the inner backend.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        inner.usageTokenCounts()
    }
}
