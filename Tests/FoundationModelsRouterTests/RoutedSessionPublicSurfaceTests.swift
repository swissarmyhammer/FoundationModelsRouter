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

    /// Builds a scripted session whose answer comes without a tool call —
    /// enough machinery for the queue members, and no tool to script.
    ///
    /// - Returns: The vended session and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeQueueFixture() async throws -> ScriptedSessionFixture {
        try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: []), mounting: [], tempDirPrefix: tempDirPrefix)
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

        let result = try await fixture.session.compactAndAwait()

        // The default budget is the session's resolved working context, which
        // one scripted answer comes nowhere near: the pipeline measured a real
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

        let result = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)

        // The target of the fixture's budget is less than the warm-up
        // transcript, so the compaction makes the one summarizer call and
        // really shrinks the transcript.
        #expect(result.stagesApplied.contains("Summarization"))
        #expect(result.tokensAfter < result.tokensBefore)
        #expect(result.summary != nil)
    }

    /// Waits for the answer to the mail `id`, then tells whether the
    /// transcript of `session` holds a prompt with `text`, and no message of
    /// it waits or runs. Only public members are read.
    ///
    /// The answer is the terminal event of the mail. The session records the
    /// prompt before the answer ends, and the mail left the queue when its
    /// answer started. Thus one read after the answer is enough.
    ///
    /// - Parameters:
    ///   - id: The id of the sent mail.
    ///   - session: The session to read.
    ///   - text: The prompt text to find.
    /// - Returns: Whether the session answered the prompt.
    /// - Throws: What ``RoutedSession/awaitAnswer(of:)`` throws.
    private static func answered(
        _ id: MailID, on session: any RoutedSession, prompt text: String
    ) async throws -> Bool {
        _ = try await session.awaitAnswer(of: id)
        let prompts = Array(await session.transcript).compactMap { entry -> String? in
            guard case .prompt(let prompt) = entry else { return nil }
            return Self.text(of: prompt)
        }
        let depth = await session.mailQueueDepth()
        return prompts.contains(text) && depth.total == 0
    }

    // MARK: - send(_ prompt: String)

    // Restates the old `enqueue(prompt:)` test. A sent message starts a
    // submission at once, thus the test reads the prompt back from the
    // transcript, not from the queue.
    @Test("send(_:) sends the plain text it is given as one message")
    func sendTextSendsThatTextAsOneMessage() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let id: MailID = try fixture.session.send(Self.sentPromptText)

        #expect(try await Self.answered(id, on: fixture.session, prompt: Self.sentPromptText))
        #expect(await fixture.session.pendingMessages().allSatisfy { $0.id != id })
    }

    // MARK: - cancel(_:)

    // Restates the old `cancelPrompt(id:)` test. A cancel that removes a mail
    // needs a busy session; the internal suites prove it (see
    // `SessionMailQueueTests.cancelMessageWithdrawsAWaitingMessage`). Over the
    // public surface this test proves the result for an answered message:
    // each signal returns its id at once, ends with its own terminal event,
    // and changes nothing.
    @Test(
        "cancel(_:), replace(_:with:) and cancelAll() after an answered message each return a SignalID, end with signalDone, and change nothing"
    )
    func cancelOfAnAnsweredMessageReportsAlreadyAnswered() async throws {
        let fixture = try await Self.makeQueueFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let feed = await fixture.session.streamSessionEvents()
        let id = try fixture.session.send(Self.sentPromptText)
        #expect(try await Self.answered(id, on: fixture.session, prompt: Self.sentPromptText))

        let cancelSignal: SignalID = fixture.session.cancel(id)
        let replaceSignal: SignalID = fixture.session.replace(
            id, with: .userMessage(prompt: "edited", options: UserMessageOptions()))
        let stopSignal: SignalID = fixture.session.cancelAll()

        for signal in [cancelSignal, replaceSignal, stopSignal] {
            #expect(try await fixture.session.awaitTerminal(of: signal) == .signalDone(signal))
        }
        #expect(await fixture.session.pendingMessages().isEmpty)
        #expect(await fixture.session.mailQueueDepth().total == 0)
        await fixture.session.close()

        // The answer stays the one terminal event of the mail: no signal
        // sent a cancelled.
        var outputs: [SessionOutput] = []
        for await output in feed {
            outputs.append(output)
        }
        let ledger = TerminalEventLedger(outputs: outputs)
        ledger.expectExactlyOneTerminal(for: [id])
        #expect(ledger.endedMailIds.count == 1)
        ledger.expectExactlyOneTerminal(forSignals: [cancelSignal, replaceSignal, stopSignal])
    }
}
