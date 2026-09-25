import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Task ^a0ze9af: the generation queue is a work queue with one worker, not a
/// semaphore (`generation-queue.md`, section 5.3).
///
/// A submitter gives the queue one item and waits only for the result of that
/// item. One worker runs the items one at a time, first in first out, on a
/// task that the worker makes. These tests read the order, the overlap and
/// the cancel of the items from the items themselves, and read the list of
/// the queue through ``GenerationQueue/isRunning`` and
/// ``GenerationQueue/waitingCount``.
@Suite("Generation queue: one worker runs the items, first in first out (task ^a0ze9af)")
struct GenerationQueueWorkerTests {
    /// Records which items started, in order, and how many ran at one time.
    private actor ItemLog {
        /// The names of the items that started, in the order they started.
        private(set) var started: [String] = []

        /// The items that run now.
        private var active = 0

        /// The largest number of items that ran at one time.
        private(set) var peak = 0

        /// Records that the item `name` started.
        ///
        /// - Parameter name: The name of the item.
        func enter(_ name: String) {
            started.append(name)
            active += 1
            peak = max(peak, active)
        }

        /// Records that one item ended.
        func exit() {
            active -= 1
        }
    }

    /// Keeps the outcome of one submitter, so a test reads it inside a bound
    /// instead of an `await` that can hang.
    private final class OutcomeBox<Value: Sendable>: Sendable {
        /// The outcome, or `nil` while the submitter waits.
        private let stored = Mutex<Result<Value, any Error>?>(nil)

        /// The outcome, or `nil` while the submitter waits.
        var outcome: Result<Value, any Error>? { stored.withLock { $0 } }

        /// Keeps `outcome`.
        ///
        /// - Parameter outcome: The outcome of the submitter.
        func store(_ outcome: Result<Value, any Error>) {
            stored.withLock { $0 = outcome }
        }
    }

    /// A flag that an item sets when its body runs.
    private final class RanFlag: Sendable {
        /// Whether the body ran.
        private let ran = Atomic<Bool>(false)

        /// Whether the body ran.
        var isSet: Bool { ran.load(ordering: .sequentiallyConsistent) }

        /// Records that the body ran.
        func set() {
            ran.store(true, ordering: .sequentiallyConsistent)
        }
    }

    /// The number of items that wait behind the first item in the FIFO test.
    private static let itemsBehindTheFirst = 2

    /// How many times the race test races a cancel against the start of an
    /// item.
    private static let raceRepetitions = 300

    /// The value the raced item returns when its body runs.
    private static let racedValue = 7

    /// The value of the item that follows the raced item.
    private static let nextValue = 11

    /// Submits `body` to `queue` on a new task, and keeps the outcome of that
    /// task in the returned box.
    ///
    /// - Parameters:
    ///   - queue: The queue to submit to.
    ///   - body: The item.
    /// - Returns: The task of the submitter, and the box of its outcome.
    private static func submit<Value: Sendable>(
        to queue: GenerationQueue, _ body: @escaping @Sendable () async throws -> Value
    ) -> (task: Task<Void, Never>, box: OutcomeBox<Value>) {
        let box = OutcomeBox<Value>()
        let task = Task {
            let outcome: Result<Value, any Error>
            do {
                outcome = .success(try await queue.submit(body))
            } catch {
                outcome = .failure(error)
            }
            box.store(outcome)
        }
        return (task, box)
    }

    /// Waits inside the bound until `box` holds an outcome.
    ///
    /// - Parameters:
    ///   - box: The box of one submitter.
    ///   - label: What the outcome means, named in the recorded issue.
    /// - Returns: The outcome.
    /// - Throws: An `ExpectationFailedError` when no outcome came inside the
    ///   bound.
    private static func outcome<Value: Sendable>(
        of box: OutcomeBox<Value>, named label: String
    ) async throws -> Result<Value, any Error> {
        _ = await BoundedWait.conditionReached(label) { box.outcome != nil }
        return try #require(box.outcome)
    }

