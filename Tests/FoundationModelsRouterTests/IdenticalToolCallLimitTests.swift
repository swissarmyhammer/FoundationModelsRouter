import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^8eq31j0: a loop of identical consecutive tool calls stops at
/// ``RepetitionDetection/identicalToolCallLimit``, the recovery prompt names
/// the repeated tool and its count, and the final pass can act with a tool
/// call.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over an ``IdenticalToolCallModel``. No GPU is in the loop.
@Suite("Identical consecutive tool calls stop at the limit, and the final pass can act")
struct IdenticalToolCallLimitTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "IdenticalToolCallLimitTests"

    /// The prompt of every answer of this suite.
    private static let prompt = "fix the related field"

    /// The code of the call that the model repeats.
    private static let repeatedCode = "read(related, offset: 1047, limit: 8)"

    /// The code of a different call.
    private static let otherCode = "read(related, offset: 1044, limit: 8)"

    /// The code of the call that makes the change in the final pass.
    private static let changeCode = "edit(related, line: 1050)"

    /// Runs one streamed answer over a fresh fixture.
    ///
    /// - Parameters:
    ///   - script: The tool calls the model makes.
    ///   - detection: The repetition detection of the session.
    /// - Returns: The fixture and the events of the answer, in order.
    private static func runAnswer(
        script: IdenticalToolCallScript, detection: RepetitionDetection = RepetitionDetection()
    ) async throws -> (fixture: RepeatingToolCallSessionFixture, events: [SessionEvent]) {
        let log = RenderProbeLog()
        let fixture = try await RepeatingToolCallSessionFixture.make(
            model: IdenticalToolCallModel(log: log, script: script), log: log, detection: detection,
            tempDirPrefix: tempDirPrefix)
        let events = try await collect(fixture.session.streamEvents(to: prompt))
        return (fixture, events)
    }

    @Test("the third identical consecutive call stops before its body runs, and the recovery prompt names it")
    func thirdIdenticalCallStopsBeforeItsBodyRuns() async throws {
        let codes = Array(repeating: Self.repeatedCode, count: RepetitionDetection.defaultIdenticalToolCallLimit + 1)
        let (fixture, events) = try await Self.runAnswer(script: IdenticalToolCallScript(codes: codes, finalPassCode: nil))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stop = try #require(events.repetitionStops.first)
        #expect(events.repetitionStops.count == 1)
        #expect(
            stop.repeatedToolCall
                == RepeatedToolCall(
                    toolName: CountingRunCodeTool.toolName, count: RepetitionDetection.defaultIdenticalToolCallLimit))
        #expect(stop.stoppedByIdenticalToolCalls)
        #expect(stop.recovery == 1)
        #expect(fixture.runs.value == RepetitionDetection.defaultIdenticalToolCallLimit - 1)
        #expect(events.submissionEnds.map(\.finishReason) == [.repeatedLines, .completed])
        #expect(events.answers.first?.reply == IdenticalToolCallModel.Executor.answerText)

        let recoveryPrompt = try #require(fixture.log.renders.last?.promptTexts.last)
        #expect(recoveryPrompt.contains("`\(CountingRunCodeTool.toolName)`"))
        #expect(recoveryPrompt.contains("\(RepetitionDetection.defaultIdenticalToolCallLimit) times"))
    }

    @Test("a different call between identical calls starts the count again")
    func differentCallBetweenStartsTheCountAgain() async throws {
        let codes = [Self.repeatedCode, Self.repeatedCode, Self.otherCode, Self.repeatedCode, Self.repeatedCode]
        let (fixture, events) = try await Self.runAnswer(script: IdenticalToolCallScript(codes: codes, finalPassCode: nil))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.repetitionStops.isEmpty)
        #expect(fixture.runs.value == codes.count)
        #expect(events.submissionEnds.map(\.finishReason) == [.completed])
    }

    @Test("a limit of nil or zero sets no limit", arguments: [nil, 0] as [Int?])
    func absentLimitDoesNotStop(limit: Int?) async throws {
        let codes = Array(repeating: Self.repeatedCode, count: RepetitionDetection.defaultIdenticalToolCallLimit + 1)
        let (fixture, events) = try await Self.runAnswer(
            script: IdenticalToolCallScript(codes: codes, finalPassCode: nil),
            detection: RepetitionDetection(identicalToolCallLimit: limit))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(events.repetitionStops.isEmpty)
        #expect(fixture.runs.value == codes.count)
    }

    @Test("a final pass makes a tool call, the tool runs, and the answer ends with the text of the model")
    func finalPassActsWithToolCall() async throws {
        let codes = Array(repeating: Self.repeatedCode, count: RepetitionDetection.defaultIdenticalToolCallLimit)
        let (fixture, events) = try await Self.runAnswer(
            script: IdenticalToolCallScript(codes: codes, finalPassCode: Self.changeCode),
            detection: RepetitionDetection(recoveriesPerAnswer: 0))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stop = try #require(events.repetitionStops.first)
        #expect(events.repetitionStops.count == 1)
        #expect(stop.recovery == nil)
        #expect(fixture.runs.value == codes.count)
        #expect(events.submissionEnds.map(\.finishReason) == [.repeatedLines, .completed])
        #expect(events.answers.first?.reply == IdenticalToolCallModel.Executor.answerText)
        #expect(fixture.log.renders.last?.promptTexts.last?.hasSuffix(RoutedSessionActor.finalPassPrompt) == true)
    }
}

