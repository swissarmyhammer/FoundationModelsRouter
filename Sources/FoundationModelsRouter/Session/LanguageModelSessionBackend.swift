import Foundation
import FoundationModels

/// One piece of a streamed response. It continues the response so far, or it
/// begins a new one.
///
/// The element type of ``LanguageModelSessionBackend/streamResponseFragments(to:maxTokens:)``.
/// A tool-using turn can close one response and start a new one. An
/// accumulator uses ``restartsResponse`` to drop the superseded text.
///
/// A fragment can also report progress with no new text: a snapshot that adds
/// a tool call, a tool result, or a reasoning entry to the transcript. That
/// fragment has an empty ``text`` and a ``progress`` other than
/// ``GenerationProgressKind/fragment``.
public struct ResponseFragment: Sendable, Equatable {
    /// The new text this fragment adds.
    public let text: String

    /// `true` when this fragment begins a new response that supersedes every
    /// fragment delivered so far this turn.
    public let restartsResponse: Bool

    /// The kind of append this fragment reports to the stall watch.
    public let progress: GenerationProgressKind

    /// Creates a fragment.
    ///
    /// - Parameters:
    ///   - text: The new text this fragment adds.
    ///   - restartsResponse: `true` when this fragment begins a new response.
    ///   - progress: The kind of append this fragment reports.
    public init(text: String, restartsResponse: Bool = false, progress: GenerationProgressKind = .fragment) {
        self.text = text
        self.restartsResponse = restartsResponse
        self.progress = progress
    }
}

/// What the newest stream snapshot of a generating method held: the
/// transcript entries the method appended so far, and the usage of its
/// newest generation call.
///
/// The value of ``LanguageModelSessionBackend/inFlightResponse()``. The
/// entries are a copy, not the bounds of a slice of the session's transcript,
/// so they stay valid after the session drops them.
public struct InFlightResponse: Sendable {
    /// The entries the method appended so far, in transcript order.
    public let entries: [Transcript.Entry]

    /// The input token count of the newest generation call.
    public let inputTokens: Int

    /// The output token count of the newest generation call.
    public let outputTokens: Int

    /// Makes the value.
    ///
    /// - Parameters:
    ///   - entries: The entries the method appended so far.
    ///   - inputTokens: The input token count of the newest generation call.
    ///   - outputTokens: The output token count of the newest generation call.
    public init(entries: [Transcript.Entry], inputTokens: Int, outputTokens: Int) {
        self.entries = entries
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// The context of the newest generation call: its input and its output.
    var contextTokens: Int {
        inputTokens + outputTokens
    }
}

/// A live session object that a ``LoadedLLMContainer`` makes through
/// ``LoadedLLMContainer/makeSession(instructions:)``.
///
/// A backend holds the session's system instructions and accumulates the
/// transcript across calls. On every generating method below, a `nil`
/// `maxTokens` means the backend's own default.
///
/// It is class-bound and `Sendable` so an actor can hold one across isolation
/// boundaries.
public protocol LanguageModelSessionBackend: AnyObject, Sendable {
    /// Generates a complete text response to `prompt`.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Generates a complete text response to `prompt`, with the model's
    /// reasoning turned off for this call only when the model can turn it off.
    ///
    /// A compaction's summarizer call uses it. A reasoning model can spend the
    /// whole ceiling of that call on its reasoning, and then it writes no
    /// summary. There is a default implementation: it calls
    /// ``respond(to:maxTokens:)``. Only a backend that can turn reasoning off
    /// overrides it.
    func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to `prompt` as it is produced.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Streams a text response as ``ResponseFragment``s. A backend that
    /// abandons one response and begins another mid-turn reports that here.
    ///
    /// There is a default implementation. Only a backend that can restart a
    /// response overrides it.
    func streamResponseFragments(
        to prompt: String,
        maxTokens: Int?
    ) -> AsyncThrowingStream<ResponseFragment, Error>

    /// Generates a complete text response to `prompt` that `grammar`
    /// constrains. There is no constrained streaming variant.
    ///
    /// - Throws: ``GuidedRequestError`` when `grammar` is invalid.
    func respond(
        to prompt: String,
        following grammar: Grammar,
        maxTokens: Int?
    ) async throws -> String

    /// Produces a new backend seeded from this session's accumulated
    /// transcript. The new backend then diverges and shares no further state.
    func makeFork() -> any LanguageModelSessionBackend

    /// ``makeFork()``, with `tools` given to the fork's model-facing session.
    ///
    /// The default ignores `tools` and forwards to ``makeFork()``.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend

    /// The backend's current full transcript, in order.
    ///
    /// Call this only while the owning session's turn lock
    /// (``RoutedSessionActor/turnLock``) is held. The one exception is a tool
    /// call of the owning session's own turn
    /// (``RoutedSessionActor/isInsideOwnTurnToolCall``), where no concurrent
    /// writer exists.
    ///
    /// The turn lock does not end a stream's producer. A turn cut short
    /// mid-stream stops consuming and records itself at once, while the
    /// producer behind ``streamResponse(to:maxTokens:)`` can still be
    /// running. A backend whose producer writes the transcript from a task of
    /// its own must guard the transcript, so this call sees a turn whole or
    /// not at all.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry]

