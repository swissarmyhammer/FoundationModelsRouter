import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises cancellation of ``Router/resolve(profile:reporting:)`` (task
/// ^h59152d): the agent CLI's `Ctrl-C` watch cancels the task that holds the
/// resolve, and the resolve must stop.
///
/// Each test drives one stage of the pipeline. The loader and the metadata
/// source suspend at the named stage on an ``AsyncSemaphore`` — the
/// non-interrupting acquire on purpose, so the stage itself is NOT unwound by
/// the cancel. That is the real shape: a download in flight cannot be torn out
/// from under the caller, so the resolve must stop at the NEXT stage boundary
/// instead.
///
/// Every test closes the same way: the resolve throws `CancellationError`, the
/// bound progress reaches ``ResolutionProgress/Phase/cancelled`` — the phase a
/// host shows the user, and not ``ResolutionProgress/Phase/failed(_:)``, because
/// the user made the cancel — and a second resolve on the same router succeeds,
/// which is how a test outside the module observes that the pool lock was
/// released.
@Suite("Resolve cancellation")
struct ResolveCancellationTests {
    // MARK: - Stage gating

    /// A stage of the resolve pipeline a test can suspend the router inside.
    private enum Stage: Sendable {
        /// Sizing the candidates against the budget.
        case sizing
        /// Acquiring a generation slot.
        case generation
        /// Acquiring the embedding slot.
        case embedding
        /// Preloading an acquired slot.
        case preload
    }

    /// Suspends the first caller that reaches ``gatedStage`` until the test
    /// releases it, and lets every later caller straight through so a second
    /// resolve can run to completion on the same router.
    private final class StageGate: Sendable {
        /// The stage this gate stands in.
        let gatedStage: Stage
        /// Signalled once the router is suspended inside the gated stage.
        let reached = AsyncSemaphore(value: 0)
        /// Signalled by the test to let the gated stage finish.
        let release = AsyncSemaphore(value: 0)
        /// Whether the gate has already fired, so it fires exactly once.
        private let hasFired = Mutex(false)

        /// Creates a gate standing in `stage`.
        init(at stage: Stage) {
            gatedStage = stage
        }

        /// Suspends the caller when it is the first to reach `stage`.
        ///
        /// - Parameter stage: The stage the caller is entering.
        func passing(_ stage: Stage) async {
            guard stage == gatedStage else { return }
            let isFirst = hasFired.withLock { fired -> Bool in
                guard !fired else { return false }
                fired = true
                return true
            }
            guard isFirst else { return }
            reached.signal()
            await release.wait()
        }
    }

    // MARK: - Stubs

    private struct GatedMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        let gate: StageGate

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            await gate.passing(.sizing)
            return raw
        }
    }

    private struct GatedLoader: ModelLoader {
        let gate: StageGate
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            await gate.passing(.generation)
            return StubLLMContainer(canned: "from-\(ref.stringValue)")
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            await gate.passing(.embedding)
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {
            await gate.passing(.preload)
        }
    }

    private struct StubLLMContainer: LoadedLLMContainer {
        let canned: String

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: canned)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: canned)
        }
    }

    // MARK: - Fixtures

    private static func makeRouter(gate: StageGate, cacheDir: URL) -> Router {
        Router(
            headroomReserve: 0,
            cacheDir: cacheDir,
            recorder: InMemoryRecorder(),
            probe: RouterTestFixtures.stubProbe,
            metadataSource: GatedMetadataSource(raw: RouterTestFixtures.rawMetadata, gate: gate),
            loader: GatedLoader(gate: gate, dimension: RouterTestFixtures.stubDimension)
        )
    }

    /// Runs one whole cancel-at-a-stage scenario and asserts the shared closing
    /// contract, so each stage's test states only which stage it gates.
    ///
    /// - Parameter stage: The stage to cancel the resolve inside.
    @MainActor
    private static func expectCancelStops(at stage: Stage) async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveCancellationTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = StageGate(at: stage)
        let router = makeRouter(gate: gate, cacheDir: dir)
        let progress = ResolutionProgress()

        let resolve = Task {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: progress)
        }
        await gate.reached.wait()

        // The router is suspended inside the gated stage. Cancel, then let that
        // stage finish: the resolve must stop at the next stage boundary.
        resolve.cancel()
        gate.release.signal()
        await #expect(throws: CancellationError.self) { try await resolve.value }

        // The user made the cancel, so the phase says so: `.cancelled`, never
        // `.failed`, which would show the user a diagnostic for their own stop.
        #expect(progress.phase == .cancelled)

        // The pool lock is free: a second resolve on the same router completes.
        let second = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        #expect(second.standard.chosen == "org/std-a")
    }

    // MARK: - One test for each stage

    @Test("a resolve cancelled while sizing stops and leaves the pool lock free")
    @MainActor
    func cancelDuringSizing() async throws {
        try await Self.expectCancelStops(at: .sizing)
    }

    @Test("a resolve cancelled while acquiring a generation slot stops")
    @MainActor
    func cancelDuringGenerationAcquisition() async throws {
        try await Self.expectCancelStops(at: .generation)
    }

    @Test("a resolve cancelled while acquiring the embedding slot stops")
    @MainActor
    func cancelDuringEmbeddingAcquisition() async throws {
        try await Self.expectCancelStops(at: .embedding)
    }

    @Test("a resolve cancelled while preloading stops")
    @MainActor
    func cancelDuringPreload() async throws {
        try await Self.expectCancelStops(at: .preload)
    }

    // MARK: - Queued on the pool lock

    /// Cooperative yields given to a queued resolve so it reaches the pool lock
    /// before the test cancels it. The pool lock is private, so its waiter count
    /// cannot be spun on the way ``AsyncSemaphore/waiterCount`` is elsewhere.
    private static let yieldsBeforeCancel = 20

    @Test("a resolve cancelled while queued on the pool lock throws before the holder releases it")
    @MainActor
    func cancelWhileQueuedOnThePoolLock() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveCancellationTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gate = StageGate(at: .generation)
        let router = Self.makeRouter(gate: gate, cacheDir: dir)

        // The first resolve takes the pool lock and suspends inside its own
        // generation load, so the lock stays held for the whole test.
        let holder = Task {
            try await router.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        await gate.reached.wait()

        let queuedProgress = ResolutionProgress()
        let queued = Task {
            try await router.resolve(
                profile: RouterTestFixtures.profile(), reporting: queuedProgress)
        }
        // Give the second resolve every chance to reach the pool lock.
        for _ in 0..<Self.yieldsBeforeCancel { await Task.yield() }

        // It throws while the holder is still suspended — no `release.signal()`
        // has been sent, so the throw cannot have come from a freed permit.
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(queuedProgress.phase == .cancelled)

        // The holder was never disturbed and resolves normally.
        gate.release.signal()
        let resolved = try await holder.value
        #expect(resolved.standard.chosen == "org/std-a")
    }
}
