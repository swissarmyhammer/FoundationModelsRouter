import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^m80y2d4: every session opens one span as it comes into
/// existence, whichever of the three shapes made it — vended over a resident
/// model, restored from disk, or forked from a live session.
///
/// The span says which shape made the session through its own `session.origin`
/// attribute, so one query can separate the cost of a restore from the cost of
/// a vend. A restored node's span opens before the transcript-tree read the
/// rebuild needs, so the disk work the restore really pays for is inside it.
///
/// A forked child carries two spans, and this suite reads the nesting that
/// says they are not double counting: the session span is a child of the fork
/// span, so the construction is a part of the fork rather than a second cost
/// beside it.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``SpanContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over the stub loader and stub backends, so the suite needs
/// no network, no GPU and no bootstrapped tracing backend.
@Suite("Session creation tracing")
struct SessionCreationTracingTests {
    /// The span name every session opens as it is made.
    private static let spanName = "FoundationModelsRouter.session"

    /// The span name one fork opens around the child it makes.
    private static let forkSpanName = "FoundationModelsRouter.fork"

    /// The suite's temp-directory prefix, so a leaked directory is
    /// attributable.
    private static let tempDirPrefix = "SessionCreationTracingTests"

    /// The model reference the standard slot resolves to, which a session span
    /// names.
    private static let standardModelRef = "org/std-a"

    // MARK: - Fixtures