    /// The backend's cumulative input/output token usage, or `nil` when the
    /// backend cannot report usage.
    ///
    /// Call this only while the owning session's turn lock
    /// (``RoutedSessionActor/turnLock``) is held. The one exception is a tool
    /// call of the owning session's own turn, where the model waits in the
    /// tool and no concurrent writer exists
    /// (``RoutedSessionActor/reportGenerationCallAtToolOpen()``). The counts
    /// are running totals since the session began, not a per-turn delta.
    func usageTokenCounts() -> (input: Int, output: Int)?

    /// The output token count of the last generation call that the most
    /// recent generating method of this backend made, or `nil` when the
    /// backend cannot tell.
    ///
    /// One generating method can make more than one generation call: a call
    /// that asks for a tool is followed by one more call after the tool runs.
    /// ``usageTokenCounts()`` sums all those calls. This count is the output of
    /// the last call alone, so a reader can tell whether that call spent its
    /// token ceiling.
    ///
    /// A backend gives `nil` when it has no count of that call, when a
    /// generating method started and did not yet give one, and when its
    /// transcript no longer ends where that call ended.
    ///
    /// Call this only while the owning session's turn lock
    /// (``RoutedSessionActor/turnLock``) is held.
    ///
    /// There is a default implementation that gives `nil`.
    func lastGenerationCallOutputTokenCount() -> Int?

    /// What the newest stream snapshot of the generating method in flight
    /// held, or `nil` when the backend has no snapshot of it.
    ///
    /// `LanguageModelSession` keeps no entry of a call that throws. A session
    /// that stops a model call at a tool result reads the entries of that
    /// call here, before and after the stop.
    ///
    /// There is a default implementation that gives `nil`.
    func inFlightResponse() -> InFlightResponse?

    /// The transcript of this backend each time it changes, from the moment
    /// of the call, while the stream is iterated.
    ///
    /// The stream snapshots of `LanguageModelSession` show no reasoning while
    /// the reasoning grows, but the observable transcript of the session does.
    /// A session that watches a call in flight for repetition reads the
    /// reasoning and the text here (task ^1hcwaqy). The values come from the
    /// task that generates, so a backend must guard its transcript, as
    /// ``transcriptEntries()`` states. Values that come faster than the reader
    /// reads can merge into one value.
    ///
    /// There is a default implementation that finishes at once, with no
    /// value. A backend with no observable transcript gives no update, and
    /// its calls are not watched.
    func transcriptUpdates() -> AsyncStream<[FoundationModels.Transcript.Entry]>

    /// Produces a new backend over the same underlying model, seeded from
    /// `transcript` instead of this backend's own history. An empty
    /// `transcript` gives a blank-slate backend.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend
}

/// Drives an `AsyncThrowingStream<String, Error>` iterator from the task that
/// calls ``next()``.
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
    /// Default ``respondWithoutReasoning(to:maxTokens:)``: a backend with no
    /// control of reasoning calls ``respond(to:maxTokens:)``.
    public func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    /// Default ``streamResponseFragments(to:maxTokens:)``: every chunk of
    /// ``streamResponse(to:maxTokens:)`` becomes a continuing fragment.
    ///
    /// The stream is pull-based. A relay `Task` would be a second cancellable
    /// consumer, and a propagated cancellation could drop a chunk it had
    /// already received. Pulling from the iterator directly removes that race.
    public func streamResponseFragments(
        to prompt: String,
        maxTokens: Int?
    ) -> AsyncThrowingStream<ResponseFragment, Error> {
        let chunks = ChunkIterator(streamResponse(to: prompt, maxTokens: maxTokens))
        return AsyncThrowingStream {
            guard let chunk = try await chunks.next() else { return nil }
            return ResponseFragment(text: chunk)
        }
    }

    /// Default ``lastGenerationCallOutputTokenCount()``: `nil`, because a
    /// backend that does not override it has no count of one call.
    public func lastGenerationCallOutputTokenCount() -> Int? {
        nil
    }

    /// Default ``inFlightResponse()``: `nil`, because a backend that does not
    /// override it keeps no snapshot.
    public func inFlightResponse() -> InFlightResponse? {
        nil
    }

    /// Default ``transcriptUpdates()``: a stream that finishes at once,
    /// because a backend that does not override it has no observable
    /// transcript.
    public func transcriptUpdates() -> AsyncStream<[FoundationModels.Transcript.Entry]> {
        AsyncStream { $0.finish() }
    }

    /// Default ``makeFork(tools:)``: ignores `tools` and forwards to
    /// ``makeFork()``.
    public func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeFork()
    }

    /// Default ``replacingTranscript(_:)``: ignores `transcript` and forwards
    /// to ``makeFork()``.
    public func replacingTranscript(
        _ transcript: FoundationModels.Transcript
    ) -> any LanguageModelSessionBackend {
        makeFork()
    }
}