    /// Whether `outcome` is a `CancellationError`.
    ///
    /// - Parameter outcome: The outcome of one submitter.
    /// - Returns: `true` for a `CancellationError`.
    private static func isCancellation<Value>(_ outcome: Result<Value, any Error>) -> Bool {
        guard case .failure(let error) = outcome else { return false }
        return error is CancellationError
    }

    /// Starts an item on `queue` that holds the worker until `release` gets a
    /// signal, and waits until that item runs.
    ///
    /// - Parameters:
    ///   - queue: The queue.
    ///   - log: The log the item enters, as `"holder"`.
    ///   - release: The semaphore that ends the item.
    /// - Returns: The task of the submitter, and the box of its outcome.
    /// - Throws: An `ExpectationFailedError` when the item never ran.
    private static func startHolder(
        on queue: GenerationQueue, log: ItemLog, release: AsyncSemaphore
    ) async throws -> (task: Task<Void, Never>, box: OutcomeBox<String>) {
        let holder = submit(to: queue) {
            await log.enter("holder")
            await release.wait()
            await log.exit()
            return "holder"
        }
        try #require(await BoundedWait.conditionReached("the holding item runs") { await log.started == ["holder"] })
        return holder
    }

    /// Submits the item `name` to `queue`, and waits until the list holds
    /// `waiting` items.
    ///
    /// - Parameters:
    ///   - name: The name of the item, which it also returns.
    ///   - queue: The queue.
    ///   - log: The log the item enters.
    ///   - waiting: The count of waiting items after this item joins.
    /// - Returns: The task of the submitter, and the box of its outcome.
    private static func submitWaiting(
        _ name: String, to queue: GenerationQueue, log: ItemLog, waiting: Int
    ) async -> (task: Task<Void, Never>, box: OutcomeBox<String>) {
        let item = submit(to: queue) {
            await log.enter(name)
            await log.exit()
            return name
        }
        _ = await BoundedWait.conditionReached("the item \(name) waits") { await queue.waitingCount == waiting }
        return item
    }