    /// A ``LoadedLLMContainer`` whose sessions answer with the stub backend's
    /// canned line, so a turn leaves a transcript on disk that a restore can
    /// read back.
    private struct AnsweringStubContainer: PlainTranscriptStubContainer {
        /// Builds a backend over a fresh stub session.
        ///
        /// - Parameter instructions: The session's system instructions, or `nil`.
        /// - Returns: The backend the vended session drives for its lifetime.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(instructions: instructions)
        }
    }

    /// The temp directories one test's routers work under.
    private struct Workspace {
        /// The routers' cache directory.
        let cacheDir: URL

        /// The durable transcripts root a restore reads back.
        let recordingsDir: URL

        /// Creates a fresh pair of temp directories.
        init() {
            cacheDir = RouterTestFixtures.makeTempDir(prefix: "\(tempDirPrefix)-cache")
            recordingsDir = RouterTestFixtures.makeTempDir(prefix: "\(tempDirPrefix)-recordings")
        }

        /// Removes both directories.
        func remove() {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
    }

    /// Resolves a profile over the stub hardware and the stub loader, wired to
    /// report every span to `tracer`.
    ///
    /// - Parameters:
    ///   - id: The router's recording root id. Pass a first router's `id` to
    ///     simulate a fresh process continuing the same recording root.
    ///   - workspace: The temp directories the router works under.
    ///   - tracer: The tracer every vended handle carries.
    /// - Returns: The resolved profile.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProfile(
        id: ULID = .generate(),
        workspace: Workspace,
        tracer: any Tracer
    ) async throws -> LanguageModelProfile {
        let router = RouterTestFixtures.makeRouter(
            id: id,
            cacheDir: workspace.cacheDir,
            recordingsDir: workspace.recordingsDir,
            recorder: JSONLRecorder(directory: workspace.recordingsDir),
            loader: StubModelLoader(
                container: AnsweringStubContainer(), dimension: RouterTestFixtures.stubDimension),
            tracer: tracer
        )
        return try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// The session spans `tracer` holds that have finished, in the order they
    /// finished.
    ///
    /// Filtered by name rather than counted over the whole tracer: a session
    /// made inside a fork or a turn shares its tracer with the spans those
    /// open.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: Every finished session span.
    private static func finishedSessionSpans(
        reportedTo tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == spanName }
    }

    /// The one finished session span naming `session`.
    ///
    /// - Parameters:
    ///   - session: The session whose span to read.
    ///   - tracer: The tracer the driven work reported to.
    /// - Returns: That session's span.
    /// - Throws: When the tracer holds no span for `session`, or more than one.
    private static func sessionSpan(
        for session: ULID,
        reportedTo tracer: InMemoryTracer
    ) throws -> FinishedInMemorySpan {
        let spans = finishedSessionSpans(reportedTo: tracer).filter {
            $0.attributes.get("session.id") == .string(session.description)
        }
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    // MARK: - A session vended over a resident model

    @Test("a vended session opens one internal span naming the router, the model and itself")
    func vendedSessionOpensOneSpanNamingItself() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }

        let tracer = InMemoryTracer()
        let profile = try await Self.makeProfile(workspace: workspace, tracer: tracer)
        let session = profile.standard.makeSession()

        let spans = Self.finishedSessionSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("router.id") == .string(session.routerId.description))
        #expect(span.attributes.get("model.ref") == .string(Self.standardModelRef))
        #expect(span.attributes.get("session.id") == .string(session.id.description))
        #expect(span.attributes.get("session.origin") == .string("new"))
        // A vended root came from no session, so it names no parent.
        #expect(span.attributes.get("session.parent_id") == nil)
        #expect(span.errors.isEmpty)
    }

    // MARK: - A forked child

    @Test("a forked child opens its own session span, naming its parent, inside the fork span")
    func forkedChildOpensItsOwnSessionSpanInsideTheForkSpan() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }

        let tracer = InMemoryTracer()
        let profile = try await Self.makeProfile(workspace: workspace, tracer: tracer)
        let parent = profile.standard.makeSession()
        let child = try await parent.fork(workingDirectory: nil)

        // The parent and the child are two different sessions, so a span that
        // named the wrong one would be indistinguishable from the right one.
        #expect(child.id != parent.id)
        #expect(Self.finishedSessionSpans(reportedTo: tracer).count == 2)

        let span = try Self.sessionSpan(for: child.id, reportedTo: tracer)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("router.id") == .string(child.routerId.description))
        #expect(span.attributes.get("model.ref") == .string(Self.standardModelRef))
        #expect(span.attributes.get("session.origin") == .string("forked"))
        #expect(span.attributes.get("session.parent_id") == .string(parent.id.description))

        // The two spans of a fork are not two costs: the construction the
        // session span measures happens inside the fork the fork span
        // measures, and the nesting is what says so.
        let forkSpans = tracer.finishedSpans.filter { $0.operationName == Self.forkSpanName }
        try #require(forkSpans.count == 1)
        let forkSpan = try #require(forkSpans.first)
        #expect(span.parentSpanID == forkSpan.spanContext.spanID)
    }

    // MARK: - A session restored from disk

    @Test("restoring a recorded tree opens one session span per node, each naming its origin")
    func restoredTreeOpensOneSpanPerNodeNamingTheRestoredOrigin() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }

        let recordedTracer = InMemoryTracer()
        let recordingProfile = try await Self.makeProfile(
            workspace: workspace, tracer: recordedTracer)
        let root = recordingProfile.standard.makeSession()
        _ = try await root.respond(to: "remember 42")
        let fork = try await root.fork(workingDirectory: nil)

        // A second router over the same recording root, the way a fresh
        // process picks a recorded tree back up. Its own tracer holds the
        // spans of the restore alone.
        let restoreTracer = InMemoryTracer()
        let restoringProfile = try await Self.makeProfile(
            id: root.routerId, workspace: workspace, tracer: restoreTracer)
        let restored = try await restoringProfile.standard.restoreSessionTree(root: root.id)

        #expect(restored.root.id == root.id)
        #expect(Self.finishedSessionSpans(reportedTo: restoreTracer).count == 2)

        let rootSpan = try Self.sessionSpan(for: root.id, reportedTo: restoreTracer)
        #expect(rootSpan.kind == .internal)
        #expect(rootSpan.attributes.get("router.id") == .string(root.routerId.description))
        #expect(rootSpan.attributes.get("model.ref") == .string(Self.standardModelRef))
        #expect(rootSpan.attributes.get("session.origin") == .string("restored"))
        #expect(rootSpan.attributes.get("session.parent_id") == nil)
        #expect(rootSpan.errors.isEmpty)

        // The recorded fork restores as a node of its own, so it gets its own
        // span, and that span names the session it was forked from.
        let forkSpan = try Self.sessionSpan(for: fork.id, reportedTo: restoreTracer)
        #expect(forkSpan.attributes.get("session.origin") == .string("restored"))
        #expect(forkSpan.attributes.get("session.parent_id") == .string(root.id.description))
    }
}
