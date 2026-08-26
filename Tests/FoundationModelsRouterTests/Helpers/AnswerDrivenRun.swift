import Foundation
import Testing

@testable import FoundationModelsRouter

/// Thrown by ``AnswerDrivenRun/deliveredAnswer()`` when no answer ever reached
/// the background run, so the test that caught the fault stops there instead of
/// asserting on a result it never received.
struct AnswerNeverDelivered: Error {}

/// Records that an ``AnswerDrivenRun`` finished, so a test observes the run
/// ending without awaiting the run itself.
private actor RunCompletion {
    /// Whether the run has finished, whether it returned or threw.
    private(set) var isFinished = false

    /// Notes that the run finished.
    func noteFinished() {
        isFinished = true
    }
}

/// Work that only finishes once an answer is delivered to it — a suspended
/// ``ToolContext/elicit(_:)``, a ``SessionMailbox/awaitAnswer(to:posting:)``,
/// or a tool call blocked behind either — started so a test reads its result
/// under a bound instead of awaiting it.
///
/// The bound is the whole point. A regression anywhere on the inbound answer
/// route leaves the run suspended forever, and this test target sets no
/// `.timeLimit` trait, so awaiting such a run directly hangs the whole run of
/// `swift test` rather than failing the test that caught the fault. That is
/// the escape hatch `TurnCancellationTests` already carries for a stranded
/// generation permit — a bounded wait, then a recorded issue and a give-up
/// rather than a further await — in the shape the answer-delivery suites need.
///
/// ``deliveredAnswer()`` never awaits the run on its give-up path, and that is
/// deliberate: ``SessionMailbox`` suspends on a plain `withCheckedContinuation`,
/// which ignores cancellation, so a run no answer reached cannot be unwound at
/// all. Cancelling it and then awaiting it would hang in exactly the case this
/// bound exists to catch.
struct AnswerDrivenRun<Value: Sendable> {
    /// What the run is waiting for, named in the issue recorded when no answer
    /// arrives.
    private let label: String

    /// Tells whether the run finished, without awaiting ``task``.
    private let completion: RunCompletion

    /// The running work.
    private let task: Task<Value, Error>

    /// Starts `body` and begins tracking whether it finished.
    ///
    /// - Parameters:
    ///   - label: What the run waits for, named in the recorded issue when no
    ///     answer arrives — "the elicitation 01K…", say.
    ///   - body: The work that finishes only once an answer is delivered to it.
    init(waitingFor label: String, running body: @escaping @Sendable () async throws -> Value) {
        let completion = RunCompletion()
        self.label = label
        self.completion = completion
        self.task = Task {
            let outcome: Result<Value, Error>
            do {
                outcome = .success(try await body())
            } catch {
                outcome = .failure(error)
            }
            await completion.noteFinished()
            return try outcome.get()
        }
    }

    /// The value the run produced once an answer reached it.
    ///
    /// - Returns: Whatever the run returned.
    /// - Throws: ``AnswerNeverDelivered`` when no answer arrived inside the
    ///   bound, after recording an issue naming the run; otherwise whatever the
    ///   run itself threw.
    func deliveredAnswer() async throws -> Value {
        guard await finishesWithinDeliveryBound() else {
            Issue.record(
                """
                no answer ever reached \(label): the run is still running, so the inbound \
                answer route is broken
                """
            )
            // Cancelling cannot resume a run suspended in `withCheckedContinuation`,
            // but the test must not await that run either.
            task.cancel()
            throw AnswerNeverDelivered()
        }
        return try await task.value
    }

    /// Whether the run finished inside the bound, asked repeatedly rather than
    /// awaited so an answer that never arrives ends the wait.
    ///
    /// The bound is ``BoundedWait/spin(until:)``, the one this test target
    /// bounds every otherwise-unbreakable wait with. The question asked here
    /// crosses an actor rather than reading a semaphore, but the wait around it
    /// is the same wait: ask a question that cannot suspend forever, again and
    /// again, until a wall-clock ceiling says no answer is coming.
    private func finishesWithinDeliveryBound() async -> Bool {
        await BoundedWait.spin(until: { await completion.isFinished })
    }
}
