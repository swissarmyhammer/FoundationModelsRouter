import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds ``SubmissionBoundaryTool`` to the public surface (task ^f33q8gw).
///
/// This file imports the module plainly. There is no `@testable`, thus the
/// compiler itself is the first assertion: when the protocol or its
/// requirement loses `public`, this file does not compile. A consumer (for
/// example the MultiTool of FoundationModelsMultitool) conforms from another
/// package, where `@testable` is not available.
///
/// The tool below is mounted the way a host mounts it. The session puts each
/// mounted tool under its decorators, so the hook call must go through the
/// decorator chain to reach the tool.
@Suite("SubmissionBoundaryTool over the public surface")
struct SubmissionBoundaryToolPublicSurfaceTests {
    /// The temp-directory prefix every fixture in this suite is built with, so
    /// a leaked directory is attributable to this suite.
    private static let tempDirPrefix = "SubmissionBoundaryToolPublicSurfaceTests"

    /// How many answers the mounting test asks for. Each answer here is one
    /// submission, because the scripted model answers at once.
    private static let answerCount = 2

    /// The model-facing name of the counting tool.
    private static let probeName = "public-submission-boundary-probe"

    /// Counts the hook calls of one tool.
    private actor HookCounter {
        /// How many times the hook was called.
        private(set) var count = 0

        /// Adds one hook call.
        func increment() {
            count += 1
        }
    }

    /// A tool that conforms to ``SubmissionBoundaryTool`` from outside the
    /// module, and counts each ``SubmissionBoundaryTool/submissionWillBegin()``
    /// call.
    private struct CountingBoundaryTool: SubmissionBoundaryTool {
        let name = SubmissionBoundaryToolPublicSurfaceTests.probeName
        let description = "test-only tool that counts each submissionWillBegin() call"

        /// The counter the test reads.
        let counter: HookCounter

        func submissionWillBegin() async {
            await counter.increment()
        }

        func call(arguments: AmbientToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }
    }

    @Test("a tool from outside the module that conforms gets one call before each submission of the session that mounts it")
    func aMountedPublicConformerGetsOneCallForEachSubmission() async throws {
        let counter = HookCounter()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: []),
            mounting: [CountingBoundaryTool(counter: counter)],
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for _ in 0..<Self.answerCount {
            _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        }

        #expect(await counter.count == Self.answerCount)
    }
}
