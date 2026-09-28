import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^trwcs63 under the queue of task ^93kjn94: two sessions over
/// one container contend for that container's one generation queue.
///
/// Two handles whose backends name one ``GenerationQueue`` share that queue. A
/// hand-built pair over one container that the test gave one queue is that
/// graph, and ``twoHandBuiltHandlesOverOneContainerContend()`` holds it to the
/// contract through one drill.
///
/// ``Router/resolve(profile:reporting:)`` never builds that graph for one
/// profile: the `standard` and `flash` slots never use the same model, so the
/// two handles of one resolved profile hold two pool entries with two queues.
/// ``resolvedStandardAndFlashHandlesHaveTwoQueues()`` holds a resolve to that.
/// A synchronous tool call runs a selection call on `flash` inside an open
/// submission on `standard`, and with one queue it would wait on itself.
///
/// Each container is a ``LiveBackendContainer`` over a ``PassObservingModel``,
/// so each answer submits its whole SDK call to the queue of the container
/// (task ^1psqdm9). A pass reports what is concurrently inside the model and
/// stays there until a latch opens, so the suite needs no network and no GPU,
/// and it waits on no clock.
@Suite("Generation queue contention over one container")
struct SharedGenerationQueueContentionTests {
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

    /// The generation queue that each session backend of `handle` names.
    ///
    /// - Parameter handle: A generation handle over a ``LiveBackendContainer``.
    /// - Returns: The queue of the pool entry of a resolved handle, or the
    ///   queue that the test gave to a hand-built container.
    /// - Throws: When the backends of the handle name no queue.
    private static func queue(of handle: RoutedLLM) throws -> GenerationQueue {
        try #require(handle.backendQueue)
    }

    /// Runs one answer on `profile.standard` and one on `profile.flash`, and
    /// holds the pair to the one-queue contract.
    ///
    /// The standard answer's submission runs on the worker of the queue, and its
    /// pass stays in the model until the latch opens. The flash answer's
    /// submission then waits in the very same queue, so one pass is in the
    /// model rather than two. Both answers end once the latch opens, and the
    /// queue is left as it was found.
    ///
    /// - Parameters:
    ///   - profile: The profile whose two generation handles wrap one
    ///     container.
    ///   - fixture: The parts the container's passes report to.
    private static func expectPassesSerialize(
        over profile: LanguageModelProfile, fixture: PassObservingFixture
    ) async throws {
        // Identity, not equality: only one queue instance can serialize the one
        // resident container, and a second queue would let both submissions in.
        let queue = try Self.queue(of: profile.standard)
        #expect(queue === (try Self.queue(of: profile.flash)))

        let holder = profile.standard.makeSession()
        let waiter = profile.flash.makeSession()

        let holderAnswer = Task { try await holder.respond(to: Self.firstPrompt) }
        #expect(
            await BoundedWait.conditionReached("the standard session's pass in the model") {
                await fixture.observer.enteredCount == 1
            })

        // The flash session's submission now waits in the very same queue.
        // This is the contention: two handles, one container, one queue.
        let waiterAnswer = Task { try await waiter.respond(to: Self.secondPrompt) }
        #expect(
            await BoundedWait.conditionReached("the flash session's submission waiting in the shared queue") {
                await queue.waitingCount == 1
            })

        // The waiting submission never reached the model, so one pass is in
        // flight rather than two.
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        #expect(try await holderAnswer.value == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(try await waiterAnswer.value == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(await fixture.observer.maximumActive == 1)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    // MARK: - The queues a resolve vends

    @Test("a resolve gives the standard and flash handles two different models and two queues")
    func resolvedStandardAndFlashHandlesHaveTwoQueues() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationQueueContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = PassObservingFixture()
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
        // Identity, not equality: each pool entry owns its own queue, so two
        // queues show two pool entries.
        #expect(try Self.queue(of: profile.standard) !== Self.queue(of: profile.flash))

        await fixture.latch.open()
        withExtendedLifetime((router, profile)) {}
    }

    // MARK: - The hand-built graph

    /// Two hand-built handles over one container share one queue, and one pass
    /// only is inside the model at a time.
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
