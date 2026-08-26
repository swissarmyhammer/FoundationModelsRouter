import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^k4nygqa's host-side ambient binding: `RoutedSessionActor`
/// binds `ToolContext.$current` around every backend `respond()`/stream call,
/// carrying the session's identity, its mailbox, and its own `SessionOutbox`
/// as the upstream sink (eventplan.md § "The vocabulary and the host
/// substrate": "Router binds the task local around native `respond()` also").
///
/// Whether Apple's runtime propagates the task local into `Tool.call` is the
/// propagation-probe task's question — the binding here is correct either
/// way, and ``RunToCompletionRunner`` and ``BackgroundToolRunner`` also bind per
/// call regardless. These tests
/// stand a probing backend in for the runtime: it reads
/// `ToolContext.current` from inside the model call and posts through it.
@Suite("ToolContext binding around native respond()/stream")
struct RoutedSessionToolContextBindingTests {
    // MARK: - Probing backend

    /// One binding observation a generation entry point captured.
    private struct ContextCapture {
        let sessionID: ULID
        let completionToken: String
        let isCancelled: Bool
    }

    /// A backend that captures the ambient ``ToolContext`` at each
    /// generation entry point — standing in for Apple's runtime invoking a
    /// tool from inside `respond()` — and posts one `.progress` event
    /// through it, so a test can prove the binding's sink is the calling
    /// session's own outbox.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``:
    /// the owning session drives one backend method at a time, and tests
    /// read captures only after the driving turn returned.
    private final class ContextProbingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()

        /// Every ambient context `respond(to:maxTokens:)` observed, in
        /// call order — `nil` recorded when no binding was present.
        private(set) var respondCaptures: [ContextCapture?] = []

        /// Every ambient context the grammar-guided
        /// `respond(to:following:maxTokens:)` observed, in call order —
        /// `nil` recorded when no binding was present.
        private(set) var grammarRespondCaptures: [ContextCapture?] = []

