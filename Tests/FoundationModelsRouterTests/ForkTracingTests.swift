import Foundation
import FoundationModels
import InMemoryTracing
import Synchronization
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^k8x4q6q: every ``RoutedSession/fork(workingDirectory:)``
/// call opens one span through `swift-distributed-tracing`.
///
/// The span opens as the first statement of the fork, so it covers the whole
/// call and not only the part that succeeds: a fork the reentry guard refuses
/// still leaves a span with its error recorded, and a fork that waits for a
/// free admission slot has that wait inside its own span.
///
/// The ceiling test holds the one slot with a fork that is still alive, and it
/// reads the gate's own waiter count and the tracer's own open spans. Nothing
/// here asserts on a duration, which is what makes the observation sound on a
/// loaded machine.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``SpanContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over the stub loader and stub backends, so the suite needs
/// no network, no GPU and no bootstrapped tracing backend.
@Suite("Fork tracing")
struct ForkTracingTests {
    /// The span name every fork opens.
    private static let spanName = "FoundationModelsRouter.fork"

    /// The suite's temp-directory prefix, so a leaked directory is
    /// attributable.
    private static let tempDirPrefix = "ForkTracingTests"

    /// The model reference the standard slot resolves to, which the fork span
    /// names.
    private static let standardModelRef = "org/std-a"

    // MARK: - Fixtures

