import Foundation
import Testing

@testable import FoundationModelsRouter

/// The `OperationEvent` wire-shape tests ported from the Operations package
/// alongside the event vocabulary itself (`OperationEvent`/
/// `OperationEventSink`): the Codable round trip and the `outcome`
/// `decodeIfPresent` back-compat case.
@Suite struct OperationEventTests {

    // MARK: - Codable round trip and wire shape

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
}
