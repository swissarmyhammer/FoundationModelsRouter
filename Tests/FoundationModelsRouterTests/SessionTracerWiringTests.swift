import Foundation
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^zgwmhd0: a session holds the tracer its ``RoutedModel``
/// carries, however the session came into existence — vended, forked, or
/// restored from disk.
///
/// All three shapes go through the one shared `makeRoutedSessionActor` factory,
/// and each is measured here: wiring only the vending site would leave a fork
/// and a restored node holding nothing, so the spans the dependent cards add
/// would go missing on exactly the sessions a long task runs on.
///
/// Everything runs over stub hardware, a stub loader and a stub backend, so the
/// suite needs no network, no GPU and no bootstrapped tracing backend.
@Suite("Session tracer wiring")
struct SessionTracerWiringTests {
    /// The temp directories one test's routers work under.
    private struct Workspace {
        /// The routers' cache directory.
        let cacheDir: URL

        /// The durable transcripts root a restore reads back.
        let recordingsDir: URL

        /// Creates a fresh pair of temp directories.
        init() {
            cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionTracerWiringTests-cache")
            recordingsDir = RouterTestFixtures.makeTempDir(
                prefix: "SessionTracerWiringTests-recordings")
        }

        /// Removes both directories.
        func remove() {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
    }

    /// A ``LoadedLLMContainer`` whose sessions answer every prompt with the
    /// stub backend's canned line, so a turn leaves a transcript on disk that a
    /// restore can read back.
    private struct AnsweringContainer: PlainTranscriptStubContainer {
        /// Builds a backend over a fresh stub session.
        ///
        /// - Parameter instructions: The session's system instructions, or `nil`.
        /// - Returns: The backend the vended session drives for its lifetime.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(instructions: instructions)
        }
    }

    /// Builds a router over the stub hardware, a durable recordings root and
    /// `tracer`.
    ///
    /// - Parameters:
    ///   - id: The router's recording root id. Pass a first router's `id` to
    ///     simulate a fresh process continuing the same recording root.
    ///   - workspace: The temp directories the router works under.
    ///   - tracer: The tracer every vended handle carries.
    /// - Returns: The router.
    private static func makeRouter(
        id: ULID = .generate(),
        workspace: Workspace,
        tracer: any Tracer
    ) -> Router {
        RouterTestFixtures.makeRouter(
            id: id,
            cacheDir: workspace.cacheDir,
            recordingsDir: workspace.recordingsDir,
            recorder: JSONLRecorder(directory: workspace.recordingsDir),
            loader: StubModelLoader(
                container: AnsweringContainer(), dimension: RouterTestFixtures.stubDimension),
            tracer: tracer
        )
    }

    /// Whether `tracer` is the very tracer `log` reads its finished spans from.
    ///
    /// `InMemoryTracer` is a value over shared, locked storage, so two copies of
    /// one tracer cannot be told apart by identity. A probe span opened through
    /// `tracer` and then found among `log`'s finished spans proves the two are
    /// one tracer, which is what the wiring has to give the session.
    ///
    /// - Parameters:
    ///   - tracer: The tracer the session holds, or `nil` when it holds none.
    ///   - log: The tracer the test handed to the router.
    ///   - probeName: The operation name to open the probe span under. Distinct
    ///     per call, so no probe can be mistaken for another.
    /// - Returns: `true` when the probe span reached `log`.
    private static func isSameTracer(
        _ tracer: (any Tracer)?, as log: InMemoryTracer, probeName: String
    ) -> Bool {
        guard let tracer else { return false }
        tracer.withSpan(probeName, ofKind: .internal) { _ in }
        return log.finishedSpans.contains { $0.operationName == probeName }
    }

    @Test("a vended root session holds the tracer its handle carries")
    func vendedRootHoldsTheHandlesTracer() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }

        let tracer = InMemoryTracer()
        let router = Self.makeRouter(workspace: workspace, tracer: tracer)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = profile.standard.makeSession()

        #expect(Self.isSameTracer(root.sessionTracer, as: tracer, probeName: "probe-root"))
    }

    @Test("a forked child holds the same tracer as its parent")
    func forkedChildHoldsTheParentsTracer() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }

        let tracer = InMemoryTracer()
        let router = Self.makeRouter(workspace: workspace, tracer: tracer)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = profile.standard.makeSession()
        let child = try await root.fork(workingDirectory: nil)

        #expect(Self.isSameTracer(child.sessionTracer, as: tracer, probeName: "probe-fork"))
    }

    @Test("a restored session holds the tracer of the handle that restored it")
    func restoredNodeHoldsTheRestoringHandlesTracer() async throws {
        let workspace = Workspace()
        defer { workspace.remove() }

        let tracer = InMemoryTracer()
        let firstRouter = Self.makeRouter(workspace: workspace, tracer: tracer)
        let firstProfile = try await firstRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = firstProfile.standard.makeSession()
        _ = try await root.respond(to: "hello")

        // A second router over the same recording root, the way a fresh process
        // picks a recorded tree back up.
        let secondRouter = Self.makeRouter(
            id: firstRouter.id, workspace: workspace, tracer: tracer)
        let secondProfile = try await secondRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await secondProfile.standard.restoreSessionTree(root: root.id)

        #expect(
            Self.isSameTracer(restored.root.sessionTracer, as: tracer, probeName: "probe-restored"))
    }
}
