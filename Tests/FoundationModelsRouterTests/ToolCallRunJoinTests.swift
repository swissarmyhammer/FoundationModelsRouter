import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^xhmws92: a live ``SessionEvent/toolInvocation(_:toolCallID:)``
/// event carries the SDK `Transcript.ToolCall.id` of the call that started its
/// run, the same id that the ``SessionEvent/toolCall(id:name:argumentsJSON:)``
/// event of that call carries. The record keeps the run's `completionToken`
/// as its `correlationID`: the event carries the two ids side by side.
@Suite("Tool call run join: the SDK tool-call id on the live invocation events of a run")
struct ToolCallRunJoinTests {
    /// The temp directory prefix every fixture of this suite is built with.
    private static let tempDirPrefix = "ToolCallRunJoinTests"

    /// The SDK id of the first scripted call.
    private static let firstCallID = "call-first"

    /// The SDK id of the second scripted call.
    private static let secondCallID = "call-second"

    /// The step name the second scripted call names.
    private static let secondStepName = "TWO"

    /// The tool name the unit tests give their records and calls.
    private static let toolName = "search"

    /// A tool name that no announced call of the unit tests names.
    private static let otherToolName = "fetch"

    // MARK: - A scripted answer

    @Test("the open and the close invocation events of a run carry the id of the toolCall event of that run")
    @MainActor
    func invocationEventsCarryTheToolCallIdOfTheirRun() async throws {
        let tool = MarkerEmittingTool()
        let script = ScriptedAnswerScript(rounds: [
            [
                ScriptedToolCall(
                    id: Self.firstCallID, toolName: tool.name, argument: .literal(ScriptedToolFixture.firstStepName))
            ]
        ])
        let fixture = try await ScriptedSessionFixture.make(
            playing: script, mounting: [tool], tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)

        #expect(Self.toolCallIDs(in: events) == [Self.firstCallID])
        #expect(Self.invocationToolCallIDs(in: events) == [Self.firstCallID, Self.firstCallID])
    }

