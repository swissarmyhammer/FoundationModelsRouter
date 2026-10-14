import Testing

import FoundationModelsRouter

/// Holds ``GenerationQueue`` to the access level a consumer outside this
/// package needs (tasks ^8csj2hw and ^1psqdm9): a stub container with no
/// executor seam makes its own queue and submits each scripted call in
/// `submit`, so its queue behavior is testable without MLX. A backend names
/// the queue its session submits to through
/// ``LanguageModelSessionBackend/generationQueue``, and a wait that can never
/// end is refused with ``GenerationQueueError``.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("GenerationQueue surface over a plain import")
struct GenerationQueuePublicSurfaceTests {
    /// Counts the items inside the queue at one time, and keeps the largest
    /// count.
    private actor PassCounter {
        /// The passes inside the queue now.
        private var active = 0

        /// The largest number of passes that were inside at one time.
        private(set) var peak = 0

        /// How many passes entered over the whole run.
        private(set) var entered = 0

        /// Records one pass that enters.
        func enter() {
            active += 1
            entered += 1
            peak = max(peak, active)
        }

        /// Records one pass that leaves.
        func exit() {
            active -= 1
        }
    }

    /// Waits for the first element of `events`. A one-shot event of the test:
    /// the producer yields once, and nothing else ends the wait.
    ///
    /// - Parameter events: The stream of the event.
    private static func firstEvent(of events: AsyncStream<Void>) async {
        for await _ in events {
            return
        }
    }

    /// One scripted pass: it enters, holds its place until `release` sends
    /// its event, leaves, and returns `name`.
    ///
    /// - Parameters:
    ///   - name: The answer of the pass.
    ///   - counter: The counter the pass reports to.
    ///   - entered: Gets one element when the pass entered.
    ///   - release: The event that lets the pass leave.
    /// - Returns: `name`.
    private static func heldPass(
        named name: String, reportingTo counter: PassCounter,
        entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>
    ) async -> String {
        await counter.enter()
        entered.yield()
        await firstEvent(of: release)
        await counter.exit()
        return name
    }

    @Test("two scripted items on one queue never overlap, and each returns its body's value")
    func scriptedPassesOnOneQueueNeverOverlap() async throws {
        let queue = GenerationQueue()
        let counter = PassCounter()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (queued, queuedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()

        // The first item holds the worker until the test sends the release.
        let first = Task {
            try await queue.submit {
                await Self.heldPass(named: "first", reportingTo: counter, entered: enteredSignal, release: release)
            }
        }
        await Self.firstEvent(of: entered)
        // The queue calls `onQueued` when the second item must wait behind
        // the first.
        let second = Task {
            try await queue.submit(onQueued: { queuedSignal.yield() }) {
                await counter.enter()
                await counter.exit()
                return "second"
            }
        }
        await Self.firstEvent(of: queued)
        // The first item still holds the worker, so the second did not enter.
        #expect(await counter.entered == 1)

        releaseSignal.yield()
        let answers = [try await first.value, try await second.value]
        #expect(answers == ["first", "second"])
        #expect(await counter.entered == 2)
        #expect(await counter.peak == 1)
    }

    /// The label a consumer shows for `error`, or `nil` for an error that is
    /// not a refused wait.
    ///
    /// - Parameter error: The error a call threw.
    /// - Returns: The label, which names the model.
    private static func refusalLabel(for error: any Error) -> String? {
        guard case .waitInsideOpenSubmission(let model) = error as? GenerationQueueError else { return nil }
        return "a tool waited inside its submission on \(model.stringValue)"
    }

    @Test("a consumer matches the refusal of a wait inside an open submission, and reads its model")
    func aConsumerMatchesTheRefusedWait() {
        let model: ModelRef = "org/refused"
        let refusal = GenerationQueueError.waitInsideOpenSubmission(model: model)

        #expect(Self.refusalLabel(for: refusal) == "a tool waited inside its submission on org/refused")
        #expect(refusal.errorDescription?.contains(model.stringValue) == true)
    }
}