    @Test("items from three tasks run in FIFO order, one at a time, with no overlap")
    func itemsFromThreeTasksRunInOrderWithNoOverlap() async throws {
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = AsyncSemaphore(value: 0)
        let first = try await Self.startHolder(on: queue, log: log, release: release)
        let second = await Self.submitWaiting("second", to: queue, log: log, waiting: 1)
        let third = await Self.submitWaiting("third", to: queue, log: log, waiting: Self.itemsBehindTheFirst)
        let startedBeforeRelease = await log.started

        release.signal()
        let answers = try await [
            Self.outcome(of: first.box, named: "the first result").get(),
            Self.outcome(of: second.box, named: "the second result").get(),
            Self.outcome(of: third.box, named: "the third result").get(),
        ]

        #expect(startedBeforeRelease == ["holder"])
        #expect(answers == ["holder", "second", "third"])
        #expect(await log.started == ["holder", "second", "third"])
        #expect(await log.peak == 1)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    @Test("a cancelled waiting item never runs, its submitter gets CancellationError at once, and the next item runs")
    func aCancelledWaitingItemNeverRunsAndTheNextItemRuns() async throws {
        let queue = GenerationQueue()
        let log = ItemLog()
        let release = AsyncSemaphore(value: 0)
        let holder = try await Self.startHolder(on: queue, log: log, release: release)
        let cancelled = await Self.submitWaiting("cancelled", to: queue, log: log, waiting: 1)
        let next = await Self.submitWaiting("next", to: queue, log: log, waiting: Self.itemsBehindTheFirst)

        cancelled.task.cancel()
        let cancelledOutcome = try await Self.outcome(of: cancelled.box, named: "the cancelled result")
        let holderStillRuns = await queue.isRunning && holder.box.outcome == nil
        let waitingAfterCancel = await queue.waitingCount
        release.signal()
        let nextAnswer = try await Self.outcome(of: next.box, named: "the next result").get()

        #expect(Self.isCancellation(cancelledOutcome))
        #expect(holderStillRuns)
        #expect(waitingAfterCancel == 1)
        #expect(nextAnswer == "next")
        #expect(await log.started == ["holder", "next"])
        #expect(await queue.isRunning == false)
    }

    @Test("a cancelled waiting item leaves the count of waiting items when the cancel returns")
    func aCancelledWaitingItemLeavesTheCountWhenTheCancelReturns() async throws {
        for _ in 0..<Self.raceRepetitions {
            let queue = GenerationQueue()
            let log = ItemLog()
            let release = AsyncSemaphore(value: 0)
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let cancelled = await Self.submitWaiting("cancelled", to: queue, log: log, waiting: 1)

            cancelled.task.cancel()
            let waitingAfterCancel = await queue.waitingCount
            release.signal()
            let cancelledOutcome = try await Self.outcome(of: cancelled.box, named: "the cancelled result")
            _ = try await Self.outcome(of: holder.box, named: "the holder result")

            #expect(waitingAfterCancel == 0)
            #expect(Self.isCancellation(cancelledOutcome))
            #expect(await log.started == ["holder"])
        }
    }

    @Test("a cancelled running item gets the cancel on the task that runs it, and the next item runs")
    func aCancelledRunningItemGetsTheCancel() async throws {
        let queue = GenerationQueue()
        let log = ItemLog()
        let running = Self.submit(to: queue) {
            await log.enter("running")
            while !Task.isCancelled {
                await Task.yield()
            }
            await log.exit()
            throw CancellationError()
        }
        _ = await BoundedWait.conditionReached("the item runs") { await log.started == ["running"] }
        let next = await Self.submitWaiting("next", to: queue, log: log, waiting: 1)

        running.task.cancel()
        let runningOutcome = try await Self.outcome(of: running.box, named: "the cancelled running result")
        let nextAnswer = try await Self.outcome(of: next.box, named: "the next result").get()

        #expect(Self.isCancellation(runningOutcome))
        #expect(nextAnswer == "next")
        #expect(await log.started == ["running", "next"])
    }

    @Test("a cancel that races the start of an item resumes its submitter one time, and the queue runs the next item")
    func aCancelThatRacesTheStartOfAnItemResumesOneTime() async throws {
        for _ in 0..<Self.raceRepetitions {
            let queue = GenerationQueue()
            let log = ItemLog()
            let release = AsyncSemaphore(value: 0)
            let holder = try await Self.startHolder(on: queue, log: log, release: release)
            let ran = RanFlag()
            let raced = Self.submit(to: queue) {
                ran.set()
                return Self.racedValue
            }
            _ = await BoundedWait.conditionReached("the raced item waits") { await queue.waitingCount == 1 }

            release.signal()
            raced.task.cancel()
            let racedOutcome = try await Self.outcome(of: raced.box, named: "the raced result")
            let next = Self.submit(to: queue) { Self.nextValue }
            let nextAnswer = try await Self.outcome(of: next.box, named: "the next result").get()
            _ = try await Self.outcome(of: holder.box, named: "the holder result")

            let ranAndAnswered = ran.isSet && (try? racedOutcome.get()) == Self.racedValue
            let refusedAndNeverRan = !ran.isSet && Self.isCancellation(racedOutcome)
            #expect(ranAndAnswered || refusedAndNeverRan)
            #expect(nextAnswer == Self.nextValue)
            #expect(await queue.isRunning == false)
            #expect(await queue.waitingCount == 0)
        }
    }

    @Test("a submitter that is cancelled before it submits gets CancellationError, and its item never runs")
    func anAlreadyCancelledSubmitterNeverRunsItsItem() async throws {
        let queue = GenerationQueue()
        let ran = RanFlag()
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.submit { ran.set() }
        }.result

        #expect(Self.isCancellation(outcome))
        #expect(!ran.isSet)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    /// The model the marks of the refusal tests name.
    private static let markedModel: ModelRef = "org/marked-model"

    /// Submits an item that sets `ran` to `queue`, under `mark`, and gives its
    /// outcome.
    ///
    /// - Parameters:
    ///   - queue: The queue to submit to.
    ///   - mark: The model-call mark of the submitting task.
    ///   - ran: The flag the item sets when it runs.
    /// - Returns: The outcome of the submission.
    private static func submitUnderMark(
        to queue: GenerationQueue, mark: ModelCallMark, ran: RanFlag
    ) async -> Result<Int, any Error> {
        await ModelCallMark.$current.withValue(mark) {
            do {
                return .success(
                    try await queue.submit {
                        ran.set()
                        return Self.racedValue
                    })
            } catch {
                return .failure(error)
            }
        }
    }

    @Test("a submission from a task inside an open submission on the same queue is refused at once, and never runs")
    func aSubmissionInsideAnOpenSubmissionOnTheSameQueueIsRefused() async throws {
        let queue = GenerationQueue()
        let ran = RanFlag()
        let mark = ModelCallMark(
            sessionID: ULID.generate(), submission: SubmissionTarget(queue: queue, model: Self.markedModel))

        let outcome = await Self.submitUnderMark(to: queue, mark: mark, ran: ran)

        #expect(throws: GenerationQueueError.waitInsideOpenSubmission(model: Self.markedModel)) {
            try outcome.get()
        }
        #expect(!ran.isSet)
        #expect(await queue.isRunning == false)
        #expect(await queue.waitingCount == 0)
    }

