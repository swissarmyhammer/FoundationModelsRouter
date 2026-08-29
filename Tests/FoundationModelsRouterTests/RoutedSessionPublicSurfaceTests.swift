import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds the four convenience members of `extension RoutedSession` to the
/// access level their siblings carry (task ^hdabs7j).
///
/// This file imports the module plainly. There is no `@testable`, thus the
/// compiler itself is the first assertion: a member that loses `public` stops
/// this file from compiling, whatever the test bodies do. Each body then drives
/// its member against the scripted fixtures, so the suite proves behavior as
/// well as reach.
@Suite("RoutedSession convenience members over the public surface")
struct RoutedSessionPublicSurfaceTests {
    /// The temp-directory prefix every fixture in this suite is built with, so
    /// a leaked directory is attributable to this suite.
    private static let tempDirPrefix = "RoutedSessionPublicSurfaceTests"

    /// The text `enqueue(prompt:)` is given, so an assertion can read the very
    /// string back off the queue.
    private static let queuedPromptText = "queued over the public surface"

    /// The one prompt the queue holds after a single `enqueue(prompt:)`.
    private static let singleQueuedPrompt = 1

    /// The empty queue a withdrawn prompt leaves behind.
    private static let emptyQueue = 0

    /// Builds a scripted session whose turn answers without calling a tool —
    /// enough machinery for the queue members, and no tool to script.
    ///
    /// - Returns: The vended session and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeQueueFixture() async throws -> ScriptedSessionFixture {
        try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: []), mounting: [], tempDirPrefix: tempDirPrefix)
    }

    /// Reads the text of a queued prompt back out of its segments.
    ///
    /// - Parameter prompt: The queued prompt ``RoutedSession/pendingPrompts()`` vended.
    /// - Returns: Every text segment's content, in order, joined by nothing.
    private static func text(of prompt: Transcript.Prompt) -> String {
        prompt.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        .joined()
    }

    // MARK: - compact()

    @Test("compact() runs the fold pipeline against this session's own working context")
    func compactWithNoArgumentsMeasuresTheLiveTranscript() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let result = try await fixture.session.compact()

        // The default budget is the session's resolved working context, which
        // one scripted turn comes nowhere near: the pipeline measured a real
        // transcript and correctly folded nothing.
        #expect(result.tokensBefore > 0)
        #expect(result.tokensAfter == result.tokensBefore)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
    }

    // MARK: - compact(budget:)

    @Test("compact(budget:) folds the transcript against the budget it is given")
    func compactWithBudgetFoldsAgainstThatBudget() async throws {
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tempDirPrefix: Self.tempDirPrefix)

        let result = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)

        // The fixture's budget targets less than the recency window alone
        // holds, so the fold cannot land on the deterministic stages: it runs
        // the model-assisted stage and really shrinks the transcript.
        #expect(result.stagesApplied.contains("Summarization"))
        #expect(result.tokensAfter < result.tokensBefore)
        #expect(result.summary != nil)
    }

    // MARK: - enqueue(prompt: String)

    @Test("enqueue(prompt:) stages the plain text it is given as one queued prompt")
    func enqueueTextStagesThatTextForAFutureTurn() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let id = await fixture.session.enqueue(prompt: Self.queuedPromptText)

        let pending = await fixture.session.pendingPrompts()
        #expect(pending.map(\.id) == [id])
        #expect(pending.map { Self.text(of: $0.prompt) } == [Self.queuedPromptText])
        #expect(await fixture.session.promptQueueDepth().queued == Self.singleQueuedPrompt)
    }

    // MARK: - cancelPrompt(id:)

    @Test("cancelPrompt(id:) withdraws a prompt that is still queued")
    func cancelPromptWithdrawsAStillQueuedPrompt() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = await fixture.session.enqueue(prompt: Self.queuedPromptText)

        let result: PromptCancellationResult = await fixture.session.cancelPrompt(id: id)

        #expect(result == .withdrawn)
        #expect(await fixture.session.pendingPrompts().isEmpty)
        #expect(await fixture.session.promptQueueDepth().queued == Self.emptyQueue)
    }
}
