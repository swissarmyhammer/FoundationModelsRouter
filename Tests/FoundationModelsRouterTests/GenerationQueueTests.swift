import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter

/// Task ^8csj2hw: the generation queue of one container, taken for one
/// executor pass at a time (`generation-queue.md`, section 2).
///
/// Each backend a container makes runs its `LanguageModelSession` over its own
/// ``QueuedLanguageModel``, and all those wrappers share the one
/// ``GenerationQueue`` of the container. ``PassObservingModel`` makes each
/// executor call an observable pass that stays open until a ``RunLatch``
/// opens, so a test sees an overlap, a queued pass, and which executor ran
/// each pass. The backends are the production ``MLXFoundationModelsSessionBackend``
/// over the scripted model, through ``LiveBackendContainer``.
@Suite("Generation queue: one executor pass at a time for each container (task ^8csj2hw)")
struct GenerationQueueTests {
    /// The parts one test observes, and the container whose backends run over
    /// them.
    private struct Fixture {
        /// The observer each pass reports its entry and its exit to.
        let observer = ConcurrencyPeakObserver()

        /// The latch each pass waits on.
        let latch = RunLatch()

        /// The log of the passes.
        let passes = ObservedPassLog()

        /// The container whose backends share one queue.
        let container: LiveBackendContainer<PassObservingModel>

        /// Makes a fixture with a closed latch.
        init() {
            container = LiveBackendContainer(
                model: PassObservingModel(observer: observer, latch: latch, passes: passes))
        }

        /// The queue of the container.
        var queue: GenerationQueue { container.generationQueue }
    }

    /// The repository id of the raw MLX model the wrapper tests build. The
    /// model is never loaded.
    private static let rawModelRepository = "org/raw-model"

    /// The window the live container of the wrapper tests declares.
    private static let rawModelContextWindow = 4096

