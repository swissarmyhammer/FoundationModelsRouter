import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The event-vocabulary tests ported from the Operations package alongside
/// the vocabulary itself (`OperationEvent`/`OperationEventSink`/
/// `EventEmittingTool`): `OperationEvent`'s Codable wire shape (including the
/// `outcome` `decodeIfPresent` back-compat case) and `connecting(_:)`'s pure,
/// route-independent copy semantics. The originals' `OperationTool`-fused
/// fixtures stay behind in Operations; these tests exercise the same
/// contracts through plain `FoundationModels.Tool` fixtures instead.
@Suite struct EventEmittingToolTests {

    // MARK: - Fixtures

    /// Collects every event posted to it, for assertion. Stands in for a real
    /// session host's outbox.
    private actor FakeEventSinkActor: OperationEventSink {
        private(set) var events: [OperationEvent] = []

        func post(_ event: OperationEvent) async {
            events.append(event)
        }
    }

    /// Reference-typed state shared by every copy `EmittingJobTool`
    /// `connecting(_:)` produces, independent of its event route — proves
    /// `connecting(_:)` copies keep sharing underlying state while each gets
    /// its own route.
    private actor SharedRunLog {
        private(set) var correlationIDs: [String] = []

        func record(_ correlationID: String) {
            correlationIDs.append(correlationID)
        }
    }

    @Generable
    struct EmitJobArguments {
        let correlationID: String
    }

    /// `run job` fixture: a real `FoundationModels.Tool` conforming to
    /// `EventEmittingTool` that posts a `.progress` then a `.completed` event
    /// through its own connected sink (a safe no-op when none is connected)
    /// while executing, and records its `correlationID` into the shared run
    /// log regardless — exercising posting and shared state together.
    /// `@unchecked Sendable`: `sink` is immutable (`let`), so concurrent reads
    /// are safe even if `OperationEventSink` does not conform to `Sendable`.
    private final class EmittingJobTool: Tool, EventEmittingTool, @unchecked Sendable {
        let name = "jobs"
        let description = "test-only tool that posts progress and completion events while running"

        private let sink: (any OperationEventSink)?
        let runLog: SharedRunLog

        init(sink: (any OperationEventSink)? = nil, runLog: SharedRunLog = SharedRunLog()) {
            self.sink = sink
            self.runLog = runLog
        }

        /// Pure: returns a new instance wired to `sink`, sharing the
        /// receiver's run log, never mutating `self` — the receiver keeps
        /// posting into the void forever.
        func connecting(_ sink: any OperationEventSink) -> any Tool {
            EmittingJobTool(sink: sink, runLog: runLog)
        }

        func call(arguments: EmitJobArguments) async throws -> String {
            await sink?.post(
                OperationEvent(
                    tool: name, op: "run job", correlationID: arguments.correlationID, kind: .progress,
                    detail: "{\"percent\":50}")
            )
            await sink?.post(
                OperationEvent(
                    tool: name, op: "run job", correlationID: arguments.correlationID, kind: .completed,
                    detail: "{\"percent\":100}")
            )
            await runLog.record(arguments.correlationID)
            return "{\"done\":true}"
        }
    }

    @Generable
    struct PlainArguments {
        let message: String
    }

    /// A plain `Tool` with no `EventEmittingTool` conformance, pairing with
    /// `EmittingJobTool` for the mixed `[any Tool]` list test.
    private struct PlainTool: Tool {
        let name = "plain"
        let description = "a tool with no event-emitting capability"

        func call(arguments: PlainArguments) async throws -> String {
            "plain: \(arguments.message)"
        }
    }

    // MARK: - OperationEvent: Codable round trip and wire shape

