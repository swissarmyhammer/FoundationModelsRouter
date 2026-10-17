import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^k4nygqa's host-side ambient binding: `RoutedSessionActor`
/// binds `ToolContext.$current` around every backend `respond()`/stream call,
/// carrying the session's identity, its run plane, and its own `SessionOutbox`
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
    /// read captures only after the driving answer returned.
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

    /// A backend whose `respond`/`streamResponse` hold until a cancel reaches
    /// the task that runs them, and then read the ambient context's
    /// `isCancelled` one time. The read proves that the probe of the binding
    /// mirrors the bound model-call task, and does not report a constant.
    ///
    /// The cancel of the answer cancels the model-call task first. On the
    /// `respond` path the backend runs in that task. On the streaming path
    /// the end of the cancelled consumer cancels the producer task of the
    /// stream. So when the hold ends, the model-call task is cancelled
    /// already, and the probe must report `true`.
    ///
    /// `@unchecked Sendable` on different terms than
    /// ``ContextProbingBackend``: tests read this backend's observations
    /// *while* the driving answer is still in flight (that concurrent
    /// observation is the whole point), so the observations are behind one
    /// `Mutex` (the ``ModelCallCancellationProbe`` precedent), ``changes``
    /// is a `Sendable` signal, and the only other stored property, `inner`,
    /// is an immutable reference to a ``StubSessionBackend``, which guards
    /// its own state. That guard is load-bearing here: the stream's producer
    /// task drives `inner` only after it observed the cancellation, so it
    /// appends the entries of the submission while the recording of the
    /// cancelled submission reads `inner.transcriptEntries()` on the actor
    /// (task ^9smkhk8).
    private final class CancellationObservingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// What the backend observed so far.
        private struct Observations {
            /// Whether `respond` started its hold.
            var respondStarted = false

            /// Whether the ambient probe that `respond` read reported `true`.
            var observedCancellation = false

            /// Whether the producer task of the stream started its hold.
            var streamStarted = false

            /// What the ambient probe on the streaming path reported, or
            /// `nil` before the producer task read it.
            var streamProbe: Bool?
        }

        private let inner = StubSessionBackend()

        /// The observations, behind a lock: the backend writes while the
        /// test reads.
        private let observations = Mutex(Observations())

        /// Signalled after each change of the observations.
        let changes = ChangeSignal()

        /// Whether `respond` started its hold, so a test can wait for the
        /// model call to be in flight before cancelling the answer.
        var respondStarted: Bool { observations.withLock { $0.respondStarted } }

        /// Whether the ambient probe `respond` read reported `true`.
        var observedCancellation: Bool { observations.withLock { $0.observedCancellation } }

        /// Whether the producer task of the stream started its hold, so a
        /// test can wait for the streaming model call to be in flight before
        /// cancelling the answer.
        var streamStarted: Bool { observations.withLock { $0.streamStarted } }

        /// Whether the producer task of the stream read the ambient probe.
        var streamProbeRead: Bool { observations.withLock { $0.streamProbe != nil } }

        /// Whether the ambient probe read on the streaming path reported
        /// `true`.
        var observedStreamCancellation: Bool { observations.withLock { $0.streamProbe == true } }

        /// Changes the observations, and then signals ``changes``.
        ///
        /// - Parameter change: The change.
        private func record(_ change: (inout Observations) -> Void) {
            observations.withLock { change(&$0) }
            changes.signal()
        }

        /// Holds until the calling task is cancelled, and then reads the
        /// ambient probe one time. A `nil` context (no binding) reads
        /// nothing, and the hold does not start.
        ///
        /// The hold is an event that nobody sends: only the cancel of the
        /// calling task ends it.
        ///
        /// - Parameter context: The ambient context of the call.
        /// - Returns: What the probe reported, or `false` with no context.
        private static func readProbeAfterCancel(_ context: ToolContext?) async -> Bool {
            guard let context else { return false }
            try? await AwaitedEvent().wait()
            return context.isCancelled
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            let context = ToolContext.current
            record { $0.respondStarted = true }
            let observed = await Self.readProbeAfterCancel(context)
            record { $0.observedCancellation = observed }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            // Captured at call time — inside the binding of the submission —
            // then read from the stream's own production task: the probe is
            // a plain closure, so it stays honest across the task hop, and
            // the binding contract covers the streaming entry point exactly
            // as it covers `respond`.
            let context = ToolContext.current
            let inner = self.inner
            return AsyncThrowingStream { continuation in
                let task = Task {
                    self.record { $0.streamStarted = true }
                    let observed = await Self.readProbeAfterCancel(context)
                    self.record { $0.streamProbe = observed }
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

    /// The prompt of each answer that a ``CancellationObservingBackend``
    /// holds until the cancel.
    private static let holdPrompt = "hold until the cancel"

    /// Builds a fresh router + resolved profile + vended session over a
    /// ``ContextProbingBackend`` — guided by `grammar` when supplied.
    ///
    /// The session is open when this returns: the caller closes it. When it
    /// throws, it closes the session that it made and removes the temp
    /// directory first (rule T1).
    private static func makeSession(grammar: Grammar? = nil) async throws -> (
        session: any RoutedSession, backend: ContextProbingBackend, dir: URL
    ) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = ProbingLLMContainer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(dir) {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        let session =
            if let grammar {
                profile.standard.makeGuidedSession(grammar: grammar)
            } else {
                profile.standard.makeSession()
            }
        let backend = try await RouterTestFixtures.removingDirectoryOnThrow(
            dir, alsoOnThrow: { await session.close() }
        ) {
            try #require(container.lastBackend)
        }
        return (session, backend, dir)
    }

    /// Builds a fresh router + resolved profile + vended session over a
    /// ``CancellationObservingBackend``.
    ///
    /// The session is open when this returns: the caller closes it. When it
    /// throws, it closes the session that it made and removes the temp
    /// directory first (rule T1).
    private static func makeCancellationObservingSession() async throws -> (
        session: any RoutedSession, backend: CancellationObservingBackend, dir: URL
    ) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = CancellationObservingLLMContainer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(dir) {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        let session = profile.standard.makeSession()
        let backend = try await RouterTestFixtures.removingDirectoryOnThrow(
            dir, alsoOnThrow: { await session.close() }
        ) {
            try #require(container.lastBackend)
        }
        return (session, backend, dir)
    }

    // MARK: - Tests

    @Test("respond binds ToolContext around the backend call: session identity, run plane scope, live cancellation probe")
    @MainActor
    func respondBindsToolContext() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await session.close() }

        _ = try await session.respond(to: "hello")

        let capture = try #require(backend.respondCaptures.first ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)

        // The event posted through the ambient context from inside
        // respond() landed in this session's own outbox — the binding's
        // sink is the session's SessionOutbox — stamped with the host
        // identity of the submission binding and its completionToken for
        // each submission.
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
        defer { await session.close() }

        _ = try await session.respond(to: "hello")

        let capture = try #require(backend.grammarRespondCaptures.first ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)

        // The guided entry point's posted event landed in this session's
        // own outbox with the completionToken of the submission binding.
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
        defer { await session.close() }

        for try await _ in await session.streamResponse(to: "hello") {}

        let capture = try #require(backend.streamCapture ?? nil)
        #expect(capture.sessionID == session.id)
        #expect(!capture.isCancelled)
    }

    @Test("each submission mints a fresh completionToken into its binding — run scope, never session scope")
    @MainActor
    func eachSubmissionMintsFreshCompletionToken() async throws {
        let (session, backend, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await session.close() }

        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let first = try #require(backend.respondCaptures.first ?? nil)
        let second = try #require(backend.respondCaptures.last ?? nil)
        #expect(first.completionToken != second.completionToken)
    }

    @Test("cancelling the answer flips the binding's isCancelled probe to true — it mirrors the model-call task, never a constant")
    @MainActor
    func cancellingTheAnswerFlipsTheBoundProbe() async throws {
        let (session, backend, dir) = try await Self.makeCancellationObservingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await session.close() }

        let answerTask = Task { try await session.respond(to: Self.holdPrompt) }
        // The answer ends also when the test throws before its cancel.
        defer { answerTask.cancel() }
        // The backend records the start of its hold inside the model call,
        // so the cancel below reaches a model call in flight.
        try await backend.changes.wait(until: { backend.respondStarted })
        let signal = session.cancelAll()
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))
        _ = try? await answerTask.value
        // cancelAll() ends the answer at once and does not wait for the
        // model call. The pump waits for the model-call task, and the
        // backend records its read of the probe in that task before it
        // returns. So the read is in the backend when the pump ended.
        #expect(await session.isIdleOnceThePumpEnds())

        #expect(backend.observedCancellation)
    }

    @Test("cancelling a streaming answer flips the bound probe observed on the streaming path too")
    @MainActor
    func cancellingAStreamingAnswerFlipsTheBoundProbe() async throws {
        let (session, backend, dir) = try await Self.makeCancellationObservingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await session.close() }

        let answerTask = Task {
            for try await _ in await session.streamResponse(to: Self.holdPrompt) {}
        }
        // The answer ends also when the test throws before its cancel.
        defer { answerTask.cancel() }
        // The producer task of the stream records the start of its hold, so
        // the cancel below reaches a streaming model call in flight.
        try await backend.changes.wait(until: { backend.streamStarted })
        let signal = session.cancelAll()
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))
        _ = try? await answerTask.value

        // The probe is read in the stream's own production task, which
        // outlives the cancelled submission. The backend signals the read,
        // and the test waits for that event.
        try await backend.changes.wait(until: { backend.streamProbeRead })
        #expect(backend.observedStreamCancellation)
    }
}
