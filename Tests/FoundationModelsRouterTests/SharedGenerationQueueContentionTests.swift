import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^trwcs63 under the queue of task ^93kjn94: two sessions over
/// one shared pool entry contend for that entry's one generation queue.
///
/// The consumer's own configuration is a single resolved profile whose
/// `standard` and `flash` name one model. The two refs are equal, so the
/// router pools both slots onto one entry, and both handles wrap the one
/// container of that entry. The container owns the ``GenerationQueue``, so the
/// two handles share one queue. That is the object graph
/// ``Router/resolve(profile:reporting:)`` builds, and it is the graph the
/// nested-generation deadlock was measured on.
///
/// A hand-built pair over one container is the same graph: both handles wrap
/// the one container, so both share its one queue. This suite holds the two
/// graphs to the same contract through one drill -- the resolved pair in
/// ``twoSessionsOverOneSharedPoolEntryContend()`` and the hand-built pair in
/// ``twoHandBuiltHandlesOverOneContainerContend()``.
///
/// Each container is a ``LiveBackendContainer`` over a ``PassObservingModel``,
/// so each pass goes through the production backend and its queued wrapper. A
/// pass reports what is concurrently inside the model and stays there until a
/// latch opens, so the suite needs no network and no GPU, and it waits on no
/// clock.
@Suite("Generation queue contention over one shared pool entry")
struct SharedGenerationQueueContentionTests {
    // MARK: - Constants

    /// The one model both generation slots name, so the two slots carry one
    /// ``ResidencyKey`` and pool onto one entry -- the consumer's own shape,
    /// where the standard and the flash model are the same model.
    private static let sharedRef: ModelRef = "org/shared-llm"

    /// The prompt the first turn is given.
    private static let firstPrompt = "first"

    /// The prompt the second turn is given.
    private static let secondPrompt = "second"

    // MARK: - Fixtures

    /// Builds a router whose loader makes a new container, with a new queue,
    /// for each generation model it loads, and resolves a profile whose
    /// standard and flash slots both name ``sharedRef``.
    ///
    /// A new container for each load is what lets one queue show that the
    /// two slots pooled onto one entry: two loads would give two queues.
    ///
    /// - Parameters:
    ///   - fixture: The parts every container's passes report to.
    ///   - dir: The temporary directory the router caches and records under.
    /// - Returns: The router and the profile it resolved, both of which the
    ///   caller has to keep alive for the length of the test.
    private static func makeSharedEntryProfile(
        fixture: PassObservingFixture, dir: URL
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: SpyingModelLoader(
                spy: LoadSpy(),
                dimension: RouterTestFixtures.stubDimension,
                llmContainer: { _ in fixture.makeContainer() })
        )
        let definition = ProfileDefinition(
            name: "shared-entry",
            description: "one model for both generation slots",
            standard: [sharedRef],
            flash: [sharedRef],
            embedding: ["org/shared-embedder"]
        )
        let profile = try await router.resolve(profile: definition, reporting: ResolutionProgress())
        return (router, profile)
    }

    /// The generation queue of the container `handle` wraps.
    ///
    /// - Parameter handle: A generation handle over a ``LiveBackendContainer``.
    /// - Returns: The queue that container owns.
    /// - Throws: When the handle wraps another container.
    private static func queue(of handle: RoutedLLM) throws -> GenerationQueue {
        try #require(handle.container as? LiveBackendContainer<PassObservingModel>).generationQueue
    }

    /// Runs one turn on `profile.standard` and one on `profile.flash`, and
    /// holds the pair to the one-queue contract.
    ///
    /// The standard turn's pass takes the one place of the queue and stays in
    /// the model until the latch opens. The flash turn's pass then waits in
    /// the very same queue, so one pass is in the model rather than two. Both
    /// turns answer once the latch opens, and the queue is left as it was
    /// found.
    ///
    /// The two graphs a caller can build -- the resolved pair and the
    /// hand-built pair -- go through this one drill, because they owe the
    /// same contract. Writing the drill twice would let the two copies drift
    /// apart, and the whole point is that they do not.
    ///
    /// - Parameters:
    ///   - profile: The profile whose two generation handles wrap one
    ///     container.
    ///   - fixture: The parts the container's passes report to.
    private static func expectPassesSerialize(
        over profile: LanguageModelProfile, fixture: PassObservingFixture
    ) async throws {
        // Identity, not equality: only one queue instance can serialize the one
        // resident container, and a second queue would let both passes in.
        let queue = try Self.queue(of: profile.standard)
        #expect(queue === (try Self.queue(of: profile.flash)))

        let holder = profile.standard.makeSession()
        let waiter = profile.flash.makeSession()

        let holderTurn = Task { try await holder.respond(to: Self.firstPrompt) }
        #expect(
            await BoundedWait.conditionReached("the standard session's pass in the model") {
                await fixture.observer.enteredCount == 1
            })

        // The flash session's pass now waits in the very same queue. This is
        // the contention: two handles, one container, one queue.
        let waiterTurn = Task { try await waiter.respond(to: Self.secondPrompt) }
        #expect(
            await BoundedWait.conditionReached("the flash session's pass waiting in the shared queue") {
                await queue.waitingCount == 1
            })

        // The waiting pass never reached the model, so one pass is in flight
        // rather than two.
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        #expect(try await holderTurn.value == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(try await waiterTurn.value == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(await fixture.observer.maximumActive == 1)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    // MARK: - The queue a resolve vends

    @Test("a resolve that pools both generation slots onto one entry gives the two handles one queue")
    func poolingBothGenerationSlotsOntoOneEntryGivesOneQueue() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationQueueContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
        let resolved = try await Self.makeSharedEntryProfile(fixture: fixture, dir: dir)

        // Identity, not equality: the loader makes a new queue for each load,
        // so one queue shows one pool entry, and a second entry would show two.
        #expect(try Self.queue(of: resolved.profile.standard) === Self.queue(of: resolved.profile.flash))

        await fixture.latch.open()
        withExtendedLifetime(resolved) {}
    }

    @Test("two sessions over one shared pool entry contend for that entry's one generation queue")
    func twoSessionsOverOneSharedPoolEntryContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationQueueContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
        let resolved = try await Self.makeSharedEntryProfile(fixture: fixture, dir: dir)

        // One session from each generation handle, which is what a consumer
        // holding a resolved profile has.
        try await Self.expectPassesSerialize(over: resolved.profile, fixture: fixture)

        withExtendedLifetime(resolved) {}
    }

    // MARK: - The control

    /// The control shows that a hand-built graph serializes exactly as the
    /// resolved graph does: two handles over one container share one queue,
    /// and one pass only is inside the model at a time.
    ///
    /// The contention test above shows only that a queue serializes; it
    /// cannot show that the resolved graph and the hand-built graph agree,
    /// and that agreement is what the suites built on a hand-built profile
    /// need.
    @Test("two hand-built handles over one container contend, because both share the container's one queue")
    func twoHandBuiltHandlesOverOneContainerContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationQueueContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
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