    /// A ``LoadedLLMContainer`` whose sessions run over a plain stub backend —
    /// the smallest container a fork needs, because a fork reads the parent's
    /// backend and never generates.
    private struct ForkingStubContainer: PlainTranscriptStubContainer {
        /// Builds a backend over a fresh stub session.
        ///
        /// - Parameter instructions: The session's system instructions, or `nil`.
        /// - Returns: The backend the vended session drives for its lifetime.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(instructions: instructions)
        }
    }

    /// A box a test fills with the session its mounted tool forks.
    ///
    /// The session does not exist until it is vended with the tool already
    /// mounted, so the tool reads its target back through this instead of
    /// holding it at construction.
    private final class SessionBox: Sendable {
        /// The session, once a test named one.
        ///
        /// A `Mutex` because the test task writes it and the SDK's own
        /// tool-calling task reads it.
        private let held: Mutex<(any RoutedSession)?> = Mutex(nil)

        /// The session a test named, or `nil` when none was named.
        var value: (any RoutedSession)? { held.withLock { $0 } }

        /// Names the session the tool forks.
        ///
        /// - Parameter session: The session to fork.
        func set(_ session: any RoutedSession) {
            held.withLock { $0 = session }
        }
    }

    /// A tool whose body forks the very session whose turn invoked it — the
    /// shape the reentry guard refuses.
    ///
    /// The refusal is caught rather than raised, so the turn answers normally
    /// and the answer says which branch ran. What the fork recorded on its span
    /// is what the test then reads.
    private struct SelfForkingTool: Tool {
        /// The model-facing tool name a scripted call names to reach this tool.
        static let toolName = "self-fork-probe"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = SelfForkingTool.toolName

        /// The `Tool` description requirement. The scripted model picks its
        /// call by name and never reads this, but the SDK renders it into the
        /// tool definition it puts in the transcript.
        let description = "test-only tool that forks the session whose turn invoked it"

        /// The session this body forks.
        let target: SessionBox

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        /// The output a call produces when the fork was refused.
        static let refusedOutput = "fork refused"

        /// The output a call produces when the fork was served, which this
        /// tool's own session must never produce.
        static let servedOutput = "fork served"

        /// Forks the target session and reports which branch ran.
        ///
        /// - Parameter arguments: The call's decoded arguments, which this tool
        ///   does not read.
        /// - Returns: ``refusedOutput`` when the fork was refused,
        ///   ``servedOutput`` when it was served, or ``noTargetOutput`` when no
        ///   session was named.
        /// - Throws: Never — the refusal is the measured outcome, so it is
        ///   caught; `throws` comes from the `Tool` requirement.
        func call(arguments: AmbientToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            do {
                _ = try await session.fork(workingDirectory: nil)
                return Self.servedOutput
            } catch {
                return Self.refusedOutput
            }
        }
    }

    /// Resolves a profile over the stub hardware and the stub loader, wired to
    /// report every span to `tracer`.
    ///
    /// - Parameters:
    ///   - cacheDir: The router's cache directory.
    ///   - maxConcurrentForks: The in-flight fork ceiling the profile admits.
    ///   - tracer: The tracer every vended handle carries.
    /// - Returns: The resolved profile.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProfile(
        cacheDir: URL,
        maxConcurrentForks: Int = defaultMaxConcurrentForks,
        tracer: any Tracer
    ) async throws -> LanguageModelProfile {
        let router = RouterTestFixtures.makeRouter(
            maxConcurrentForks: maxConcurrentForks,
            cacheDir: cacheDir,
            loader: StubModelLoader(
                container: ForkingStubContainer(), dimension: RouterTestFixtures.stubDimension),
            tracer: tracer
        )
        return try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// The fork spans `tracer` holds that have finished, in the order they
    /// finished.
    ///
    /// Filtered by name rather than counted over the whole tracer: a turn that
    /// forks from inside a tool opens a turn span of its own that encloses the
    /// fork span.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: Every finished fork span.
    private static func finishedForkSpans(
        reportedTo tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == spanName }
    }

    /// The fork spans `tracer` holds that are still open.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: Every fork span that has started and not yet ended.
    private static func openForkSpans(reportedTo tracer: InMemoryTracer) -> [InMemorySpan] {
        tracer.activeSpans.filter { $0.operationName == spanName }
    }

    // MARK: - A fork that is served

    @Test("one fork opens one internal span naming the router, the model, the parent and the child")
    func oneForkOpensOneSpanNamingItsParentAndItsChild() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tracer = InMemoryTracer()
        let profile = try await Self.makeProfile(cacheDir: directory, tracer: tracer)
        let parent = profile.standard.makeSession()
        let child = try await parent.fork(workingDirectory: nil)

        let spans = Self.finishedForkSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("router.id") == .string(parent.routerId.description))
        #expect(span.attributes.get("model.ref") == .string(Self.standardModelRef))
        #expect(span.attributes.get("session.id") == .string(parent.id.description))
        // The parent and the child are two different sessions, so the two id
        // attributes would be indistinguishable if either named the wrong one.
        #expect(child.id != parent.id)
        #expect(span.attributes.get("fork.child_session_id") == .string(child.id.description))
        #expect(span.errors.isEmpty)
    }

    @Test("a fork with no tracer injected and no backend bootstrapped forks normally")
    func untracedForkForksNormally() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }

        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: ForkingStubContainer(), dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let parent = profile.standard.makeSession()

        let child = try await parent.fork(workingDirectory: nil)

        #expect(child.parentId == parent.id)
    }

    // MARK: - A fork the reentry guard refuses

    @Test("a fork refused from inside a tool of its own turn keeps its span, with the refusal recorded")
    func refusedForkKeepsItsSpanWithTheRefusalRecorded() async throws {
        let tracer = InMemoryTracer()
        let target = SessionBox()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1",
                        toolName: SelfForkingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [SelfForkingTool(target: target)],
            tempDirPrefix: Self.tempDirPrefix,
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        target.set(fixture.session)

        // The tool forks the session whose turn is calling it, so the guard
        // refuses before any gate is touched. The answer is composed from the
        // tool's output, so it says which branch really ran.
        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        #expect(answer.contains(SelfForkingTool.refusedOutput))

        let spans = Self.finishedForkSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("session.id") == .string(fixture.session.id.description))
        // Refused before a child was ever minted, so the span names no child.
        #expect(span.attributes.get("fork.child_session_id") == nil)
        try #require(span.errors.count == 1)
        let recorded = try #require(span.errors.first?.error as? SessionReentryError)
        #expect(recorded == .forkDuringSameSessionTurn(sessionID: fixture.session.id))
    }

    // MARK: - A fork that waits for a free admission slot

    @Test("a fork that waits for a free admission slot has that wait inside its own span")
    func forkWaitingOnTheCeilingHasTheWaitInsideItsSpan() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tracer = InMemoryTracer()
        let profile = try await Self.makeProfile(
            cacheDir: directory, maxConcurrentForks: 1, tracer: tracer)
        let admissionGate = profile.standard.forkAdmissionGate
        let root = profile.standard.makeSession()

        // The one admission slot, taken by a fork that stays alive and so keeps
        // holding it.
        var held: (any RoutedSession)? = try await root.fork(workingDirectory: nil)
        #expect(admissionGate.availablePermits == 0)
        #expect(Self.finishedForkSpans(reportedTo: tracer).count == 1)
        _ = held

        // A second fork, past the ceiling. It opens its span and then suspends
        // on the gate.
        let queued = Task { try await root.fork(workingDirectory: nil) }
        #expect(
            await BoundedWait.conditionReached("the queued fork suspending on the admission gate") {
                admissionGate.waiterCount == 1
            })

        // The wait is inside the span: the queued fork's span is open while the
        // slot it is waiting for is still taken. Read as state, never as
        // elapsed time.
        let openSpans = Self.openForkSpans(reportedTo: tracer)
        #expect(openSpans.count == 1)
        #expect(openSpans.first?.attributes.get("session.id") == .string(root.id.description))
        #expect(admissionGate.availablePermits == 0)
        // Still one finished span — the queued fork's own has not ended.
        #expect(Self.finishedForkSpans(reportedTo: tracer).count == 1)

        // Releasing the held fork frees its slot, the waiter is admitted, and
        // its span then closes carrying the child it made.
        held = nil
        let child = try await queued.value
        let spans = Self.finishedForkSpans(reportedTo: tracer)
        #expect(spans.count == 2)
        #expect(spans.last?.attributes.get("fork.child_session_id") == .string(child.id.description))
        #expect(spans.last?.errors.isEmpty == true)
        #expect(Self.openForkSpans(reportedTo: tracer).isEmpty)

        withExtendedLifetime(child) {}
    }
}
