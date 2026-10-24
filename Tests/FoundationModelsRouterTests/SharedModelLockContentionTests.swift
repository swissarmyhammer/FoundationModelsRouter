import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^trwcs63 under the design of task ^qhgfajc: two sessions
/// over one model contend only for the lock of that model, for one pass at a
/// time.
///
/// Two handles over one container run over one model, and thus over the one
/// lock of that model. A hand-built pair over one container is that graph,
/// and ``twoHandBuiltHandlesOverOneContainerContend()`` holds it to the
/// contract through one drill.
///
/// ``Router/resolve(profile:reporting:)`` never builds that graph for one
/// profile: the `standard` and `flash` slots never use the same model.
/// ``resolvedStandardAndFlashHandlesHaveTwoModels()`` holds a resolve to that.
///
/// Each container is a ``LiveBackendContainer`` over a ``PassObservingModel``,
/// whose passes hold its ``FIFOGenerationLock``. A pass reports what is
/// concurrently inside the model and stays there until a latch opens, so the
/// suite needs no network and no GPU, and it waits on no clock. Each wait
/// that a regression can keep open is a ``BoundedWait``.
@Suite("Contention for the lock of one model over one container")
struct SharedModelLockContentionTests {
    // MARK: - Constants

    /// The model the `standard` slot names, and the model the hand-built pair
    /// wraps.
    private static let sharedRef: ModelRef = "org/shared-llm"

    /// The model the `flash` slot names: a different model from ``sharedRef``,
    /// because the two generation slots never use the same model.
    private static let flashRef: ModelRef = "org/flash-llm"

    /// The prompt the first answer is given.
    private static let firstPrompt = "first"

    /// The prompt the second answer is given.
    private static let secondPrompt = "second"

    // MARK: - Fixtures

    /// Runs one answer on `profile.standard` and one on `profile.flash`, and
    /// holds the pair to the contract of one lock.
    ///
    /// The pass of the standard answer holds the lock of the model, and stays
    /// in the model until the latch opens. The pass of the flash answer then
    /// waits for the very same lock, so one pass is in the model rather than
    /// two. Both answers end once the latch opens.
    ///
    /// - Parameters:
    ///   - profile: The profile whose two generation handles wrap one
    ///     container.
    ///   - fixture: The parts the container's passes report to. The caller
    ///     opens the latch also when this helper throws.
    private static func expectPassesSerialize(
        over profile: LanguageModelProfile, fixture: PassObservingFixture
    ) async throws {
        let holder = profile.standard.makeSession()
        let waiter = profile.flash.makeSession()
        // The latch opens before the closes, also when this helper throws
        // (rule T1): a close waits for the held pass.
        defer { await SessionFixtureLifecycle.close([holder, waiter], opening: [fixture.latch]) }

        let holderAnswer = Task { try await holder.respond(to: Self.firstPrompt) }
        // The wait also ends when the holder answer ends (rule T1): the latch
        // holds its pass, so in a test that passes it cannot end first.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: holderAnswer)
        }

        // The pass of the flash session now waits for the very same lock.
        // This is the contention: two handles, one container, one model.
        let waiterAnswer = Task { try await waiter.respond(to: Self.secondPrompt) }
        try await BoundedWait.run { try await fixture.lock.waitForWaiters(1) }

        // The waiting pass never reached the model, so one pass is in flight
        // rather than two.
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        #expect(try await BoundedWait.value(of: holderAnswer) == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(try await BoundedWait.value(of: waiterAnswer) == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(await fixture.observer.maximumActive == 1)
        #expect(await fixture.lock.waitingCount == 0)
    }

    // MARK: - The models a resolve vends

    @Test("a resolve gives the standard and flash handles two different models")
    func resolvedStandardAndFlashHandlesHaveTwoModels() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedModelLockContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
        defer { await fixture.latch.open() }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: SpyingModelLoader(
                spy: LoadSpy(),
                dimension: RouterTestFixtures.stubDimension,
                llmContainer: { _ in fixture.makeContainer() })
        )
        let definition = ProfileDefinition(
            name: "two-generation-models",
            description: "the standard and flash slots name two different models",
            standard: [Self.sharedRef],
            flash: [Self.flashRef],
            embedding: ["org/shared-embedder"]
        )
        let profile = try await router.resolve(profile: definition, reporting: ResolutionProgress())

        #expect(profile.standard.chosen == Self.sharedRef)
        #expect(profile.flash.chosen == Self.flashRef)

        withExtendedLifetime((router, profile)) {}
    }

    // MARK: - The hand-built graph

    /// Two hand-built handles over one container share one model, and one
    /// pass only is inside the model at a time.
    @Test("two hand-built handles over one container contend, because both share the lock of its one model")
    func twoHandBuiltHandlesOverOneContainerContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedModelLockContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
        defer { await fixture.latch.open() }
        let container = fixture.container
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = HandBuiltProfileFixtures.makeProfile(
            definitionName: "hand-built",
            chosen: Self.sharedRef,
            container: container,
            router: router
        )

        try await Self.expectPassesSerialize(over: profile, fixture: fixture)

        withExtendedLifetime(profile) {}
    }
}
