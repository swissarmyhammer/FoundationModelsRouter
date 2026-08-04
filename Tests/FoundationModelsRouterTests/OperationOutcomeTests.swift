import Foundation
import Testing

@testable import FoundationModelsRouter

@Suite struct OperationOutcomeTests {

    // MARK: - rawValue: snake_case wire vocabulary

    @Test(
        arguments: [
            (OperationOutcome.succeeded, "succeeded"),
            (OperationOutcome.failed, "failed"),
            (OperationOutcome.timedOut, "timed_out"),
            (OperationOutcome.stopped, "stopped"),
            (OperationOutcome.cancelled, "cancelled"),
            (OperationOutcome.lost, "lost"),
        ]
    )
    func rawValueIsSnakeCase(outcome: OperationOutcome, expected: String) {
        #expect(outcome.rawValue == expected)
    }

    // MARK: - init(rawValue:): known values round-trip, unknown preserved

    @Test(
        arguments: [
            ("succeeded", OperationOutcome.succeeded),
            ("failed", OperationOutcome.failed),
            ("timed_out", OperationOutcome.timedOut),
            ("stopped", OperationOutcome.stopped),
            ("cancelled", OperationOutcome.cancelled),
            ("lost", OperationOutcome.lost),
        ]
    )
    func initRawValueRoundTripsKnownCases(raw: String, expected: OperationOutcome) {
        #expect(OperationOutcome(rawValue: raw) == expected)
    }

    @Test func initRawValuePreservesUnrecognizedValueAsOther() {
        let outcome = OperationOutcome(rawValue: "quarantined")

        #expect(outcome == .other("quarantined"))
        #expect(outcome.rawValue == "quarantined")
    }

    // MARK: - Codable: wire shape is a bare JSON string

    @Test func encodesAsBareJSONStringMatchingRawValue() throws {
        let data = try JSONEncoder().encode(OperationOutcome.timedOut)

        #expect(String(data: data, encoding: .utf8) == "\"timed_out\"")
    }

    @Test func decodesKnownStringIntoTheMatchingCase() throws {
        let data = Data("\"cancelled\"".utf8)

        let decoded = try JSONDecoder().decode(OperationOutcome.self, from: data)

        #expect(decoded == .cancelled)
    }

    @Test func decodingUnrecognizedStringDoesNotThrowAndPreservesTheValue() throws {
        let data = Data("\"future_outcome\"".utf8)

        let decoded = try JSONDecoder().decode(OperationOutcome.self, from: data)

        #expect(decoded == .other("future_outcome"))
    }

    @Test func codableRoundTripPreservesEveryKnownCase() throws {
        let outcomes: [OperationOutcome] = [.succeeded, .failed, .timedOut, .stopped, .cancelled, .lost, .other("x")]

        for outcome in outcomes {
            let data = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(OperationOutcome.self, from: data)
            #expect(decoded == outcome)
        }
    }
}
