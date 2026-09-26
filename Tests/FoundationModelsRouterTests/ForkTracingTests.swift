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
/// call and not only the part that succeeds: a fork that throws still leaves a
/// span with its error recorded. A fork from inside a tool of its own session
/// is served (task ^dpn2ytt), and its span names its child.
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

    /// A box that holds one session: the session a mounted tool forks, or the
    /// child that tool made.
    ///
    /// The session does not exist until it is vended with the tool already
    /// mounted, so the tool reads its target back through this instead of
    /// holding it at construction.
    private final class SessionBox: Sendable {
        /// The session, once one was put in the box.
        ///
        /// A `Mutex` because the test task and the SDK's own tool-calling task
        /// each write it or read it.
        private let held: Mutex<(any RoutedSession)?> = Mutex(nil)

        /// The session in the box, or `nil` when none was put in it.
        var value: (any RoutedSession)? { held.withLock { $0 } }

        /// Puts `session` in the box.
        ///
        /// - Parameter session: The session to keep.
        func set(_ session: any RoutedSession) {
            held.withLock { $0 = session }
        }
    }

    /// A tool whose body forks the very session whose submission invoked it. The fork
    /// reads the settled transcript of that session, so it is served
    /// (task ^dpn2ytt).
    ///
    /// A failure is caught rather than raised, so the answer ends normally
    /// and the answer says which branch ran. The child goes into ``child``, and
    /// what the fork recorded on its span is what the test then reads.
    private struct SelfForkingTool: Tool {
        /// The model-facing tool name a scripted call names to reach this tool.
        static let toolName = "self-fork-probe"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = SelfForkingTool.toolName

        /// The `Tool` description requirement. The scripted model picks its
        /// call by name and never reads this, but the SDK renders it into the
        /// tool definition it puts in the transcript.
        let description = "test-only tool that forks the session whose submission invoked it"

        /// The session this body forks.
        let target: SessionBox

        /// Where the body puts the child the fork made.
        let child: SessionBox

        /// The output a call produces when no target session was named, so a
        /// misbuilt fixture reads as a wrong answer rather than as a pass.
        static let noTargetOutput = "no target session"

        /// The output a call produces when the fork failed.
        static let failedOutput = "fork failed"

        /// The output a call produces when the fork was served.
        static let servedOutput = "fork served"

        /// Forks the target session, keeps the child, and reports which branch
        /// ran.
        ///
        /// - Parameter arguments: The call's decoded arguments, which this tool
        ///   does not read.
        /// - Returns: ``servedOutput`` when the fork was served,
        ///   ``failedOutput`` when it threw, or ``noTargetOutput`` when no
        ///   session was named.
        /// - Throws: Never — a failure is a measured outcome, so it is caught;
        ///   `throws` comes from the `Tool` requirement.
        func call(arguments: AmbientToolArguments) async throws -> String {
            guard let session = target.value else { return Self.noTargetOutput }
            do {
                child.set(try await session.fork(workingDirectory: nil))
                return Self.servedOutput
            } catch {
                return Self.failedOutput
            }
        }
    }

    /// Resolves a profile over the stub hardware and the stub loader, wired to
    /// report every span to `tracer`.
    ///
    /// - Parameters:
    ///   - cacheDir: The router's cache directory.
    ///   - tracer: The tracer every vended handle carries.
    /// - Returns: The resolved profile.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProfile(
        cacheDir: URL,
        tracer: any Tracer
    ) async throws -> LanguageModelProfile {
        let router = RouterTestFixtures.makeRouter(
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
    /// Filtered by name rather than counted over the whole tracer: an answer that
    /// forks from inside a tool opens a submission span of its own that encloses the
    /// fork span.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: Every finished fork span.
    private static func finishedForkSpans(
        reportedTo tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == spanName }
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

    // MARK: - A fork from inside a tool of its own session

    @Test("a fork from inside a tool of its own session is served, and its span names the child")
    func forkFromItsOwnToolIsServedAndItsSpanNamesTheChild() async throws {
        let tracer = InMemoryTracer()
        let target = SessionBox()
        let child = SessionBox()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1",
                        toolName: SelfForkingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [SelfForkingTool(target: target, child: child)],
            tempDirPrefix: Self.tempDirPrefix,
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        target.set(fixture.session)

        // The tool forks the session whose submission is calling it. The fork reads
        // the settled transcript of that session, so it is served at once
        // (task ^dpn2ytt). The answer is composed from the tool's output, so
        // it says which branch really ran.
        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        #expect(answer.contains(SelfForkingTool.servedOutput))

        let forked = try #require(child.value)
        let spans = Self.finishedForkSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("session.id") == .string(fixture.session.id.description))
        #expect(span.attributes.get("fork.child_session_id") == .string(forked.id.description))
        #expect(span.errors.isEmpty)
    }
}
