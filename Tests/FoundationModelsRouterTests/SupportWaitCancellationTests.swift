import FoundationModelsRouterTestSupport
import Testing

/// Holds the waits of the test support target to rule T1: a cancel of the
/// waiting task ends the wait. ``RecordedWaitResult/wait(for:endingOnEndOf:)``
/// cancels its wait task when the observed task ends first, and a wait that
/// ignored the cancel would stay suspended after the test.
///
/// Each test cancels the waiting task, and then makes the condition hold. A
/// wait that ignores the cancel then returns with no error, and the test
/// fails. A wait that obeys the cancel throws `CancellationError`, also when
/// the condition holds later. The suite needs no session and no model.
@Suite("The waits of the test support target end on a cancel (rule T1)")
struct SupportWaitCancellationTests {
    /// The production change that makes this test fail: a
    /// `ConcurrencyPeakObserver.waitUntil(_:)` with no cancel handler. Its
    /// wait then returns on the entry, and throws nothing.
    @Test("a cancelled wait of a ConcurrencyPeakObserver throws CancellationError")
    func aCancelledObserverWaitThrows() async {
        let observer = ConcurrencyPeakObserver()
        let waiting = Task { try await observer.waitUntil { $0.entered == 1 } }
        defer { waiting.cancel() }

        waiting.cancel()
        await observer.enter()

        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    /// The production change that makes this test fail: a
    /// `PassBoundaryLog.waitUntil(_:)` with no cancel handler. Its wait then
    /// returns on the record, and throws nothing.
    @Test("a cancelled wait of a PassBoundaryLog throws CancellationError")
    func aCancelledLogWaitThrows() async {
        let log = PassBoundaryLog()
        let waiting = Task { try await log.waitUntil { $0.contains(.executorEntered) } }
        defer { waiting.cancel() }

        waiting.cancel()
        log.record(.executorEntered)

        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
