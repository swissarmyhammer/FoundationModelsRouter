import Foundation
import FoundationModels

/// A live session object vended by a ``LoadedLLMContainer`` factory.
///
/// Where a ``LoadedLLMContainer`` used to expose stateless, one-shot generation
/// methods directly, it now only *manufactures* backends through
/// ``LoadedLLMContainer/makeSession(instructions:)``; every generation call runs
/// through the backend it returns instead. This is the seam
/// ``RoutedSessionActor`` drives: a backend is born holding this session's
/// system instructions and — once a real conversation-preserving conformer
/// lands — accumulates conversation state (the transcript) across calls, so a
/// second ``respond(to:maxTokens:)`` sees the first turn's content the way a
/// real multi-turn chat does. ``makeFork()`` is the seam a
/// ``RoutedSession/fork(workingDirectory:)`` calls to produce a child backend
/// that begins from this session's accumulated transcript and then diverges
/// independently.
///
/// It is class-bound and `Sendable` so a session (an actor) can hold one across
/// isolation boundaries.
public protocol LanguageModelSessionBackend: AnyObject, Sendable {
    /// Generates a complete text response to a prompt.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the backend's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: If the generation fails.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the backend's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Generates a complete, grammar-constrained text response.
    ///
    /// Guided output is whole-chunk: there is no constrained streaming variant.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - grammar: The grammar constraining the output.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the backend's own default ceiling.
    /// - Returns: The constrained text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, or if the
    ///   generation fails.
    func respond(
        to prompt: String,
        following grammar: Grammar,
        maxTokens: Int?
    ) async throws -> String

    /// Produces a new backend seeded from this session's accumulated transcript.
    ///
    /// The returned backend begins with this session's conversation history and
    /// then diverges independently — the seam ``RoutedSession/fork(workingDirectory:)``
    /// runs through so a forked child sees its parent's turns so far without the
    /// two sharing any further state.
    ///
    /// - Returns: A new, independent backend seeded from this session's history.
    func makeFork() -> any LanguageModelSessionBackend

    /// Produces a new backend seeded from this session's accumulated transcript,
    /// with `tools` threaded to whatever model-facing session the fork
    /// constructs — the overload ``RoutedSession/fork(workingDirectory:)`` calls
    /// with its own fork-then-connect composed tool list (the child's originals,
    /// each forked via ``ForkableTool/forked()`` where applicable and reconnected
    /// to the child's own outbox via ``EventEmittingTool/connecting(_:)``), so a
    /// conformer whose model can actually call tools (``MLXFoundationModelsSessionBackend``)
    /// hands the live model the child's own instances rather than silently
    /// carrying the parent's forward — the same principle that motivates
    /// ``RoutedSession/fork(workingDirectory:)`` in the first place, applied to
    /// the model-facing session instead of just the actor's own bookkeeping list.
    ///
    /// Defaulted to ignore `tools` and forward to ``makeFork()`` unchanged, so
    /// every existing conformer that does not model live tool-calling (every
    /// stub backend in the unit suite) keeps its prior behavior with no changes
    /// of its own required.
    ///
    /// - Parameter tools: The tools to thread into the fork's model-facing
    ///   session, in place of whatever tools this backend itself was built
    ///   with.
    /// - Returns: A new, independent backend seeded from this session's
    ///   history, with `tools` threaded to its model-facing session.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend

    /// The backend's current full transcript, in order.
    ///
    /// **Only safe to call while holding the model's serial gate**
    /// (``RoutedModel/serialGate``) — the same discipline ``makeFork()``
    /// requires, since a concrete conformer (e.g. `MLXFoundationModelsSessionBackend`)
    /// reads this straight off a live, mutable session that a concurrent
    /// generation call could otherwise still be appending to.
    ///
    /// - Returns: Every transcript entry this backend has accumulated so far,
    ///   in order.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry]

    /// The backend's cumulative input/output token usage so far, or `nil`
    /// when the backend cannot report usage.
    ///
    /// **Only safe to call while holding the model's serial gate**
    /// (``RoutedModel/serialGate``) — the same discipline ``transcriptEntries()``
    /// requires, since a concrete conformer (e.g.
    /// `MLXFoundationModelsSessionBackend`) reads this straight off a live,
    /// mutable session that a concurrent generation call could otherwise
    /// still be updating.
    ///
    /// The counts are the backend's running totals since the session began,
    /// not a per-turn delta — ``RoutedSessionActor``'s `generate(grammar:_:)`
    /// chokepoint is what turns two of these snapshots, taken immediately
    /// before and after a turn, into that turn's own `tokensIn`/`tokensOut`.
    ///
    /// - Returns: The backend's cumulative `(input, output)` token counts so
    ///   far, or `nil` when the backend cannot report usage.
    func usageTokenCounts() -> (input: Int, output: Int)?

    /// Produces a new backend over the same underlying model, seeded from
    /// `transcript` instead of this backend's own accumulated history.
    ///
    /// Unlike ``makeFork()``/``makeFork(tools:)``, which continue an existing
    /// conversation by seeding a new backend from *this* backend's own
    /// accumulated transcript, this reseeds from an arbitrary transcript —
    /// the mechanism ``RoutedSessionActor/compact(prompt:budget:)`` swaps its
    /// inner session through in place once folding actually changes
    /// something (compaction_plan.md §1.4, "swap the inner Apple session"):
    /// `transcript` there is `Compactor`'s folded output, and the swap keeps
    /// this session's identity (same actor, same nonisolated `id`, same
    /// recorder) untouched — only the backend driving generation changes.
    ///
    /// Also the mechanism a fresh, disposable one-shot summarizer call is
    /// built over: seeding from an *empty* transcript yields a blank-slate
    /// backend for the same resident model, with no accumulated history to
    /// either leak between independent calls or double up against the very
    /// content being summarized.
    ///
    /// - Parameter transcript: The transcript to seed the new backend from.
    /// - Returns: A new, independent backend over the same underlying model,
    ///   whose accumulated history begins with `transcript`'s entries.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend
}

extension LanguageModelSessionBackend {
    /// Default ``makeFork(tools:)``: ignores `tools` and forwards to
    /// ``makeFork()`` unchanged.
    ///
    /// Every conformer across the unit suite stands in for a backend whose
    /// model cannot actually call tools at all (see each stub's own doc
    /// comment), so none of them need to know about `tools` threading — they
    /// pick up this default and keep behaving exactly as ``makeFork()``
    /// already defined, with no changes of their own required.
    /// ``MLXFoundationModelsSessionBackend`` is the one conformer whose model
    /// really can call tools, so it overrides this instead of relying on the
    /// default.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeFork()
    }

    /// Default ``replacingTranscript(_:)``: ignores `transcript` and forwards
    /// to ``makeFork()`` unchanged.
    ///
    /// Every stub conformer across the unit suite stands in for a backend
    /// whose owning session never exercises ``RoutedSessionActor/compact(prompt:budget:)``
    /// (that surface's own suite drives ``StubSessionBackend`` directly), so
    /// none of them need real transcript-reseeding behavior — they pick up
    /// this default and keep behaving exactly as ``makeFork()`` already
    /// defined, with no changes of their own required.
    /// ``StubSessionBackend``/``MLXFoundationModelsSessionBackend`` are the
    /// conformers that override this with a real implementation.
    func replacingTranscript(_ transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        makeFork()
    }
}