/// The stored form and the prompts of the identical tool call limit
/// (task ^8eq31j0).
@Suite("The identical tool call limit has a named default, a stored form and prompts that name the call")
struct IdenticalToolCallLimitSettingTests {
    /// The key of the limit in the stored form.
    private static let key = "identicalToolCallLimit"

    /// A repeated call of the `files` tool.
    private static let repeatedCall = RepeatedToolCall(toolName: "files", count: 3)

    @Test("the default is 3 calls")
    func defaultIsTheOwnerValue() {
        #expect(RepetitionDetection.defaultIdenticalToolCallLimit == 3)
        #expect(RepetitionDetection().identicalToolCallLimit == RepetitionDetection.defaultIdenticalToolCallLimit)
    }

    @Test("a stored form with no key decodes with the default")
    func absentKeyDecodesWithTheDefault() throws {
        let stored = try JSONEncoder().encode(RepetitionDetection(identicalToolCallLimit: nil))
        var object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object.keys.contains(Self.key))
        object.removeValue(forKey: Self.key)

        let decoded = try JSONDecoder().decode(
            RepetitionDetection.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.identicalToolCallLimit == RepetitionDetection.defaultIdenticalToolCallLimit)
    }

    @Test("a stored limit decodes as it was stored", arguments: [nil, 0, 5] as [Int?])
    func storedLimitRoundTrips(limit: Int?) throws {
        let detection = RepetitionDetection(identicalToolCallLimit: limit)

        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: JSONEncoder().encode(detection))

        #expect(decoded == detection)
    }

    @Test("the logged values name the limit")
    func loggedValuesNameTheLimit() {
        #expect(RepetitionDetection().loggedValues.contains("\(Self.key) = 3"))
        #expect(RepetitionDetection(identicalToolCallLimit: nil).loggedValues.contains("\(Self.key) = none"))
    }

    @Test("a journal row from before the repeated tool call decodes with no repeated tool call")
    func oldWatchStopRowDecodes() throws {
        let row = WatchStop(
            kind: .repetition, tokens: 2_078, limit: 2_048, passFinishReason: .repeatedLines, recovery: 1,
            recoveriesAllowed: 2)
        let stored = try JSONEncoder().encode(row)
        let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(!object.keys.contains("repeatedToolCall"))

        let decoded = try JSONDecoder().decode(WatchStop.self, from: stored)

        #expect(decoded == row)
        #expect(decoded.repeatedToolCall == nil)
    }

    @Test("a journal row with a repeated tool call decodes as it was stored, and its line names the call")
    func watchStopWithRepeatedToolCallRoundTrips() throws {
        let row = WatchStop(
            kind: .repetition, tokens: 0, limit: 2_048, passFinishReason: .repeatedLines, recovery: 1,
            recoveriesAllowed: 2, repeatedToolCall: Self.repeatedCall)

        let decoded = try JSONDecoder().decode(WatchStop.self, from: JSONEncoder().encode(row))

        #expect(decoded == row)
        #expect(row.description.contains("repetition.toolCall=files repetition.toolCallCount=3"))
    }

    @Test("the recovery prompt of a stop on a repeated tool call names the tool and the count")
    func recoveryPromptNamesTheCall() {
        let stop = RepetitionStop(
            generatedTokens: 0, countedLines: 0, newLines: 0, tokensWithoutNewLine: 0,
            detection: RepetitionDetection(), recovery: 1, repeatedToolCall: Self.repeatedCall)

        let prompt = WatchStopReport.repetition(stop).continuationPrompt

        #expect(prompt.contains("You called `files` with the same arguments 3 times in a row."))
        #expect(prompt.contains("Do not call it again with these arguments."))
        #expect(prompt != RoutedSessionActor.repetitionStopContinuationPrompt)
    }

    @Test("the recovery prompt of a stop with no repeated tool call does not change")
    func recoveryPromptWithoutCallIsTheGeneralPrompt() {
        let stop = RepetitionStop(
            generatedTokens: 0, countedLines: 0, newLines: 0, tokensWithoutNewLine: 0,
            detection: RepetitionDetection(), recovery: 1)

        #expect(WatchStopReport.repetition(stop).continuationPrompt == RoutedSessionActor.repetitionStopContinuationPrompt)
    }

    @Test("the final pass prompt lets the model make the change with one tool call")
    func finalPassPromptAllowsOneToolCall() {
        #expect(RoutedSessionActor.finalPassPrompt.contains("make it now with one tool call"))
    }
}

