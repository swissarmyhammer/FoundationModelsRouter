import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^zetnz36: a tool call that the host check marks as a no-op never
/// runs, also when no operation of the session is pending. With nothing
/// pending, nothing can arrive, so a round of only no-op calls ends the
/// answer: each no-op call gets ``RoutedSessionActor/noOpToolCallEndReason``
/// as its output, and the answer ends with the last text of the model.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``StagedReasoningModel``. No GPU is in the loop, and no operation
/// of the session is pending.
@Suite("A no-op tool call with nothing pending ends the answer", .timeLimit(.minutes(1)))
struct NoOpToolCallWithNothingPendingTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "NoOpToolCallWithNothingPendingTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "check the fix"

    /// The start of each waiting snippet that the host check of this suite
    /// marks as a no-op.
    private static let waitingPrefix = "return waiting-"

    /// A snippet that computes a value and calls no tool: the host check of
    /// this suite marks it as a no-op too.
    private static let computingCode = "return 6 * 7"

    /// The count of the model calls that each loop a waiting snippet.
    private static let waitingCallCount = 5

    /// The text a model call writes before its no-op call.
    private static let lastText = "VERDICT: PASS"

    /// The host check of this suite: a `runCode` call whose snippet starts
    /// with ``waitingPrefix``, or is ``computingCode``, is a no-op.
    ///
    /// - Parameters:
    ///   - toolName: The name of the called tool.
    ///   - arguments: The arguments of the call.
    /// - Returns: `true` for a no-op call.
    private static func isNoOp(toolName: String, arguments: GeneratedContent) -> Bool {
        guard toolName == CountingRunCodeTool.toolName,
            let code = try? arguments.value(String.self, forProperty: "code")
        else { return false }
        return code.hasPrefix(waitingPrefix) || code == computingCode
    }

    /// The scripts of a model that calls one distinct waiting snippet on each
    /// call: `return waiting-1`, `return waiting-2`, and so on.
    private static var waitingScripts: [RepeatingReasoningScript] {
        (1...waitingCallCount).map { index in
            RepeatingReasoningScript(reasoningLines: [], hold: .noHold, ending: .runCode(waitingPrefix + "\(index)"))
        }
    }

    /// Runs one streamed answer to ``prompt`` over `scripts`, with the
    /// default ``RepetitionDetection``, one ``CountingRunCodeTool`` that
    /// counts into `runs`, and the host check ``isNoOp(toolName:arguments:)``.
    /// The caller ends the fixture.
    ///
    /// - Parameters:
    ///   - scripts: The script of each call, in call order.
    ///   - runs: The count of the runs of `runCode`.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runAnswer(
        scripts: [RepeatingReasoningScript], runs: RunCount = RunCount()
    ) async throws -> (fixture: StagedReasoningSessionFixture, events: [SessionEvent]) {
        try await StagedReasoningSessionFixture.answer(
            to: prompt, scripts: scripts, detection: RepetitionDetection(),
            tools: [CountingRunCodeTool(runs: runs)], isNoOpToolCall: isNoOp(toolName:arguments:),
            tempDirPrefix: tempDirPrefix)
    }

    /// The tool output of `entry`.
    ///
    /// - Parameter entry: A transcript entry.
    /// - Returns: The output, or `nil` for an entry that is not a tool output.
    private static func toolOutput(of entry: Transcript.Entry) -> Transcript.ToolOutput? {
        guard case .toolOutput(let output) = entry else { return nil }
        return output
    }

    /// The text of each segment of `output`, joined.
    ///
    /// - Parameter output: A tool output.
    /// - Returns: The text of the output.
    private static func text(of output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined()
    }

    /// The reply of the one answer of `events`.
    ///
    /// - Parameter events: The events of one answer, in order.
    /// - Returns: The reply text of the answer.
    /// - Throws: When the events hold no answer.
    private static func reply(in events: [SessionEvent]) throws -> String {
        let answer = try #require(events.lazy.compactMap(MailQueueFixtures.answer(of:)).first)
        return answer.reply
    }

    @Test("a model that loops distinct no-op snippets runs none of them")
    func distinctNoOpSnippetsNeverRun() async throws {
        let runs = RunCount()
        let (fixture, _) = try await Self.runAnswer(scripts: Self.waitingScripts, runs: runs)
        defer { await fixture.end() }

        #expect(runs.value == 0)
    }

    @Test("a round of only no-op calls ends the answer after its model call")
    func aRoundOfOnlyNoOpCallsEndsTheAnswer() async throws {
        let (fixture, _) = try await Self.runAnswer(scripts: Self.waitingScripts)
        defer { await fixture.end() }

        #expect(fixture.log.renders.count == 1)
    }

    @Test("a no-op snippet that computes a value gets the reason as its output, and the transcript ends with it")
    func aComputingNoOpCallGetsTheReason() async throws {
        let (fixture, _) = try await Self.runAnswer(
            scripts: [RepeatingReasoningScript(reasoningLines: [], hold: .noHold, ending: .runCode(Self.computingCode))])
        defer { await fixture.end() }

        let last = try #require(await fixture.session.transcript.last)
        let output = try #require(Self.toolOutput(of: last))
        #expect(Self.text(of: output) == RoutedSessionActor.noOpToolCallEndReason)
    }

    @Test("the answer that a round of only no-op calls ends replies with the last text of the model")
    func theAnswerEndsWithTheLastTextOfTheModel() async throws {
        var script = RepeatingReasoningScript(
            reasoningLines: [], hold: .noHold, ending: .runCode(Self.waitingPrefix + "1"))
        script.leadingText = Self.lastText
        let (fixture, events) = try await Self.runAnswer(scripts: [script])
        defer { await fixture.end() }

        #expect(try Self.reply(in: events) == Self.lastText)
    }
}
