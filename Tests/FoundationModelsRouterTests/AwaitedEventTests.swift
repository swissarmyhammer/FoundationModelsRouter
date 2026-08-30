import Testing

@testable import FoundationModelsRouter

/// Holds ``AwaitedEvent`` to the three properties every wait built on it rests
/// on: a signal already sent is still observed, a signal sent while a waiter is
/// suspended resumes it, and a cancelled wait ends rather than suspending on an
/// event nothing will send.
///
/// The third is what lets a `.timeLimit` trait end a test whose event never
/// arrives. ``AsyncSemaphore/wait()`` cannot be ended that way by design, which
/// is why the waits a test makes go through this type instead.
///
/// `.timeLimit` here for the same reason: a regression in the type under test
/// would otherwise suspend one of these tests forever and hang the whole run.
@Suite("AwaitedEvent ends a wait on the event itself, never on a clock", .timeLimit(.minutes(1)))
struct AwaitedEventTests {
    @Test("a signal sent before the wait is still observed")
    func anEarlierSignalIsStillObserved() async {
        let event = AwaitedEvent()
        event.signal()

        await #expect(throws: Never.self) { try await event.wait() }
    }

    @Test("a signal sent while a waiter is suspended resumes it")
    func aLaterSignalResumesTheWaiter() async throws {
        let event = AwaitedEvent()
        let waiterFinished = AwaitedEvent()
        let waiter = Task {
            try await event.wait()
            waiterFinished.signal()
        }

        event.signal()

        try await waiterFinished.wait()
        await #expect(throws: Never.self) { try await waiter.value }
    }

    @Test("a wait its own task cancels ends, rather than suspending on an event nothing will send")
    func aCancelledWaitEnds() async throws {
        let event = AwaitedEvent()
        let waiting = AwaitedEvent()
        let waiter = Task {
            waiting.signal()
            try await event.wait()
        }

        try await waiting.wait()
        waiter.cancel()

        await #expect(throws: EventNeverArrived.self) { try await waiter.value }
    }
}
