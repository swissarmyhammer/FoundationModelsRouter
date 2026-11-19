import Observation
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Task ^szyxq9z: the read of the transcript updates of the live backend
/// sees each change, also a change that comes while the read installs its
/// observation.
///
/// `withObservationTracking` records what its body reads, and installs the
/// observation only after the body returned. A write that another task makes
/// between the read and the install has no observer, so it sends no wake.
/// When that write is the last write of a pass, the reader never reads it:
/// the repetition watch then never sees the last reasoning line, and never
/// stops a pass that waits for the stop. A full `swift test` run hung that
/// way. Each test here makes the write in that window in a fixed order: the
/// body of the read makes the write itself, after its read.
@Suite("A tracked read of the transcript sees a change that comes before its observation")
struct TranscriptChangeWakeTests {
    /// An observed state with one counter, as the SDK session is an
    /// observed object with one transcript.
    @Observable
    final class ObservedCounter {
        /// The observed value.
        var value = 0
    }

    /// Counts the wakes that a tracked read sends.
    private final class WakeCount: Sendable {
        /// The count, under a lock: the observation can wake from any task.
        private let count = Mutex(0)

        /// The wakes so far.
        var wakes: Int { count.withLock { $0 } }

        /// Counts one wake.
        func wake() {
            count.withLock { $0 += 1 }
        }
    }

    @Test("a write between the read and the install of the observation wakes the reader")
    func aWriteBeforeTheInstallWakes() {
        let counter = ObservedCounter()
        let wakes = WakeCount()
        var reads = 0

        _ = MLXFoundationModelsSessionBackend.readTrackingChanges(
            of: {
                let read = counter.value
                reads += 1
                if reads == 1 {
                    counter.value += 1
                }
                return read
            },
            onChange: wakes.wake)

        #expect(wakes.wakes == 1)
    }

    @Test("a read with no write sends no wake")
    func aReadWithNoWriteDoesNotWake() {
        let counter = ObservedCounter()
        let wakes = WakeCount()

        _ = MLXFoundationModelsSessionBackend.readTrackingChanges(of: { counter.value }, onChange: wakes.wake)

        #expect(wakes.wakes == 0)
    }

    @Test("a write after the read wakes the reader one time")
    func aWriteAfterTheReadWakesOnce() {
        let counter = ObservedCounter()
        let wakes = WakeCount()

        _ = MLXFoundationModelsSessionBackend.readTrackingChanges(of: { counter.value }, onChange: wakes.wake)
        counter.value += 1
        counter.value += 1

        #expect(wakes.wakes == 1)
    }
}
