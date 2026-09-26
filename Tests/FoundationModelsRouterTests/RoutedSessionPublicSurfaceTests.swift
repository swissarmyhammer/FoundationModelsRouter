import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds the convenience members of `extension RoutedSession` to the
/// access level their siblings carry (task ^hdabs7j), and the message
/// members they use (task ^cbhpdjy).
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

    /// The text `send(_:)` is given, so an assertion can read the very string
    /// back off the transcript.
    private static let sentPromptText = "sent over the public surface"

    /// Builds a scripted session whose turn answers without calling a tool —
    /// enough machinery for the queue members, and no tool to script.
    ///
    /// - Returns: The vended session and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeQueueFixture() async throws -> ScriptedSessionFixture {
        try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: []), mounting: [], tempDirPrefix: tempDirPrefix)
    }

    /// Reads the text of a prompt back out of its segments.
    ///
    /// - Parameter prompt: A prompt of the session transcript.
    /// - Returns: Every text segment's content, in order, joined by nothing.
    private static func text(of prompt: Transcript.Prompt) -> String {
        prompt.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        .joined()
    }

    // MARK: - compact()

    @Test("compact() runs the compaction pipeline against this session's own working context")
    func compactWithNoArgumentsMeasuresTheLiveTranscript() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let result = try await fixture.session.compact()

        // The default budget is the session's resolved working context, which
        // one scripted turn comes nowhere near: the pipeline measured a real
        // transcript and correctly compacted nothing.
        #expect(result.tokensBefore > 0)
        #expect(result.tokensAfter == result.tokensBefore)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
    }

    // MARK: - compact(budget:)

    @Test("compact(budget:) compacts the transcript against the budget it is given")
    func compactWithBudgetCompactsAgainstThatBudget() async throws {
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tempDirPrefix: Self.tempDirPrefix)

        let result = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)

        // The target of the fixture's budget is less than the warm-up
        // transcript, so the compaction makes the one summarizer call and
        // really shrinks the transcript.
        #expect(result.stagesApplied.contains("Summarization"))
        #expect(result.tokensAfter < result.tokensBefore)
        #expect(result.summary != nil)
    }

    /// Whether the transcript of `session` holds a prompt with `text`, and no
    /// message of it waits or runs, inside ``BoundedWait``'s bound. Only
    /// public members are read.
    ///
    /// - Parameters:
    ///   - session: The session to read.
    ///   - text: The prompt text to find.
    /// - Returns: Whether the session answered the prompt inside the bound.
    private static func answered(_ session: any RoutedSession, prompt text: String) async -> Bool {
        await BoundedWait.conditionReached("the answer to the sent message") {
            let prompts = Array(await session.transcript).compactMap { entry -> String? in
                guard case .prompt(let prompt) = entry else { return nil }
                return Self.text(of: prompt)
            }
            let depth = await session.messageQueueDepth()
            return prompts.contains(text) && depth.total == 0
        }
    }

    // MARK: - send(_ prompt: String)

    // Restates the old `enqueue(prompt:)` test. A sent message starts a
    // submission at once, thus the test reads the prompt back from the
    // transcript, not from the queue.
    @Test("send(_:) sends the plain text it is given as one message")
    func sendTextSendsThatTextAsOneMessage() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let id: MessageID = await fixture.session.send(Self.sentPromptText)

        #expect(await Self.answered(fixture.session, prompt: Self.sentPromptText))
        #expect(await fixture.session.pendingMessages().allSatisfy { $0.id != id })
    }

    // MARK: - cancel(message:)

    // Restates the old `cancelPrompt(id:)` test. A withdrawal needs a busy
    // session; the internal suites prove it (see
    // `SessionMessagePumpTests.cancelOfAWaitingMessageWithdrawsIt`). Over the
    // public surface this test proves the result for an answered message.
    @Test("cancel(message:) of an answered message reports alreadyAnswered and changes nothing")
    func cancelOfAnAnsweredMessageReportsAlreadyAnswered() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = await fixture.session.send(Self.sentPromptText)
        #expect(await Self.answered(fixture.session, prompt: Self.sentPromptText))

        let result: MessageCancellationResult = await fixture.session.cancel(message: id)

        #expect(result == .alreadyAnswered)
        #expect(await fixture.session.pendingMessages().isEmpty)
        #expect(await fixture.session.messageQueueDepth().total == 0)
    }
}
