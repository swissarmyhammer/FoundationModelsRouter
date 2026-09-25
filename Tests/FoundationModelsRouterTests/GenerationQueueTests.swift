import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter

/// Tasks ^8csj2hw and ^1psqdm9: the generation queue of one container, and
/// the per-session wrapper of each backend (`generation-queue.md`, sections
/// 5.1 and 5.3).
///
/// Each backend a container makes runs its `LanguageModelSession` over its own
/// ``SessionLanguageModel``, and declares the one ``GenerationQueue`` of the
/// container (``LanguageModelSessionBackend/generationQueue``). The session
/// submits each whole SDK call of the backend to that queue.
/// ``PassObservingModel`` makes each executor call an observable pass that
/// stays open until a ``RunLatch`` opens, so a test sees an overlap, a waiting
/// submission, and which executor ran each pass. The backends are the
/// production ``MLXFoundationModelsSessionBackend`` over the scripted model,
/// through ``LiveBackendContainer``.
@Suite("Generation queue: one submission at a time for each container (tasks ^8csj2hw, ^1psqdm9)")
struct GenerationQueueTests {
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

    /// Submits one whole call of `backend` to `queue`, as a session submits
    /// the SDK call of its backend.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the call.
    ///   - backend: The backend whose call is the item.
    ///   - queue: The queue the item goes to.
    /// - Returns: The answer of the call.
    /// - Throws: What the queue or the call throws.
    private static func submitCall(
        _ prompt: String, of backend: any LanguageModelSessionBackend, to queue: GenerationQueue
    ) async throws -> String {
        try await queue.submit { try await backend.respond(to: prompt, maxTokens: nil) }
    }

    @Test("two whole calls submitted to the queue of one container never run at the same time")
    func twoSubmissionsOverOneContainerNeverOverlap() async throws {
        let fixture = PassObservingFixture()
        let first = fixture.container.makeSession(instructions: nil)
        let second = fixture.container.makeSession(instructions: nil)
        let queue = try #require(first.generationQueue)

        let firstCall = Task { try await Self.submitCall("first", of: first, to: queue) }
        _ = await BoundedWait.conditionReached("the first pass entered the model") {
            await fixture.observer.enteredCount == 1
        }
        let secondCall = Task { try await Self.submitCall("second", of: second, to: queue) }
        _ = await BoundedWait.conditionReached("the second submission waited for the worker") {
            await fixture.queue.waitingCount == 1
        }
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        let firstAnswer = try await firstCall.value
        let secondAnswer = try await secondCall.value

        #expect(queue === fixture.queue)
        #expect(second.generationQueue === fixture.queue)
        #expect(firstAnswer == PassObservingModel.answer(to: "first"))
        #expect(secondAnswer == PassObservingModel.answer(to: "second"))
        #expect(await fixture.observer.enteredCount == 2)
        #expect(await fixture.observer.maximumActive == 1)
        #expect(await fixture.queue.isRunning == false)
    }

    @Test("two sessions and a fork over one container each get their own executor")
    func eachSessionOverOneContainerGetsItsOwnExecutor() async throws {
        let fixture = PassObservingFixture()
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

    @Test("a submission cancelled while it waits for the worker throws CancellationError and never runs")
    func cancelledWaitingSubmissionNeverRuns() async throws {
        let fixture = PassObservingFixture()
        let holder = fixture.container.makeSession(instructions: nil)
        let waiter = fixture.container.makeSession(instructions: nil)

        let holdingCall = Task { try await Self.submitCall("holder", of: holder, to: fixture.queue) }
        _ = await BoundedWait.conditionReached("the holding pass entered the model") {
            await fixture.observer.enteredCount == 1
        }
        let waitingCall = Task { try await Self.submitCall("waiter", of: waiter, to: fixture.queue) }
        _ = await BoundedWait.conditionReached("the second submission waited for the worker") {
            await fixture.queue.waitingCount == 1
        }
        waitingCall.cancel()
        let waitingOutcome = await waitingCall.result
        let waiterCountAfterCancel = await fixture.queue.waitingCount

        await fixture.latch.open()
        _ = try await holdingCall.value

        #expect(throws: CancellationError.self) { try waitingOutcome.get() }
        #expect(waiterCountAfterCancel == 0)
        #expect(await fixture.queue.isRunning == false)
        #expect(fixture.passes.executors(servingPrompt: "waiter").isEmpty)
    }

    @Test("a submission reports that it waits only when the worker runs another item (task ^ake8sax)")
    func aSubmissionReportsItsWaitOnlyWhenTheWorkerIsBusy() async throws {
        let queue = GenerationQueue()
        let entered = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let holderWaits = AsyncSemaphore(value: 0)
        let waiterWaits = AsyncSemaphore(value: 0)

        let holdingSubmission = Task {
            try await queue.submit(onQueued: { holderWaits.signal() }) {
                entered.signal()
                await release.wait()
            }
        }
        let holderInside = await BoundedWait.signalArrived(entered, named: "the holding submission started")
        let waitingSubmission = Task {
            try await queue.submit(onQueued: { waiterWaits.signal() }) {}
        }
        let waiterQueued = await BoundedWait.conditionReached("the second submission waited for the worker") {
            await queue.waitingCount == 1
        }
        release.signal()
        try await holdingSubmission.value
        try await waitingSubmission.value

        #expect(holderInside)
        #expect(waiterQueued)
        #expect(holderWaits.availablePermits == 0)
        #expect(waiterWaits.availablePermits == 1)
        #expect(await queue.isRunning == false)
    }

    @Test("two wrappers over one model are two executor cache keys")
    func wrappersOverOneModelCompareByTheirOwnState() {
        let model = Self.makeUnloadableMLXModel()
        let first = SessionLanguageModel(wrapping: model)
        let second = SessionLanguageModel(wrapping: model)

        #expect(first.executorConfiguration != second.executorConfiguration)
        #expect(first.state.passQueue == nil)
    }

    @Test("the live container gives a new wrapper on each read of languageModel, whose each pass is one item")
    func liveContainerWrapsItsRawModelOnEachRead() throws {
        let container = Self.makeLiveContainer()

        let first = try #require(container.languageModel as? SessionLanguageModel)
        let second = try #require(container.languageModel as? SessionLanguageModel)

        #expect(first.state !== second.state)
        #expect(first.state.passQueue === container.generationQueue)
        #expect(second.state.passQueue === container.generationQueue)
        let wrapped = try #require(first.state.wrapped as? MLXLanguageModel)
        #expect(wrapped.modelID == container.model.modelID)
    }

    @Test("a live backend, its fork and a replaced transcript declare the queue of their container")
    func liveBackendDeclaresTheQueueOfItsContainer() {
        let container = Self.makeLiveContainer()
        let backend = container.makeSession(instructions: nil)

        #expect(backend.generationQueue === container.generationQueue)
        #expect(backend.makeFork().generationQueue === container.generationQueue)
        #expect(backend.replacingTranscript(Transcript(entries: [])).generationQueue === container.generationQueue)
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
