import Foundation
import FoundationModels

/// One piece of a streamed response. It continues the response so far, or it
/// begins a new one.
///
/// The element type of ``LanguageModelSessionBackend/streamResponseFragments(to:maxTokens:)``.
/// A tool-using turn can close one response and start a new one. An
/// accumulator uses ``restartsResponse`` to drop the superseded text.
public struct ResponseFragment: Sendable, Equatable {
    /// The new text this fragment adds.
    let text: String

    /// `true` when this fragment begins a new response that supersedes every
    /// fragment delivered so far this turn.
    let restartsResponse: Bool

    /// Creates a fragment.
    ///
    /// - Parameters:
    ///   - text: The new text this fragment adds.
    ///   - restartsResponse: Whether this fragment begins a new response. Defaults to `false`.
    init(text: String, restartsResponse: Bool = false) {
        self.text = text
        self.restartsResponse = restartsResponse
    }
}

/// A live session object that a ``LoadedLLMContainer`` makes through
/// ``LoadedLLMContainer/makeSession(instructions:)``.
///
/// A backend holds the session's system instructions and accumulates the
/// transcript across calls. ``makeFork()`` makes a child backend that starts
/// from this transcript and then diverges.
///
/// It is class-bound and `Sendable` so an actor can hold one across isolation
/// boundaries.
public protocol LanguageModelSessionBackend: AnyObject, Sendable {
    /// Generates a complete text response to `prompt`. A `nil` `maxTokens`
    /// uses the backend default.
    ///
    /// - Returns: The model's complete text response.
    /// - Throws: If the generation fails.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to `prompt` as it is produced. A `nil`
    /// `maxTokens` uses the backend default.
    ///
    /// - Returns: A stream of text chunks. It throws if generation fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Streams a text response as ``ResponseFragment``s. A backend that
    /// abandons one response and begins another mid-turn reports that here.
    ///
    /// The default implementation maps every chunk of
    /// ``streamResponse(to:maxTokens:)`` to a continuing fragment. Only a
    /// backend that can restart a response overrides it.
    ///
    /// - Returns: A stream of response fragments. It throws if generation fails.
    func streamResponseFragments(
        to prompt: String,
        maxTokens: Int?
    ) -> AsyncThrowingStream<ResponseFragment, Error>

    /// Generates a complete text response to `prompt` that `grammar`
    /// constrains. There is no constrained streaming variant.
    ///
    /// - Returns: The constrained text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, or if the generation fails.
    func respond(
        to prompt: String,
        following grammar: Grammar,
        maxTokens: Int?
    ) async throws -> String

    /// Produces a new backend seeded from this session's accumulated transcript.
    /// The new backend then diverges and shares no further state.
    ///
    /// - Returns: A new, independent backend seeded from this session's history.
    func makeFork() -> any LanguageModelSessionBackend

    /// Produces a new backend seeded from this session's accumulated transcript,
    /// with `tools` given to the fork's model-facing session.
    ///
    /// The default ignores `tools` and forwards to ``makeFork()``.
    ///
    /// - Parameter tools: The tools for the fork's model-facing session.
    /// - Returns: A new, independent backend seeded from this session's history.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend

    /// The backend's current full transcript, in order.
    ///
    /// Call this only while the owning session's turn lock
    /// (``RoutedSessionActor/turnLock``) is held. The one exception is a tool
    /// call of the owning session's own turn
    /// (``RoutedSessionActor/isInsideOwnTurnToolCall``), where no concurrent
    /// writer exists.
    ///
    /// - Returns: Every transcript entry this backend has accumulated so far.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry]

    /// The backend's cumulative input/output token usage, or `nil` when the
    /// backend cannot report usage.
    ///
    /// Call this only while the owning session's turn lock
    /// (``RoutedSessionActor/turnLock``) is held. The counts are running
    /// totals since the session began, not a per-turn delta.
    ///
    /// - Returns: The cumulative `(input, output)` token counts, or `nil`.
    func usageTokenCounts() -> (input: Int, output: Int)?

    /// Produces a new backend over the same underlying model, seeded from
    /// `transcript` instead of this backend's own history. An empty
    /// `transcript` gives a blank-slate backend.
    ///
    /// - Parameter transcript: The transcript to seed the new backend from.
    /// - Returns: A new, independent backend whose history begins with `transcript`.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend
}

/// Drives an `AsyncThrowingStream<String, Error>` iterator from the task that
/// calls ``next()``, so ``streamResponseFragments(to:maxTokens:)`` relays
/// chunks without a second, independently-cancellable consumer task.
///
/// `@unchecked Sendable`: `iterator` is mutated without a lock. This is sound
/// because an `AsyncThrowingStream` has one active reader at a time.
private final class ChunkIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<String, Error>.Iterator

    init(_ stream: AsyncThrowingStream<String, Error>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> String? {
        try await iterator.next()
    }
}

extension LanguageModelSessionBackend {
    /// Default ``streamResponseFragments(to:maxTokens:)``: every chunk of
    /// ``streamResponse(to:maxTokens:)`` becomes a continuing fragment.
    ///
    /// The stream is pull-based. A relay `Task` would be a second
    /// cancellable consumer, and a propagated cancellation could drop a chunk
    /// it had already received. Pulling from the iterator directly removes
    /// that race.
    ///
    /// - Returns: A stream of continuing fragments, one per underlying chunk.
    func streamResponseFragments(
        to prompt: String,
        maxTokens: Int?
    ) -> AsyncThrowingStream<ResponseFragment, Error> {
        let chunks = ChunkIterator(streamResponse(to: prompt, maxTokens: maxTokens))
        return AsyncThrowingStream {
            guard let chunk = try await chunks.next() else { return nil }
            return ResponseFragment(text: chunk)
        }
    }

    /// Default ``makeFork(tools:)``: ignores `tools` and forwards to
    /// ``makeFork()``.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeFork()
    }

    /// Default ``replacingTranscript(_:)``: ignores `transcript` and forwards
    /// to ``makeFork()``.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeFork()
    }
}
