import Testing

import FoundationModelsRouter

/// Holds ``GenerationQueue`` to the access level a consumer outside this
/// package needs (task ^8csj2hw): a stub container with no executor seam
/// makes its own queue and runs each scripted pass in `runPass`, so its queue
/// behavior is testable without MLX.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("GenerationQueue surface over a plain import")
struct GenerationQueuePublicSurfaceTests {
    /// Counts the passes inside the queue at one time, and keeps the largest
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

    /// How many times each pass yields while it holds the place, so a pass
    /// that did not wait would enter while the other is inside.
    private static let yieldsInsideThePass = 1_000

    /// One scripted pass: it enters, yields while it holds the place, leaves,
    /// and returns `name`.
    ///
    /// - Parameters:
    ///   - name: The answer of the pass.
    ///   - counter: The counter the pass reports to.
    /// - Returns: `name`.
    private static func scriptedPass(named name: String, reportingTo counter: PassCounter) async -> String {
        await counter.enter()
        for _ in 0..<yieldsInsideThePass {
            await Task.yield()
        }
        await counter.exit()
        return name
    }

    @Test("two scripted passes on one queue never overlap, and each returns its body's value")
    func scriptedPassesOnOneQueueNeverOverlap() async throws {
        let queue = GenerationQueue()
        let counter = PassCounter()

        async let first = queue.runPass { await Self.scriptedPass(named: "first", reportingTo: counter) }
        async let second = queue.runPass { await Self.scriptedPass(named: "second", reportingTo: counter) }

        let answers = try await [first, second]
        #expect(answers == ["first", "second"])
        #expect(await counter.entered == 2)
        #expect(await counter.peak == 1)
    }
}