        /// The ambient context the last `streamResponse(to:maxTokens:)`
        /// observed, or `nil` when no binding was present.
        private(set) var streamCapture: ContextCapture??

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if let context = ToolContext.current {
                respondCaptures.append(
                    ContextCapture(
                        sessionID: context.sessionID,
                        completionToken: context.completionToken,
                        isCancelled: context.isCancelled
                    )
                )
                await context.progress("from inside respond")
            } else {
                respondCaptures.append(nil)
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            streamCapture = ToolContext.current.map {
                ContextCapture(
                    sessionID: $0.sessionID,
                    completionToken: $0.completionToken,
                    isCancelled: $0.isCancelled
                )
            }
            return inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            // The binding contract covers *every* backend generation entry
            // point, so the guided path captures and posts exactly as the
            // plain `respond(to:maxTokens:)` above does.
            if let context = ToolContext.current {
                grammarRespondCaptures.append(
                    ContextCapture(
                        sessionID: context.sessionID,
                        completionToken: context.completionToken,
                        isCancelled: context.isCancelled
                    )
                )
                await context.progress("from inside grammar respond")
            } else {
                grammarRespondCaptures.append(nil)
            }
            return try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            inner.makeFork(tools: tools)
        }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            inner.replacingTranscript(transcript)
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends one retained ``ContextProbingBackend`` per session.
    ///
    /// `@unchecked Sendable` invariant: `lastBackend` is written once,
    /// synchronously, inside `makeSession(instructions:)` — called from the
    /// (synchronous, non-actor-isolated) session-vending path — and read
    /// only by the `@MainActor` test method after that vend returns, so the
    /// write and every read happen on the same thread, never concurrently.
    private final class ProbingLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        private(set) var lastBackend: ContextProbingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = ContextProbingBackend()
            lastBackend = backend
            return backend
        }
    }

    /// A backend whose `respond`/`streamResponse` poll the ambient
    /// context's `isCancelled` — never structured task cancellation — and
    /// return the moment the flag flips, proving the binding's probe
    /// mirrors the bound model-call task rather than reporting a constant.
    ///
    /// `@unchecked Sendable` on different terms than
    /// ``ContextProbingBackend``: tests poll this backend's observation
    /// flags *while* the driving turn is still in flight (that concurrent
    /// observation is the whole point), so every flag is a `Mutex`-guarded
    /// `Bool` (the ``ModelCallCancellationProbe`` precedent) and the only
    /// other stored property, `inner`, is an immutable reference the
    /// owning session drives one call at a time.
    private final class CancellationObservingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()

        /// How many times a polling loop re-reads the ambient flag before
        /// giving up.
        private static let pollIterations = 6_000

        /// How long each polling iteration sleeps.
        private static let pollIntervalNanoseconds: UInt64 = 5_000_000

        /// Backing storage for ``respondStarted``.
        private let respondStartedFlag = Mutex(false)

        /// Backing storage for ``observedCancellation``.
        private let observedCancellationFlag = Mutex(false)

        /// Backing storage for ``streamStarted``.
        private let streamStartedFlag = Mutex(false)

        /// Backing storage for ``observedStreamCancellation``.
        private let observedStreamCancellationFlag = Mutex(false)

        /// Flips when `respond` begins polling, so a test can wait for the
        /// model call to be in flight before cancelling the turn.
        var respondStarted: Bool { respondStartedFlag.withLock { $0 } }

        /// Whether the ambient probe `respond` polled ever reported `true`.
        var observedCancellation: Bool { observedCancellationFlag.withLock { $0 } }

        /// Flips when `streamResponse`'s production task begins polling, so
        /// a test can wait for the streaming model call to be in flight
        /// before cancelling the turn.
        var streamStarted: Bool { streamStartedFlag.withLock { $0 } }

        /// Whether the ambient probe polled on the streaming path ever
        /// reported `true`.
        var observedStreamCancellation: Bool { observedStreamCancellationFlag.withLock { $0 } }

        /// Polls the ambient probe until it reports cancellation or the
        /// iteration budget runs out, returning whether cancellation was
        /// ever observed. `nil` context — no binding — observes nothing.
        private static func pollForCancellation(_ context: ToolContext?) async -> Bool {
            guard let context else { return false }
            for _ in 0..<pollIterations {
                if context.isCancelled { return true }
                // Deliberately swallow the cancellation error: this
                // backend cooperates through the ambient flag alone.
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
            return false
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            respondStartedFlag.withLock { $0 = true }
            if await Self.pollForCancellation(ToolContext.current) {
                observedCancellationFlag.withLock { $0 = true }
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            // Captured at call time — inside the turn's binding — then
            // polled from the stream's own production task: the probe is a
            // plain closure, so it stays honest across the task hop, and
            // the binding contract covers the streaming entry point exactly
            // as it covers `respond`.
            let context = ToolContext.current
            let inner = self.inner
            return AsyncThrowingStream { continuation in
                let task = Task {
                    self.streamStartedFlag.withLock { $0 = true }
                    if await Self.pollForCancellation(context) {
                        self.observedStreamCancellationFlag.withLock { $0 = true }
                    }
                    do {
                        for try await chunk in inner.streamResponse(to: prompt, maxTokens: maxTokens) {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            inner.makeFork(tools: tools)
        }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            inner.replacingTranscript(transcript)
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends one retained ``CancellationObservingBackend`` per session.
    ///
    /// `@unchecked Sendable` invariant: `lastBackend` is written once,
    /// synchronously, inside `makeSession(instructions:)` — called from the
    /// (synchronous, non-actor-isolated) session-vending path — and read
    /// only by the `@MainActor` test method after that vend returns, so the
    /// write and every read happen on the same thread, never concurrently.
    private final class CancellationObservingLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        private(set) var lastBackend: CancellationObservingBackend?

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = CancellationObservingBackend()
            lastBackend = backend
            return backend
        }
    }

    // MARK: - Fixtures

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "RoutedSessionToolContextBindingTests"

    /// Builds a fresh router + resolved profile + vended session over a
    /// ``ContextProbingBackend`` — guided by `grammar` when supplied.
    private static func makeSession(grammar: Grammar? = nil) async throws -> (
        session: RoutedSession, backend: ContextProbingBackend, dir: URL
    ) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = ProbingLLMContainer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session =
            if let grammar {
                profile.standard.makeGuidedSession(grammar: grammar)
            } else {
                profile.standard.makeSession()
            }
        let backend = try #require(container.lastBackend)
        return (session, backend, dir)
    }

    /// Builds a fresh router + resolved profile + vended session over a
    /// ``CancellationObservingBackend``.
    private static func makeCancellationObservingSession() async throws -> (
        session: RoutedSession, backend: CancellationObservingBackend, dir: URL
    ) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = CancellationObservingLLMContainer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        let backend = try #require(container.lastBackend)
        return (session, backend, dir)
    }

    // MARK: - Tests

    @Test("respond binds ToolContext around the backend call: session identity, mailbox scope, live cancellation probe")
    @MainActor
    func respondBindsToolContext() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let capture = try #require(backend.respondCaptures.first ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)

        // The event posted through the ambient context from inside
        // respond() landed in this session's own outbox — the binding's
        // sink is the session's SessionOutbox — stamped with the turn
        // binding's host identity and its per-turn completionToken.
        let pending = await session.outbox.pending()
        let posted = try #require(pending.events.first?.event)
        #expect(posted.kind == .progress)
        #expect(posted.detail == "from inside respond")
        #expect(posted.tool == "session")
        #expect(posted.op == "respond")
        #expect(posted.correlationID == capture.completionToken)
    }

    @Test("grammar-guided respond binds the same ambient context around the backend's guided call")
    @MainActor
    func grammarRespondBindsToolContext() async throws {
        let (session, backend, dir) = try await Self.makeSession(
            grammar: .ebnf("root ::= \"yes\" | \"no\""))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let capture = try #require(backend.grammarRespondCaptures.first ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)

        // The guided entry point's posted event landed in this session's
        // own outbox with the turn binding's per-turn completionToken.
        let pending = await session.outbox.pending()
        let posted = try #require(pending.events.first?.event)
        #expect(posted.kind == .progress)
        #expect(posted.detail == "from inside grammar respond")
        #expect(posted.correlationID == capture.completionToken)
    }

    @Test("streamResponse binds the same ambient context around the backend stream call")
    @MainActor
    func streamResponseBindsToolContext() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        for try await _ in await session.streamResponse(to: "hello") {}

        let capture = try #require(backend.streamCapture ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)
    }

    @Test("each turn mints a fresh completionToken into its binding — run scope, never session scope")
    @MainActor
    func eachTurnMintsFreshCompletionToken() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let first = try #require(backend.respondCaptures.first ?? nil)
        let second = try #require(backend.respondCaptures.last ?? nil)
        #expect(first.completionToken != second.completionToken)
    }

    @Test("cancelling the turn flips the binding's isCancelled probe to true — it mirrors the model-call task, never a constant")
    @MainActor
    func cancellingTheTurnFlipsTheBoundProbe() async throws {
        let (session, backend, dir) = try await Self.makeCancellationObservingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let turn = Task { try await session.respond(to: "poll the flag") }
        for _ in 0..<600 {
            if backend.respondStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.respondStarted)
        await session.cancelCurrentTurn()
        _ = try? await turn.value

        #expect(backend.observedCancellation)
    }

    @Test("cancelling a streaming turn flips the bound probe observed on the streaming path too")
    @MainActor
    func cancellingAStreamingTurnFlipsTheBoundProbe() async throws {
        let (session, backend, dir) = try await Self.makeCancellationObservingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let turn = Task {
            for try await _ in await session.streamResponse(to: "poll the flag") {}
        }
        for _ in 0..<600 {
            if backend.streamStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.streamStarted)
        await session.cancelCurrentTurn()
        _ = try? await turn.value

        // The polling loop runs in the stream's own production task, which
        // outlives the cancelled turn briefly — wait for its observation.
        for _ in 0..<600 {
            if backend.observedStreamCancellation { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(backend.observedStreamCancellation)
    }
}