/// The run of identical consecutive tool calls of one answer (task ^8eq31j0).
@Suite("The run of identical consecutive tool calls counts each call")
struct IdenticalToolCallRunTests {
    /// One call.
    private static let first = ToolCallIdentity(toolName: "files", argumentsJSON: #"{"path": "a.py"}"#)

    /// The same tool with other arguments.
    private static let second = ToolCallIdentity(toolName: "files", argumentsJSON: #"{"path": "b.py"}"#)

    @Test("identical calls add to the count, and the run names the repeated call")
    func identicalCallsCount() {
        var run = IdenticalToolCallRun()
        run.add(Self.first)
        #expect(run.repeatedToolCall == nil)
        run.add(Self.first)
        run.add(Self.first)

        #expect(run.count == 3)
        #expect(run.repeatedToolCall == RepeatedToolCall(toolName: "files", count: 3))
    }

    @Test("a call with other arguments starts the count again")
    func otherArgumentsStartAgain() {
        var run = IdenticalToolCallRun()
        run.add(Self.first)
        run.add(Self.first)
        run.add(Self.second)

        #expect(run.count == 1)
        #expect(run.repeatedToolCall == nil)
    }

    @Test("a call that cannot be compared ends the run")
    func unknownCallEndsTheRun() {
        var run = IdenticalToolCallRun()
        run.add(Self.first)
        run.add(Self.first)
        run.add(nil)

        #expect(run.count == 0)
        #expect(run.repeatedToolCall == nil)
    }

    @Test("the identity of generable arguments is their JSON text")
    func generableArgumentsGiveTheirJSON() throws {
        let identity = try #require(
            ToolCallIdentity(toolName: CountingRunCodeTool.toolName, arguments: RunCodeArguments(code: "x = 1")))
        let same = try #require(
            ToolCallIdentity(toolName: CountingRunCodeTool.toolName, arguments: RunCodeArguments(code: "x = 1")))
        let other = try #require(
            ToolCallIdentity(toolName: CountingRunCodeTool.toolName, arguments: RunCodeArguments(code: "x = 2")))

        #expect(identity == same)
        #expect(identity != other)
        #expect(identity.argumentsJSON.contains("x = 1"))
    }
}
