import Foundation

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
/// ``makeFork()`` simulates transcript inheritance without a real model: the
/// returned backend starts with a *copy* of this backend's
/// ``receivedPrompts`` as of fork time (mirroring how the live
/// `MLXFoundationModelsSessionBackend.makeFork()` seeds a child session from
/// the parent's accumulated transcript), then diverges independently as each
/// backend's own further calls append only to its own history.
///
/// Like the live conformance it stands in for, this is a plain mutable class
/// rather than an actor: ``RoutedSessionActor`` only ever drives one backend
/// method at a time (serialized by the model's own serial gate), so there is
/// no concurrent access to guard against in practice.
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

    /// Creates a stub backend.
    ///
    /// - Parameters:
    ///   - responseText: The canned text returned on success.
    ///   - shouldThrow: Whether every call should throw instead of
    ///     succeeding.
    ///   - receivedPrompts: The initial prompt history — non-empty only for a
    ///     backend born via ``makeFork()``.
    init(responseText: String = "stub response", shouldThrow: Bool = false, receivedPrompts: [String] = []) {
        self.responseText = responseText
        self.shouldThrow = shouldThrow
        self.receivedPrompts = receivedPrompts
    }

    /// Records the call and returns ``responseText``, or throws
    /// ``StubError/boom`` when ``shouldThrow`` is set.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        record(prompt)
        if shouldThrow { throw StubError.boom }
        return responseText
    }

    /// Records the call and streams ``responseText`` as a single chunk, or
    /// finishes with ``StubError/boom`` when ``shouldThrow`` is set.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        record(prompt)
        let responseText = responseText
        let shouldThrow = shouldThrow
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
        record(prompt)
        try grammar.validateForXGrammar()
        if shouldThrow { throw StubError.boom }
        return responseText
    }

    /// Returns a new ``StubSessionBackend`` pre-seeded with a copy of
    /// ``receivedPrompts`` as of this call, sharing this backend's
    /// ``responseText``/``shouldThrow`` configuration.
    func makeFork() -> any LanguageModelSessionBackend {
        StubSessionBackend(responseText: responseText, shouldThrow: shouldThrow, receivedPrompts: receivedPrompts)
    }

    /// Records one call's prompt into ``receivedPrompts`` and bumps
    /// ``callCount``, shared by every generation entry point.
    private func record(_ prompt: String) {
        callCount += 1
        receivedPrompts.append(prompt)
    }
}