    @Test func operationEventCodableRoundTripPreservesAllFields() throws {
        let event = OperationEvent(
            tool: "jobs", op: "run job", correlationID: "cid-1", kind: .completed, detail: "{\"percent\":100}")

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test func operationEventEncodesKindAsLowercaseRawStringInJSON() throws {
        let event = OperationEvent(tool: "jobs", op: "run job", correlationID: "cid-1", kind: .progress, detail: "{}")

        let data = try JSONEncoder().encode(event)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"kind\":\"progress\""))
    }

    // MARK: - OperationEvent.outcome: backward compatibility and round trip

    @Test func initDefaultsOutcomeToNilSoExistingCallSitesCompileUnchanged() {
        let event = OperationEvent(tool: "jobs", op: "run job", correlationID: "cid-1", kind: .progress, detail: "{}")

        #expect(event.outcome == nil)
    }

    @Test func decodingAPreviouslyRecordedEventWithNoOutcomeKeyDefaultsToNil() throws {
        // Simulates an `OperationEvent` recorded before `outcome` existed —
        // e.g. a Router-journaled `OperationEventSegment` already committed
        // to a transcript. `decodeIfPresent` must default to `nil` rather
        // than throwing `keyNotFound`.
        let json = """
            {"tool":"jobs","op":"run job","correlationID":"cid-1","kind":"completed","detail":"{\\"percent\\":100}"}
            """
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)

        #expect(decoded.outcome == nil)
        #expect(decoded.kind == .completed)
    }

    @Test func codableRoundTripPreservesAPresentOutcome() throws {
        let event = OperationEvent(
            tool: "jobs", op: "run job", correlationID: "cid-1", kind: .completed, detail: "{}", outcome: .succeeded)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OperationEvent.self, from: data)

        #expect(decoded == event)
        #expect(decoded.outcome == .succeeded)
    }

    // MARK: - connecting(_:): route independence + shared state

    @Test func connectingTwoSinksPostIndependentlyWhileSharingUnderlyingState() async throws {
        // "tool.connecting(sinkA) and tool.connecting(sinkB) post to their
        // own sinks independently; the original posts into the void; all
        // three share underlying reference-typed state" — one test proving
        // both route independence and state sharing together.
        let runLog = SharedRunLog()
        let baseTool = EmittingJobTool(runLog: runLog)
        let sinkA = FakeEventSinkActor()
        let sinkB = FakeEventSinkActor()

        guard let toolA = baseTool.connecting(sinkA) as? EmittingJobTool else {
            Issue.record("connecting(_:) did not return an EmittingJobTool")
            return
        }
        guard let toolB = baseTool.connecting(sinkB) as? EmittingJobTool else {
            Issue.record("connecting(_:) did not return an EmittingJobTool")
            return
        }

        _ = try await toolA.call(arguments: EmitJobArguments(correlationID: "cid-a"))
        _ = try await toolB.call(arguments: EmitJobArguments(correlationID: "cid-b"))
        _ = try await baseTool.call(arguments: EmitJobArguments(correlationID: "cid-orig"))

        let eventsA = await sinkA.events
        let eventsB = await sinkB.events
        #expect(eventsA.map(\.correlationID) == ["cid-a", "cid-a"])
        #expect(eventsB.map(\.correlationID) == ["cid-b", "cid-b"])

        // All three dispatches — toolA, toolB, and the un-connected
        // baseTool — recorded into the same shared run log, proving the
        // reference-typed state is shared across every copy.
        let recordedIDs = await runLog.correlationIDs
        #expect(recordedIDs == ["cid-a", "cid-b", "cid-orig"])
    }

    @Test func toolWithNoConnectedSinkDispatchesNormallyWithoutErrorOrRetention() async throws {
        let tool = EmittingJobTool()

        let json = try await tool.call(arguments: EmitJobArguments(correlationID: "cid-2"))

        #expect(json.contains("\"done\":true"))
    }

    // MARK: - Host mapping over a mixed [any Tool] list

    @Test func hostMappingOverAMixedAnyToolListConnectsOnlyEmittingToolsPureCopies() async throws {
        let emittingTool = EmittingJobTool()
        let plainTool: any Tool = PlainTool()
        let tools: [any Tool] = [plainTool, emittingTool]
        let sink = FakeEventSinkActor()

        let connectedTools = tools.map { tool in
            (tool as? any EventEmittingTool)?.connecting(sink) ?? tool
        }

        #expect(connectedTools.count == 2)
        #expect(plainTool as? any EventEmittingTool == nil)

        guard let passthroughPlain = connectedTools[0] as? PlainTool else {
            Issue.record("Non-conforming tool did not pass through as a PlainTool")
            return
        }
        let plainResult = try await passthroughPlain.call(arguments: PlainArguments(message: "hi"))
        #expect(plainResult == "plain: hi")

        guard let connectedEmitting = connectedTools[1] as? EmittingJobTool else {
            Issue.record("Emitting tool's connecting(_:) did not return an EmittingJobTool")
            return
        }
        _ = try await connectedEmitting.call(arguments: EmitJobArguments(correlationID: "cid-1"))

        let events = await sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.allSatisfy { $0.tool == "jobs" && $0.op == "run job" && $0.correlationID == "cid-1" })
    }
}
