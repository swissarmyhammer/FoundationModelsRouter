import Foundation

@testable import FoundationModelsRouter

/// A latch a fake run body suspends on until a test (or cooperative
/// cancellation) opens it — the controllable stand-in for a detached run's
/// real work.
///
/// Shared by the run-plane suites (`SessionMailboxTests`, `ToolContextTests`)
/// so the scaffolding lives in exactly one place.
actor RunLatch {
    /// Whether the latch has been opened.
    private var isOpen = false

    /// The bodies suspended until the latch opens.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Opens the latch, resuming every suspended body. Opening an already
    /// open latch is a no-op.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        let parked = waiters
        waiters = []
        for waiter in parked {
            waiter.resume()
        }
    }

    /// Suspends until the latch opens, or returns at once when it already is.
    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Counts canceler invocations so a test can assert a sweep invoked each
/// parked run's canceler exactly once.
actor CancelCounter {
    /// How many cancelers have reported in.
    private(set) var count = 0

    /// Records one canceler invocation.
    func increment() {
        count += 1
    }
}

/// The identity every fake parked run is stamped with, so a suite can assert
/// the stamps it reads back off the run plane.
enum FakeRun {
    /// The fused tool's name every fake run carries.
    static let tool = "fake"

    /// The canonical `"verb noun"` op string every fake run carries.
    static let op = "run task"
}

/// Parks a fake swift-task run on `mailbox`: its settling task suspends on
/// `latch` (opening it on cooperative cancellation), then produces a terminal
/// `.completed` event whose outcome honestly reports whether it was cancelled.
/// The canceler cancels the settling task and reports `cancelerOutcome`.
///
/// - Parameters:
///   - mailbox: The mailbox the run parks on.
///   - latch: The latch the run's body suspends on until a test opens it.
///   - detailOnSettle: The detail the terminal event carries.
///   - cancelerOutcome: The outcome the run's canceler reports.
///   - counter: Counts this run's canceler invocations, when a test supplies
///     one.
/// - Returns: The run's completion token.
func parkFakeRun(
    on mailbox: SessionMailbox,
    latch: RunLatch,
    detailOnSettle: String = "done",
    cancelerOutcome: OperationOutcome = .cancelled,
    counter: CancelCounter? = nil
) async -> String {
    let token = SessionMailbox.makeCompletionToken()
    let settling = Task<OperationEvent, Never> {
        await withTaskCancellationHandler {
            await latch.waitUntilOpen()
        } onCancel: {
            Task { await latch.open() }
        }
        return OperationEvent(
            tool: FakeRun.tool,
            op: FakeRun.op,
            correlationID: token,
            kind: .completed,
            detail: detailOnSettle,
            outcome: Task.isCancelled ? .cancelled : .succeeded
        )
    }
    await mailbox.park(
        tool: FakeRun.tool,
        op: FakeRun.op,
        kind: .swiftTask,
        completionToken: token,
        settling: settling,
        canceler: {
            await counter?.increment()
            settling.cancel()
            return cancelerOutcome
        }
    )
    return token
}
