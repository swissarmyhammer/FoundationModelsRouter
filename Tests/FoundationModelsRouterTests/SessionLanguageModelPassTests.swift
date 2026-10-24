import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import Testing

@testable import FoundationModelsRouter

/// Tasks ^8csj2hw, ^1psqdm9 and ^qhgfajc: the per-session wrapper of each
/// backend, and the passes of the sessions over one model.
///
/// Each backend a container makes runs its `LanguageModelSession` over its own
/// ``SessionLanguageModel``. Each pass is one call into the model through
/// `PooledGeneration.run(ref:channel:_:)`, with no queue around the SDK call.
/// ``PassObservingModel`` holds a ``FIFOGenerationLock`` for each pass, as an
/// MLX model does, and stays open until a ``RunLatch`` opens. A test thus
/// sees an overlap, a pass that waits for the lock, and which executor ran
/// each pass. The backends are the production
/// ``MLXFoundationModelsSessionBackend`` over the scripted model, through
/// ``LiveBackendContainer``.
///
/// Rule T1: a backend has no end call and no cancel call for a `defer`, so
/// these tests close no backend. Each wait that a regression can keep open
/// is a ``BoundedWait``.
@Suite("The passes of the sessions over one model (tasks ^8csj2hw, ^1psqdm9, ^qhgfajc)")
struct SessionLanguageModelPassTests {
    /// The repository id of the raw MLX model the wrapper tests build. The
    /// model is never loaded.
    private static let rawModelRepository = "org/raw-model"

    /// An `MLXLanguageModel` whose load always fails. Nothing in these tests
    /// loads it.
    private static func makeUnloadableMLXModel() -> MLXLanguageModel {
        UnloadableMLXModel.make(repo: rawModelRepository)
    }

    /// A live container over ``makeUnloadableMLXModel()``.
    private static func makeLiveContainer() -> MLXFoundationModelsContainer {
        UnloadableMLXModel.liveContainer(repo: rawModelRepository)
    }

    @Test("two calls over one model take the lock of the model one at a time, first in first out")
    func twoCallsOverOneModelNeverOverlap() async throws {
        let fixture = PassObservingFixture()
        let first = fixture.container.makeSession(instructions: nil)
        let second = fixture.container.makeSession(instructions: nil)

        let firstCall = Task { try await first.respond(to: "first", maxTokens: nil) }
        // The wait also ends when the first call ends (rule T1): the latch
        // holds its pass, so in a test that passes it cannot end first.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: firstCall)
        }
        let secondCall = Task { try await second.respond(to: "second", maxTokens: nil) }
        // The second pass waits for the lock, which the first pass holds.
        try await BoundedWait.run { try await fixture.lock.waitForWaiters(1) }
        #expect(await fixture.observer.maximumActive == 1)

        await fixture.latch.open()
        let firstAnswer = try await BoundedWait.value(of: firstCall)
        let secondAnswer = try await BoundedWait.value(of: secondCall)

        #expect(firstAnswer == PassObservingModel.answer(to: "first"))
        #expect(secondAnswer == PassObservingModel.answer(to: "second"))
        #expect(fixture.passes.recorded.map(\.prompt) == ["first", "second"])
        #expect(await fixture.observer.enteredCount == 2)
        #expect(await fixture.observer.maximumActive == 1)
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

    @Test("a call cancelled while its pass waits for the lock of the model throws CancellationError at once")
    func aCallCancelledWhileItWaitsForTheLockThrowsAtOnce() async throws {
        let fixture = PassObservingFixture()
        let holder = fixture.container.makeSession(instructions: nil)
        let waiter = fixture.container.makeSession(instructions: nil)

        let holdingCall = Task { try await holder.respond(to: "holder", maxTokens: nil) }
        // The wait also ends when the holding call ends (rule T1): the latch
        // holds its pass, so in a test that passes it cannot end first.
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(
                for: { try await fixture.observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: holdingCall)
        }
        let waitingCall = Task { try await waiter.respond(to: "waiter", maxTokens: nil) }
        try await BoundedWait.run { try await fixture.lock.waitForWaiters(1) }

        // The cancel does not wait for the lock: the call ends while the
        // holder still holds it.
        waitingCall.cancel()
        let waitingOutcome = try await BoundedWait.run { await waitingCall.result }
        let passesWhileTheHolderHeldTheLock = fixture.passes.recorded.map(\.prompt)

        await fixture.latch.open()
        _ = try await BoundedWait.value(of: holdingCall)

        #expect(throws: CancellationError.self) { try waitingOutcome.get() }
        #expect(passesWhileTheHolderHeldTheLock == ["holder"])
    }

    @Test("two wrappers over one model are two executor cache keys")
    func wrappersOverOneModelCompareByTheirOwnState() {
        let model = Self.makeUnloadableMLXModel()
        let ref = ModelRef(repo: Self.rawModelRepository)
        let first = SessionLanguageModel(wrapping: model, ref: ref)
        let second = SessionLanguageModel(wrapping: model, ref: ref)

        #expect(first.executorConfiguration != second.executorConfiguration)
    }

    @Test("the backends, forks and replaced transcripts of the live container name the model reference of the container")
    func liveBackendNamesTheReferenceOfItsContainer() throws {
        let container = Self.makeLiveContainer()
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend)
        let fork = try #require(backend.makeFork() as? MLXFoundationModelsSessionBackend)
        let replaced = try #require(
            backend.replacingTranscript(Transcript(entries: [])) as? MLXFoundationModelsSessionBackend)

        #expect(container.ref == ModelRef(repo: Self.rawModelRepository))
        #expect(backend.ref == container.ref)
        #expect(fork.ref == container.ref)
        #expect(replaced.ref == container.ref)
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
