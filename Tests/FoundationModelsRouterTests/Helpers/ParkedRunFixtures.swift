import Foundation

@testable import FoundationModelsRouter

/// A latch a fixture body suspends on until a test (or cooperative
/// cancellation) opens it — the controllable stand-in for a detached run's
/// real work, whether that body is a fake parked run or a gated tool's
/// `call(arguments:)`.
///
/// This is the one gate the test target declares. Every suite that has to
/// hold a run open — `SessionMailboxTests`, `ToolContextTests`,
/// `DetachingToolTests`, `SessionOutboxToolWiringTests`,
/// `RoutedSessionCompactTests` — uses it, so the scaffolding lives in exactly
/// one place and cannot drift copy from copy.
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

/// Parks a fake run of `kind` on `mailbox`: its settling task suspends on
/// `latch` (opening it on cooperative cancellation), then produces a terminal
/// `.completed` event whose outcome honestly reports whether it was cancelled.
/// The canceler reports `cancelerOutcome`, and what it does before reporting is
/// `kind`'s own cancellation authority:
///
/// - ``RunKind/swiftTask``: cancellation is cooperative, so the canceler
///   cancels the settling task and the body ends on its own schedule.
/// - ``RunKind/process``: `killpg(SIGKILL)` is authoritative and lives in the
///   capability, not in the fixture, so the canceler only reports. The body
///   stands for the run's wait on the killed process group, and it ends when a
///   test opens `latch`.
///
/// - Parameters:
///   - mailbox: The mailbox the run parks on.
///   - latch: The latch the run's body suspends on until a test opens it.
///   - kind: What kind of work the fake run is.
///   - detailOnSettle: The detail the terminal event carries.
///   - cancelerOutcome: The outcome the run's canceler reports.
///   - counter: Counts this run's canceler invocations, when a test supplies
///     one.
/// - Returns: The run's completion token.
func parkFakeRun(
    on mailbox: SessionMailbox,
    latch: RunLatch,
    kind: RunKind = .swiftTask,
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
        kind: kind,
        completionToken: token,
        settling: settling,
        canceler: {
            await counter?.increment()
            switch kind {
            case .swiftTask:
                // Cooperative: the canceler only requests the end.
                settling.cancel()
            case .process:
                // Authoritative, and owned by the capability: the fixture
                // reports the kill and leaves the body to the test's latch.
                break
            }
            return cancelerOutcome
        }
    )
    return token
}
