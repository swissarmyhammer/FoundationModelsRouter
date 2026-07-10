import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// A test-only ``LanguageModelSessionBackend`` shared by the stub
/// ``LoadedLLMContainer``s across the unit suite.
///
/// Every stub container in this target used to implement stateless
/// `respond`/`streamResponse` methods directly; now that generation runs
/// through a persistent backend a session holds for its whole lifetime (see
/// ``LanguageModelSessionBackend``), the stubs instead manufacture one of
/// these per session via `makeSession(instructions:)`. It returns a
/// configurable canned response (or throws a configured error) and records
/// every prompt it is asked to respond to, so a test can assert both the
/// response a session produced and the call history the backend observed.
///
/// It also maintains a synthetic ``entries`` transcript mirroring the shape a
/// real `LanguageModelSession`/``MLXFoundationModelsSessionBackend`` would
/// accumulate: when constructed with non-nil `instructions`, ``entries``
/// opens with one `.instructions` entry (matching how supplied instructions
/// become a `LanguageModelSession`'s transcript's first entry); every
/// successful `respond`/`streamResponse`/guided-`respond` call then appends a
/// `.prompt` entry followed by a `.response` entry, so ``transcriptEntries()``
/// reports the same prompt/response-pair-per-turn shape the live backend's
/// real transcript does.
///
/// ``makeFork()`` simulates transcript inheritance without a real model: the
/// returned backend starts with a *copy* of this backend's
/// ``receivedPrompts`` and ``entries`` as of fork time (mirroring how the live
/// `MLXFoundationModelsSessionBackend.makeFork()` seeds a child session from
/// the parent's accumulated transcript), then diverges independently as each
/// backend's own further calls append only to its own history.
///
/// Like the live conformance it stands in for, this is a plain mutable class
/// rather than an actor: ``RoutedSessionActor`` only ever drives one backend
/// method at a time (serialized by the model's own serial gate), so there is
/// no concurrent access to guard against in practice.
/// A ``LoadedLLMContainer`` whose `makeSession(transcript:)` has no special
/// wrapping/invariant/spy requirement beyond seeding a plain
/// ``StubSessionBackend`` from the given transcript's entries — the common
/// case shared by most stub containers across this suite. Conforming to this
/// protocol instead of ``LoadedLLMContainer`` directly gets a container this
/// implementation for free, so it only has to implement
/// `makeSession(instructions:)`.
///
/// A handful of containers wire special behavior through
/// `makeSession(instructions:)` — test-observation tracking, a
/// "no generation allowed" invariant, a maxTokens-recording spy, or a shared
/// mutable backend a test drives directly — and their `makeSession(transcript:)`
/// must mirror that same behavior rather than fall back to a bare stub. Those
/// containers implement `makeSession(transcript:)` themselves and conform to
/// ``LoadedLLMContainer`` directly instead of to this protocol.
protocol PlainTranscriptStubContainer: LoadedLLMContainer {}

extension PlainTranscriptStubContainer {
    /// Seeds a plain ``StubSessionBackend`` from `transcript`'s entries.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(entries: Array(transcript))
    }
}