    @Test("a submission under a closed mark, or an open mark of another queue, runs")
    func aSubmissionOutsideAnOpenSubmissionOnItsQueueRuns() async throws {
        let queue = GenerationQueue()
        let otherQueue = GenerationQueue()
        let closed = ModelCallMark(
            sessionID: ULID.generate(), submission: SubmissionTarget(queue: queue, model: Self.markedModel))
        closed.close()
        let otherModel = ModelCallMark(
            sessionID: ULID.generate(), submission: SubmissionTarget(queue: otherQueue, model: Self.markedModel))
        let ranUnderClosed = RanFlag()
        let ranUnderOther = RanFlag()

        let closedOutcome = await Self.submitUnderMark(to: queue, mark: closed, ran: ranUnderClosed)
        let otherOutcome = await Self.submitUnderMark(to: queue, mark: otherModel, ran: ranUnderOther)

        #expect(try closedOutcome.get() == Self.racedValue)
        #expect(try otherOutcome.get() == Self.racedValue)
        #expect(ranUnderClosed.isSet)
        #expect(ranUnderOther.isSet)
    }

    @Test("a background run of an open submission is not refused a submission on the same queue")
    func aBackgroundRunOfAnOpenSubmissionIsNotRefused() async throws {
        let queue = GenerationQueue()
        let ran = RanFlag()
        let open = ModelCallMark(
            sessionID: ULID.generate(), submission: SubmissionTarget(queue: queue, model: Self.markedModel))

        let outcome = await ModelCallMark.$current.withValue(open) {
            await ModelCallMark.withBackgroundRunMark {
                await Self.submitUnderMark(to: queue, mark: ModelCallMark.current ?? open, ran: ran)
            }
        }

        #expect(try outcome.get() == Self.racedValue)
        #expect(ran.isSet)
    }
}

/// An item runs on the task of the worker, and the SDK call returns the output
/// of its pass (tasks ^a0ze9af and ^1psqdm9).
///
/// ``SubmitterMarkModel`` answers with the value of a task-local that the
/// test binds around the SDK call. The SDK gives task-locals to the executor
/// (the control test), so a pass that answers "none" ran on a task that the
/// worker made, which inherits no task-local of the submitter. That holds for
/// a whole SDK call submitted as one item, and for each pass of a
/// ``SessionLanguageModel`` whose passes are items.
@Suite("Generation queue: an item runs on the worker task (tasks ^a0ze9af, ^1psqdm9)")
struct GenerationQueueWorkerTaskTests {
    /// The task-local that the test binds around the SDK call.
    enum SubmitterMark {
        /// The mark of the task that calls the SDK, or `nil` when no caller
        /// bound one.
        @TaskLocal static var value: String?
    }