    @Test("two calls of one tool in two rounds each join the id of their own call")
    @MainActor
    func twoRunsOfOneToolJoinTheirOwnCalls() async throws {
        let tool = MarkerEmittingTool()
        let script = ScriptedAnswerScript(rounds: [
            [
                ScriptedToolCall(
                    id: Self.firstCallID, toolName: tool.name, argument: .literal(ScriptedToolFixture.firstStepName))
            ],
            [ScriptedToolCall(id: Self.secondCallID, toolName: tool.name, argument: .literal(Self.secondStepName))],
        ])
        let fixture = try await ScriptedSessionFixture.make(
            playing: script, mounting: [tool], tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)

        #expect(Self.toolCallIDs(in: events) == [Self.firstCallID, Self.secondCallID])
        #expect(
            Self.invocationToolCallIDs(in: events) == [
                Self.firstCallID, Self.firstCallID, Self.secondCallID, Self.secondCallID,
            ])
    }

    // MARK: - The join alone

    @Test("an open record joins the first announced call with its tool name")
    func openRecordJoinsTheFirstCallWithItsToolName() throws {
        var join = ToolCallRunJoin()
        let entries = [
            try Self.toolCallsEntry([(Self.firstCallID, Self.otherToolName), (Self.secondCallID, Self.toolName)])
        ]

        #expect(join.toolCallID(for: Self.openRecord(tool: Self.toolName), in: entries) == Self.secondCallID)
    }

    @Test("an open record whose tool no announced call names joins no id")
    func openRecordWithNoCallOfItsToolJoinsNothing() throws {
        var join = ToolCallRunJoin()
        let entries = [try Self.toolCallsEntry([(Self.firstCallID, Self.toolName)])]

        #expect(join.toolCallID(for: Self.openRecord(tool: Self.otherToolName), in: entries) == nil)
    }

    @Test("a second open record of one tool joins the next call, and a third finds none")
    func eachCallJoinsOneRunOnly() throws {
        var join = ToolCallRunJoin()
        let entries = [
            try Self.toolCallsEntry([(Self.firstCallID, Self.toolName), (Self.secondCallID, Self.toolName)])
        ]

        #expect(join.toolCallID(for: Self.openRecord(tool: Self.toolName), in: entries) == Self.firstCallID)
        #expect(join.toolCallID(for: Self.openRecord(tool: Self.toolName), in: entries) == Self.secondCallID)
        #expect(join.toolCallID(for: Self.openRecord(tool: Self.toolName), in: entries) == nil)
    }

    @Test("an open record does not join a call that an output already answered")
    func answeredCallJoinsNoRun() throws {
        var join = ToolCallRunJoin()
        let entries = [
            try Self.toolCallsEntry([(Self.firstCallID, Self.toolName)]),
            Self.toolOutputEntry(answering: Self.firstCallID),
        ]

        #expect(join.toolCallID(for: Self.openRecord(tool: Self.toolName), in: entries) == nil)
    }

    @Test("a close record carries the id of its open record, also when the entries are gone")
    func closeRecordCarriesTheIdOfItsOpenRecord() throws {
        var join = ToolCallRunJoin()
        let open = Self.openRecord(tool: Self.toolName)
        let entries = [try Self.toolCallsEntry([(Self.firstCallID, Self.toolName)])]

        #expect(join.toolCallID(for: open, in: entries) == Self.firstCallID)
        #expect(join.toolCallID(for: open.closed(at: Date()), in: []) == Self.firstCallID)
    }

    @Test("a close record whose open record joined no call carries no id")
    func closeRecordOfAnUnjoinedRunCarriesNothing() throws {
        var join = ToolCallRunJoin()
        let entries = [try Self.toolCallsEntry([(Self.firstCallID, Self.toolName)])]

        let close = Self.openRecord(tool: Self.toolName).closed(at: Date())

        #expect(join.toolCallID(for: close, in: entries) == nil)
    }

    // MARK: - Helpers

    /// The ids of the ``SessionEvent/toolCall(id:name:argumentsJSON:)`` events
    /// among `events`, in order.
    ///
    /// - Parameter events: The events of one answer, in stream order.
    /// - Returns: The SDK id of each `toolCall` event.
    private static func toolCallIDs(in events: [SessionEvent]) -> [String] {
        events.compactMap { event in
            guard case .toolCall(let id, _, _) = event else { return nil }
            return id
        }
    }

    /// The SDK id of each ``SessionEvent/toolInvocation(_:toolCallID:)`` event
    /// among `events`, in order, with `nil` for a record that joined no call.
    ///
    /// - Parameter events: The events of one answer, in stream order.
    /// - Returns: One id for each invocation event.
    private static func invocationToolCallIDs(in events: [SessionEvent]) -> [String?] {
        events.filter { $0.carriedInvocation != nil }.map(\.carriedToolCallID)
    }

    /// An open record of a fresh run of `tool`.
    ///
    /// - Parameter tool: The tool name the record carries.
    /// - Returns: The open record, with a fresh `completionToken`.
    private static func openRecord(tool: String) -> ToolInvocationRecord {
        ToolInvocationRecord(
            tool: tool, op: tool, correlationID: RunPlane.makeCompletionToken(), sessionID: .generate(),
            openedAt: Date())
    }

    /// One `.toolCalls` entry that announces `calls`, in order.
    ///
    /// - Parameter calls: The SDK id and the tool name of each call.
    /// - Returns: The entry.
    /// - Throws: When `{}` does not parse as generated content.
    private static func toolCallsEntry(_ calls: [(id: String, toolName: String)]) throws -> Transcript.Entry {
        let arguments = try GeneratedContent(json: "{}")
        return .toolCalls(
            Transcript.ToolCalls(
                calls.map { Transcript.ToolCall(id: $0.id, toolName: $0.toolName, arguments: arguments) }))
    }

    /// One `.toolOutput` entry that answers the call with id `callID`.
    ///
    /// - Parameter callID: The SDK id of the answered call.
    /// - Returns: The entry.
    private static func toolOutputEntry(answering callID: String) -> Transcript.Entry {
        .toolOutput(Transcript.ToolOutput(id: callID, toolName: toolName, segments: []))
    }
}
