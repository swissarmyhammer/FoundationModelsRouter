import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Spike of task ^jdp02p (`generation-queue.md`, section 5, "Sessions as work
/// queues"): the queue item is one submission to Foundation, and mail goes
/// between two submissions.
///
/// The user said on 2026-09-25: "going to Foundation to generate -- or call
/// tools which might be multiple 'steps' inside Foundation -- that submission
/// to Foundation needs to be queued". So one item is one whole SDK call, with
/// all of its passes and tool bodies.
///
/// The spike puts a test model of that queue, ``SubmissionWorker``, in front
/// of the production session code. It proves three facts over the scripted
/// model, with no change to production code:
///
/// 1. One worker runs whole submissions of two sessions on one model, one at
///    a time, first in first out.
/// 2. A tool that starts a child session on the same model does not wait for
///    it: the tool is a background tool, so it returns at once, the
///    submission of the parent ends, and the submission of the child runs
///    next. A tool that waited in its body would never end, because the
///    submission of the child waits behind the submission of the parent.
/// 3. The result of the child comes back to the parent as mail, and the mail
///    causes the next submission of the parent, with the result in the
///    prompt of that submission.
@Suite("Spike: the queue item is one submission, and mail goes between submissions (task ^jdp02p)")
struct SubmissionQueueSpikeTests {
    /// A test model of the per-model work queue of the design: one worker runs
    /// whole submissions, one at a time, in the order they came.
    ///
    /// A submitter gives the worker its submission and waits for the result of
    /// that submission. It does not take or wait on a lock: it waits only for
    /// its own result. The worker is an actor, so the list of waiting
    /// submissions has no lock either. While a submission runs, the actor is
    /// free, so a new submission can join the list.
    private actor SubmissionWorker {
        /// One submission that waits for the worker.
        private struct Waiting {
            /// The name the test reads back in ``startedLabels``.
            let label: String

            /// Runs the submission and gives its result to its submitter.
            let run: @Sendable () async -> Void
        }

        /// The submissions that wait, first in first out.
        private var waiting: [Waiting] = []

        /// The task that runs the waiting submissions, while one runs.
        private var drain: Task<Void, Never>?

        /// The label of each submission, in the order the worker started it.
        private(set) var startedLabels: [String] = []

        /// Adds `submission` to the end of the queue, and waits for its result.
        ///
        /// - Parameters:
        ///   - label: The name of the submission in ``startedLabels``.
        ///   - submission: The whole submission: one SDK call of one session.
        /// - Returns: What `submission` returns.
        /// - Throws: What `submission` throws.
        func submit<Result: Sendable>(
            _ label: String, _ submission: @escaping @Sendable () async throws -> Result
        ) async throws -> Result {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(
                    Waiting(label: label) {
                        do {
                            continuation.resume(returning: try await submission())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    })
                startDrainIfIdle()
            }
        }

        /// Starts the drain task when no submission runs.
        private func startDrainIfIdle() {
            guard drain == nil else { return }
            drain = Task { await self.runWaitingSubmissions() }
        }

        /// Runs each waiting submission to its end, in order, until none waits.
        ///
        /// The check for an empty queue and the reset of ``drain`` have no
        /// suspension point between them, so a submission that joins the queue
        /// is always run.
        private func runWaitingSubmissions() async {
            while !waiting.isEmpty {
                let next = waiting.removeFirst()
                startedLabels.append(next.label)
                await next.run()
            }
            drain = nil
        }
    }

    /// A flag that exactly one caller takes.
    private final class FirstCallFlag: Sendable {
        /// Whether a caller already took the flag.
        private let taken = Atomic<Bool>(false)

        /// Takes the flag.
        ///
        /// - Returns: `true` for the first caller only.
        func take() -> Bool {
            !taken.exchange(true, ordering: .sequentiallyConsistent)
        }
    }

    /// A background tool whose first call starts a submission of a child
    /// session on the worker, and answers with the answer of the child.
    ///
    /// The model calls the tool again in the delivery submission of the
    /// parent. The later calls start nothing, so the test sees exactly one
    /// submission of the child.
    private struct ChildStartingTool: Tool, BackgroundTool {
        let name = "child_starting_tool"
        let description = "in the background, submits a prompt to a child session and answers with its answer"

        /// The session the first call asks for an answer.
        let child: any RoutedSession

        /// The worker the submission of the child goes to.
        let worker: SubmissionWorker

        /// Taken by the first call, which starts the submission of the child.
        let firstCall: FirstCallFlag

        /// Every call goes to the background at once.
        var mount: ToolMount? { ToolMount(mode: .background) }

        func call(arguments: MountArguments) async throws -> String {
            guard firstCall.take() else { return SubmissionQueueSpikeTests.nothingStarted }
            let child = child
            return try await worker.submit(SubmissionQueueSpikeTests.childLabel) {
                try await child.respond(to: SubmissionQueueSpikeTests.childPrompt)
            }
        }
    }

    /// The prompt of the first submission of the parent.
    private static let parentPrompt = "a"

    /// The prompt the tool gives the child.
    private static let childPrompt = "b"

    /// The label of each submission of the parent.
    private static let parentLabel = "parent"

    /// The label of the submission of the child.
    private static let childLabel = "child"

    /// The answer of each later call of the tool.
    private static let nothingStarted = "nothing new started"

    /// The passes before the delivery submission of the parent: the two
    /// passes of its first submission (the tool call, then the answer), and
    /// the one pass of the submission of the child.
    private static let passesBeforeDelivery = 3

    @Test("a child result delivered as mail causes the next submission of its parent, with the result in its prompt")
    func aChildResultDeliveredAsMailCausesTheNextSubmission() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SubmissionQueueSpikeTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let worker = SubmissionWorker()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(
            tools: [ChildStartingTool(child: child, worker: worker, firstCall: FirstCallFlag())])

        // The mail: the terminal of the background run, whose detail is the
        // answer of the child. The subscription opens before the first
        // submission, so it cannot miss the terminal.
        let sessionEvents = await parent.streamSessionEvents()
        let runSettled = AsyncSemaphore(value: 0)
        let settledRun = Task { () -> OperationEvent? in
            defer { runSettled.signal() }
            for await event in sessionEvents {
                if case .runSettled(let terminal) = event {
                    return terminal
                }
            }
            return nil
        }

        // The first submission of the parent. `streamEvents` ends with its SDK
        // call and does not wait for the background run, as a submission must
        // not wait. Bounded, so a tool that waits in its body fails the test
        // and does not hang the run.
        let firstSubmissionEnded = AsyncSemaphore(value: 0)
        let firstSubmission = Task {
            defer { firstSubmissionEnded.signal() }
            try await worker.submit(Self.parentLabel) {
                for try await _ in await parent.streamEvents(to: Self.parentPrompt) {}
            }
        }
        try #require(
            await BoundedWait.signalArrived(
                firstSubmissionEnded, named: "the first submission of the parent, while its tool starts the child"))
        try await firstSubmission.value

        try #require(
            await BoundedWait.signalArrived(
                runSettled, named: "the terminal of the background run, after the submission of the child"))
        let terminal = await settledRun.value

        // The pump of the parent: the waiting mail causes the next submission.
        let delivered = try await worker.submit(Self.parentLabel) {
            try await parent.dispatchNextPrompt()
        }

        let childAnswer = PassObservingModel.answer(to: Self.childPrompt)
        let prompts = fixture.passes.recorded.map(\.prompt)
        let deliveryPrompt = try #require(prompts.dropFirst(Self.passesBeforeDelivery).first)
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == childAnswer)
        #expect(await worker.startedLabels == [Self.parentLabel, Self.childLabel, Self.parentLabel])
        #expect(
            Array(prompts.prefix(Self.passesBeforeDelivery))
                == [Self.parentPrompt, Self.parentPrompt, Self.childPrompt])
        #expect(deliveryPrompt.contains(childAnswer))
        #expect(deliveryPrompt.contains(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(delivered == PassObservingModel.answer(to: deliveryPrompt))
        withExtendedLifetime(resolved) {}
    }
}
