import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^pe7mg0v: ``RoutedModel/transcriptTree(recordingRoot:)`` —
/// tree access off the resolved handle, so user code never composes a
/// recording directory from `recordingsDir` and `routerId` by hand.
///
/// The contract under test: the call returns the ``TranscriptTree`` loaded
/// from this handle's router-level recording root (or from an explicit
/// per-session `recordingRoot`), and throws the existing typed
/// ``SessionTreeRestorationError/noDurableRecordingsRoot`` when the router
/// records to memory.
@Suite("RoutedModel.transcriptTree: tree access off the resolved handle")
struct TranscriptTreeAccessTests {
    /// Builds a stub-backed router over the shared fixtures.
    private func makeRouter(cacheDir: URL, recordingsDir: URL? = nil) -> Router {
        let recorder: any TranscriptRecorder =
            recordingsDir.map { JSONLRecorder(directory: $0) } ?? InMemoryRecorder()
        return RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(),
                dimension: RouterTestFixtures.stubDimension
            )
        )
    }

    @Test("returns the tree loaded from <recordingsRoot>/<routerId>/")
    @MainActor
    func returnsTheRouterLevelTree() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "TranscriptTreeAccessTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(
            prefix: "TranscriptTreeAccessTests-recordings")
        let router = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()

        let tree = try profile.standard.transcriptTree()

        #expect(tree.session(session.id) != nil)
        await profile.release()
    }

    @Test("an explicit recordingRoot loads that directory's flat layout")
    @MainActor
    func explicitRecordingRootLoadsTheFlatLayout() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "TranscriptTreeAccessTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(
            prefix: "TranscriptTreeAccessTests-recordings")
        let sessionRoot = RouterTestFixtures.makeTempDir(
            prefix: "TranscriptTreeAccessTests-sessionRoot")
        let router = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(recordingRoot: sessionRoot)

        let tree = try profile.standard.transcriptTree(recordingRoot: sessionRoot)

        #expect(tree.session(session.id) != nil)
        await profile.release()
    }

    @Test("throws noDurableRecordingsRoot when the router records to memory")
    @MainActor
    func throwsWithoutADurableRoot() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "TranscriptTreeAccessTests")
        let router = makeRouter(cacheDir: cacheDir)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        #expect(throws: SessionTreeRestorationError.noDurableRecordingsRoot) {
            _ = try profile.standard.transcriptTree()
        }
        await profile.release()
    }
}