    /// A scripted `LanguageModel` whose one pass answers with the
    /// ``SubmitterMark`` that the task of the pass sees.
    struct SubmitterMarkModel: LanguageModel {
        /// The text an answer opens with.
        static let answerPrefix = "seen: "

        /// The mark an answer names when the pass sees no mark.
        static let noMark = "none"

        /// The answer of a pass that sees `mark`.
        ///
        /// - Parameter mark: The mark the pass sees, or `nil`.
        /// - Returns: The answer text.
        static func answer(seeing mark: String?) -> String {
            answerPrefix + (mark ?? noMark)
        }

        /// The model answers text only.
        var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

        /// The empty executor cache key.
        var executorConfiguration: Executor.Configuration { Executor.Configuration() }

        /// The executor that answers with the mark its task sees.
        struct Executor: LanguageModelExecutor {
            /// The empty cache key: the executor holds no data.
            struct Configuration: Sendable, Hashable {}

            /// The model type this executor serves.
            typealias Model = SubmitterMarkModel

            /// The token count the one emitted fragment reports.
            private static let emittedTokenCount = 1

            /// Makes the executor. The configuration carries no data.
            ///
            /// - Parameter configuration: The empty configuration.
            /// - Throws: Never. `throws` comes from the protocol requirement.
            init(configuration: Configuration) throws {}

            /// Answers with the mark that the task of this pass sees.
            ///
            /// - Parameters:
            ///   - request: The generation request. Unread.
            ///   - model: The model. Unread.
            ///   - channel: The channel the pass emits into.
            /// - Throws: Never. `throws` comes from the protocol requirement.
            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: SubmitterMarkModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                let text = SubmitterMarkModel.answer(seeing: SubmitterMark.value)
                await channel.send(.response(action: .appendText(text, tokenCount: Self.emittedTokenCount)))
            }
        }
    }

    /// The mark the test binds around each SDK call.
    private static let submitterMark = "submitter"

    /// Calls the SDK over `model` with ``SubmitterMark`` bound.
    ///
    /// - Parameter model: The model of the SDK session.
    /// - Returns: The content of the SDK response.
    /// - Throws: What the SDK call throws.
    private static func respondWithMark(over model: some LanguageModel) async throws -> String {
        try await SubmitterMark.$value.withValue(submitterMark) {
            let session = LanguageModelSession(model: model, tools: [])
            return try await session.respond(to: "which mark").content
        }
    }

    @Test("with no queue, the SDK gives the task-local of the caller to the pass (the control)")
    func theSDKGivesTheCallerTaskLocalToThePass() async throws {
        let content = try await Self.respondWithMark(over: SubmitterMarkModel())

        #expect(content == SubmitterMarkModel.answer(seeing: Self.submitterMark))
    }

    @Test("behind a wrapper whose each pass is an item, the pass runs on the worker task, and the SDK call returns its output")
    func thePassRunsOnTheWorkerTaskAndTheSDKCallReturnsItsOutput() async throws {
        let queue = GenerationQueue()
        let model = SessionLanguageModel(wrapping: SubmitterMarkModel(), passQueue: queue)

        let content = try await Self.respondWithMark(over: model)

        #expect(content == SubmitterMarkModel.answer(seeing: nil))
        #expect(await queue.isRunning == false)
    }

    @Test("a whole SDK call submitted as one item runs on the worker task, and returns the output of its pass")
    func aWholeSDKCallRunsOnTheWorkerTask() async throws {
        let queue = GenerationQueue()
        let model = SessionLanguageModel(wrapping: SubmitterMarkModel())

        let content = try await SubmitterMark.$value.withValue(Self.submitterMark) {
            try await queue.submit {
                let session = LanguageModelSession(model: model, tools: [])
                return try await session.respond(to: "which mark").content
            }
        }

        #expect(content == SubmitterMarkModel.answer(seeing: nil))
        #expect(await queue.isRunning == false)
    }
}
