import Testing

@testable import FoundationModelsRouter

@Suite("BoundedWait ends every wait on a wall clock, never on a count of scheduler hops")
struct BoundedWaitTests {
    /// How long the late signal below makes its waiter wait.
    ///
    /// Longer than any run of scheduler hops a test orders a state change
    /// behind, and shorter than the bound's own ceiling. A wait that counts
    /// hops gives up inside this span on a loaded machine; a wait that reads a
    /// clock does not.
    static let lateSignalDelayNanoseconds: UInt64 = 400_000_000

    @Test("a signal that arrives late in wall-clock terms is still observed")
    func aLateSignalIsStillObserved() async throws {
        let signal = AsyncSemaphore(value: 0)
        let signaller = Task {
            try await Task.sleep(nanoseconds: Self.lateSignalDelayNanoseconds)
            signal.signal()
        }
        defer { signaller.cancel() }

        #expect(await BoundedWait.signalArrived(signal, named: "the late signal"))
    }

    @Test("a condition that never holds ends the wait, and never before a late change would have landed")
    func aConditionThatNeverHoldsEndsTheWaitAndNamesItself() async {
        let label = "the state change nothing ever makes"
        let started = ContinuousClock.now

        await withKnownIssue {
            #expect(await BoundedWait.conditionReached(label, when: { false }) == false)
        } matching: { issue in
            issue.comments.contains { $0.description.contains(label) }
        }

        #expect(started.duration(to: .now) >= .nanoseconds(Self.lateSignalDelayNanoseconds))
    }
}
