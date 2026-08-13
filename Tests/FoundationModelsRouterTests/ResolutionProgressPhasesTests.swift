import Testing

@testable import FoundationModelsRouter

/// Exercises task ^pe7mg0v: ``ResolutionProgress/phases`` — the resolution
/// progress as an `AsyncSequence`, so a CLI caller writes a `for await` loop
/// instead of a polling task.
///
/// The contract under test: the sequence first yields the current phase, then
/// yields each observed phase transition exactly once, and finishes when the
/// phase reaches ``ResolutionProgress/Phase/ready`` or
/// ``ResolutionProgress/Phase/failed(_:)``. Every wait here goes through
/// ``BoundedWait``, so a broken stream fails the test instead of hanging the
/// suite.
@Suite("ResolutionProgress.phases: progress as an AsyncSequence")
struct ResolutionProgressPhasesTests {
    /// Collects what one consumer task saw: the yielded transitions, and
    /// whether the sequence finished.
    ///
    /// `@MainActor` so the consumer task's appends and the test's reads are
    /// serialized on one actor.
    @MainActor
    private final class TransitionLog {
        /// The transitions the consumer received, in arrival order.
        private(set) var transitions: [(phase: ResolutionProgress.Phase, fraction: Double)] = []

        /// Whether the `for await` loop ended.
        private(set) var finished = false

        /// Records one received transition.
        func record(_ transition: (phase: ResolutionProgress.Phase, fraction: Double)) {
            transitions.append(transition)
        }

        /// Records that the sequence finished.
        func markFinished() {
            finished = true
        }
    }

    /// Starts a consumer task that drains `progress.phases` into a fresh log.
    @MainActor
    private func startConsumer(of progress: ResolutionProgress) -> TransitionLog {
        let log = TransitionLog()
        Task { @MainActor in
            for await transition in progress.phases {
                log.record(transition)
            }
            log.markFinished()
        }
        return log
    }

    @Test("yields the current phase, then each transition once, and finishes at .ready")
    @MainActor
    func yieldsEachTransitionOnceAndFinishesAtReady() async {
        let progress = ResolutionProgress()
        let log = startConsumer(of: progress)

        guard
            await BoundedWait.conditionReached(
                "the initial sizing transition", when: { await log.transitions.count == 1 })
        else { return }

        progress.phase = .downloading
        guard
            await BoundedWait.conditionReached(
                "the downloading transition", when: { await log.transitions.count == 2 })
        else { return }

        // A write of the same phase again is not a transition, so it must
        // yield nothing: the next element the consumer sees is .loading.
        progress.phase = .downloading
        progress.phase = .loading
        guard
            await BoundedWait.conditionReached(
                "the loading transition", when: { await log.transitions.count == 3 })
        else { return }

        progress.fraction = 1.0
        progress.phase = .ready
        guard
            await BoundedWait.conditionReached(
                "the finished sequence", when: { await log.finished })
        else { return }

        #expect(log.transitions.map(\.phase) == [.sizing, .downloading, .loading, .ready])
        #expect(log.transitions.first?.fraction == 0)
        #expect(log.transitions.last?.fraction == 1.0)
    }

    @Test("finishes at .failed, with the failure as the last element")
    @MainActor
    func finishesAtFailed() async {
        let progress = ResolutionProgress()
        let log = startConsumer(of: progress)

        guard
            await BoundedWait.conditionReached(
                "the initial sizing transition", when: { await log.transitions.count == 1 })
        else { return }

        progress.phase = .failed("no candidate fit the budget")
        guard
            await BoundedWait.conditionReached(
                "the finished sequence", when: { await log.finished })
        else { return }

        #expect(
            log.transitions.map(\.phase) == [.sizing, .failed("no candidate fit the budget")])
    }

    @Test("a subscriber that arrives after .ready gets one terminal element")
    @MainActor
    func lateSubscriberGetsTheTerminalPhaseOnly() async {
        let progress = ResolutionProgress()
        progress.fraction = 1.0
        progress.phase = .ready

        let log = startConsumer(of: progress)
        guard
            await BoundedWait.conditionReached(
                "the finished sequence", when: { await log.finished })
        else { return }

        #expect(log.transitions.map(\.phase) == [.ready])
        #expect(log.transitions.first?.fraction == 1.0)
    }
}
