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
    /// The start of the name of each temporary directory of this suite. A
    /// directory that stays after a test then names this suite as its owner.
    private static let tempDirPrefix = "TranscriptTreeAccessTests"

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
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let router = makeRouter(cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        defer { await session.close() }

        let tree = try profile.standard.transcriptTree()

        #expect(tree.session(session.id) != nil)
    }

    @Test("an explicit recordingRoot loads that directory's flat layout")
    @MainActor
    func explicitRecordingRootLoadsTheFlatLayout() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let sessionRoot = RouterTestFixtures.makeTempDir(prefix: "\(Self.tempDirPrefix)-sessionRoot")
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let router = makeRouter(cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(recordingRoot: sessionRoot)
        defer { await session.close() }

        let tree = try profile.standard.transcriptTree(recordingRoot: sessionRoot)

        #expect(tree.session(session.id) != nil)
    }

    @Test("throws noDurableRecordingsRoot when the router records to memory")
    @MainActor
    func throwsWithoutADurableRoot() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let router = makeRouter(cacheDir: cacheDir)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        #expect(throws: SessionTreeRestorationError.noDurableRecordingsRoot) {
            _ = try profile.standard.transcriptTree()
        }
    }
}