    /// An `MLXLanguageModel` whose load always fails. Nothing in these tests
    /// loads it.
    private static func makeUnloadableMLXModel() -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(id: rawModelRepository),
            weightsLocation: { _ in FileManager.default.temporaryDirectory },
            load: { _, _ in throw ModelLoaderError.notConfigured })
    }

    /// A live container over ``makeUnloadableMLXModel()``.
    private static func makeLiveContainer() -> MLXFoundationModelsContainer {
        MLXFoundationModelsContainer(
            model: makeUnloadableMLXModel(), contextWindow: rawModelContextWindow,
            tokenCounter: CharacterTokenCounter())
    }

    @Test("two sessions over one container never run two executor passes at the same time")
    func twoSessionsOverOneContainerNeverOverlapTheirPasses() async throws {
        let fixture = Fixture()
        let first = fixture.container.makeSession(instructions: nil)
        let second = fixture.container.makeSession(instructions: nil)

        let firstTurn = Task { try await first.respond(to: "first", maxTokens: nil) }
        _ = await BoundedWait.conditionReached("the first pass entered the model") {
            await fixture.observer.enteredCount == 1
        }
        let secondTurn = Task { try await second.respond(to: "second", maxTokens: nil) }
        _ = await BoundedWait.conditionReached("the second pass waited for a queue place") {
            fixture.queue.waiterCount == 1
        }
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        let firstAnswer = try await firstTurn.value
        let secondAnswer = try await secondTurn.value

        #expect(firstAnswer == PassObservingModel.answer(to: "first"))
        #expect(secondAnswer == PassObservingModel.answer(to: "second"))
        #expect(await fixture.observer.enteredCount == 2)
        #expect(await fixture.observer.maximumActive == 1)
        #expect(fixture.queue.availablePlaces == 1)
    }

    @Test("two sessions and a fork over one container each get their own executor")
    func eachSessionOverOneContainerGetsItsOwnExecutor() async throws {
        let fixture = Fixture()
        await fixture.latch.open()
        let first = fixture.container.makeSession(instructions: nil)
        let second = fixture.container.makeSession(instructions: nil)

        _ = try await first.respond(to: "first-1", maxTokens: nil)
        _ = try await second.respond(to: "second-1", maxTokens: nil)
        _ = try await first.respond(to: "first-2", maxTokens: nil)
        _ = try await second.respond(to: "second-2", maxTokens: nil)
        let fork = first.makeFork()
        _ = try await fork.respond(to: "fork-1", maxTokens: nil)

        let passes = fixture.passes
        let firstExecutors = passes.executors(servingPrompt: "first-1")
            .union(passes.executors(servingPrompt: "first-2"))
        let secondExecutors = passes.executors(servingPrompt: "second-1")
            .union(passes.executors(servingPrompt: "second-2"))
        let forkExecutors = passes.executors(servingPrompt: "fork-1")
        #expect(passes.recorded.count == 5)
        #expect(firstExecutors.count == 1)
        #expect(secondExecutors.count == 1)
        #expect(forkExecutors.count == 1)
        #expect(firstExecutors.isDisjoint(with: secondExecutors))
        #expect(firstExecutors.isDisjoint(with: forkExecutors))
        #expect(secondExecutors.isDisjoint(with: forkExecutors))
    }

    @Test("a pass cancelled while it waits for a queue place throws CancellationError and takes no place")
    func cancelledWaitingPassLeavesNoPlaceTaken() async throws {
        let fixture = Fixture()
        let holder = fixture.container.makeSession(instructions: nil)
        let waiter = fixture.container.makeSession(instructions: nil)

        let holdingTurn = Task { try await holder.respond(to: "holder", maxTokens: nil) }
        _ = await BoundedWait.conditionReached("the holding pass entered the model") {
            await fixture.observer.enteredCount == 1
        }
        let waitingTurn = Task { try await waiter.respond(to: "waiter", maxTokens: nil) }
        _ = await BoundedWait.conditionReached("the second pass waited for a queue place") {
            fixture.queue.waiterCount == 1
        }
        waitingTurn.cancel()
        let waitingOutcome = await waitingTurn.result
        let waiterCountAfterCancel = fixture.queue.waiterCount

        await fixture.latch.open()
        _ = try await holdingTurn.value

        #expect(throws: CancellationError.self) { try waitingOutcome.get() }
        #expect(waiterCountAfterCancel == 0)
        #expect(fixture.queue.availablePlaces == 1)
        #expect(fixture.passes.executors(servingPrompt: "waiter").isEmpty)
    }

    @Test("two wrappers over one model and one queue are two executor cache keys")
    func wrappersOverOneQueueCompareByTheirOwnState() {
        let queue = GenerationQueue()
        let model = Self.makeUnloadableMLXModel()
        let first = QueuedLanguageModel(wrapping: model, queue: queue)
        let second = QueuedLanguageModel(wrapping: model, queue: queue)

        #expect(first.executorConfiguration == first.executorConfiguration)
        #expect(first.executorConfiguration != second.executorConfiguration)
    }

    @Test("the live container gives a new wrapper over its own queue on each read of languageModel")
    func liveContainerWrapsItsRawModelOnEachRead() throws {
        let container = Self.makeLiveContainer()

        let first = try #require(container.languageModel as? QueuedLanguageModel)
        let second = try #require(container.languageModel as? QueuedLanguageModel)

        #expect(first.state !== second.state)
        #expect(first.state.queue === container.generationQueue)
        #expect(second.state.queue === container.generationQueue)
        let wrapped = try #require(first.state.wrapped as? MLXLanguageModel)
        #expect(wrapped.modelID == container.model.modelID)
    }

    @Test("respondWithoutReasoning still finds the raw MLX model behind the wrapper, in a fork too")
    func liveBackendFindsTheRawModelForThinkingControl() throws {
        let container = Self.makeLiveContainer()
        let rawModelID = container.model.modelID

        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend)
        let fork = try #require(backend.makeFork() as? MLXFoundationModelsSessionBackend)
        let replaced = try #require(
            backend.replacingTranscript(Transcript(entries: [])) as? MLXFoundationModelsSessionBackend)

        #expect(backend.mlxLanguageModel?.modelID == rawModelID)
        #expect(fork.mlxLanguageModel?.modelID == rawModelID)
        #expect(replaced.mlxLanguageModel?.modelID == rawModelID)
    }
}