final class StubSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// A failure ``respond(to:maxTokens:)``/``streamResponse(to:maxTokens:)``/
    /// the guided `respond` raise when ``shouldThrow`` is `true`.
    enum StubError: Error, Equatable {
        case boom
    }

    /// The canned text every generation entry point returns on success.
    var responseText: String

    /// When `true`, every generation entry point throws ``StubError/boom``
    /// instead of returning ``responseText``.
    var shouldThrow: Bool

    /// The number of generation calls this backend has served — every
    /// `respond`/`streamResponse`/guided `respond` call increments this,
    /// whether or not it throws.
    private(set) var callCount = 0

    /// Every prompt this backend has been asked to respond to, in call order.
    ///
    /// Seeded with a copy of the parent's history at fork time (see
    /// ``makeFork()``), so a forked backend's history begins with its
    /// parent's prompts and then grows independently with its own.
    private(set) var receivedPrompts: [String]

    /// The synthetic transcript this backend has accumulated, in order.
    ///
    /// Seeded from ``instructions`` at construction time (one leading
    /// `.instructions` entry, or none), then grown by one `.prompt` + one
    /// `.response` entry per successful turn. See ``transcriptEntries()``.
    private(set) var entries: [Transcript.Entry]

    /// Creates a stub backend.
    ///
    /// - Parameters:
    ///   - responseText: The canned text returned on success.
    ///   - shouldThrow: Whether every call should throw instead of
    ///     succeeding.
    ///   - receivedPrompts: The initial prompt history — non-empty only for a
    ///     backend born via ``makeFork()``.
    ///   - instructions: The session's system instructions, or `nil`. When
    ///     non-nil, ``entries`` opens with a single `.instructions` entry
    ///     carrying this text — mirroring how a real `LanguageModelSession`'s
    ///     transcript begins. Ignored when `entries` is supplied directly
    ///     (the fork path).
    ///   - entries: The initial transcript — non-nil only for a backend born
    ///     via ``makeFork()``, which snapshots the parent's ``entries`` as of
    ///     fork time. When `nil`, ``entries`` is derived from `instructions`.
    init(
        responseText: String = "stub response",
        shouldThrow: Bool = false,
        receivedPrompts: [String] = [],
        instructions: String? = nil,
        entries: [Transcript.Entry]? = nil
    ) {
        self.responseText = responseText
        self.shouldThrow = shouldThrow
        self.receivedPrompts = receivedPrompts
        if let entries {
            self.entries = entries
        } else if let instructions {
            self.entries = [Self.instructionsEntry(for: instructions)]
        } else {
            self.entries = []
        }
    }

    /// Records the call and returns ``responseText``, or throws
    /// ``StubError/boom`` when ``shouldThrow`` is set.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        recordPrompt(prompt)
        if shouldThrow { throw StubError.boom }
        recordResponse()
        return responseText
    }

    /// Records the call and streams ``responseText`` as a single chunk, or
    /// finishes with ``StubError/boom`` when ``shouldThrow`` is set.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        recordPrompt(prompt)
        let responseText = responseText
        let shouldThrow = shouldThrow
        if !shouldThrow {
            recordResponse()
        }
        return AsyncThrowingStream { continuation in
            if shouldThrow {
                continuation.finish(throwing: StubError.boom)
            } else {
                continuation.yield(responseText)
                continuation.finish()
            }
        }
    }

    /// Records the call, runs the real (GPU-free) grammar validation, then
    /// returns ``responseText`` — or throws ``StubError/boom`` when
    /// ``shouldThrow`` is set — mirroring the live backend's guided entry
    /// point, which validates before decoding.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        recordPrompt(prompt)
        try grammar.validateForXGrammar()
        if shouldThrow { throw StubError.boom }
        recordResponse()
        return responseText
    }

    /// Returns a new ``StubSessionBackend`` pre-seeded with a copy of
    /// ``receivedPrompts`` and ``entries`` as of this call, sharing this
    /// backend's ``responseText``/``shouldThrow`` configuration.
    func makeFork() -> any LanguageModelSessionBackend {
        StubSessionBackend(
            responseText: responseText,
            shouldThrow: shouldThrow,
            receivedPrompts: receivedPrompts,
            entries: entries
        )
    }

    /// Returns ``entries``, this backend's synthetic transcript so far.
    func transcriptEntries() -> [Transcript.Entry] {
        entries
    }

    /// Records one call's prompt into ``receivedPrompts``/``entries`` and
    /// bumps ``callCount``, shared by every generation entry point.
    private func recordPrompt(_ prompt: String) {
        callCount += 1
        receivedPrompts.append(prompt)
        entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
    }

    /// Appends a `.response` entry carrying ``responseText`` into
    /// ``entries``, called only once a turn is known to have succeeded.
    private func recordResponse() {
        entries.append(
            .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))]))
        )
    }

    /// Builds the leading `.instructions` entry a non-nil `instructions`
    /// string seeds ``entries`` with, mirroring how a real
    /// `LanguageModelSession`'s transcript carries supplied instructions as
    /// its first entry.
    private static func instructionsEntry(for instructions: String) -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: []
            )
        )
    }
}
