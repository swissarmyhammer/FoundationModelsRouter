import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for the entry-shaped `TranscriptEvent` schema v2: the new ``TranscriptEvent/Kind``
/// cases that mirror `FoundationModels.Transcript.Entry`'s six cases, and
/// ``TranscriptEntryPayload``'s structural mirror of an entry's payload.
///
/// Every change here is purely additive: old v1 JSONL lines — no `entry`
/// field, and the legacy `.toolCall` kind — must still decode unchanged.
@Suite("TranscriptEvent schema v2")
struct TranscriptEventSchemaTests {
    private static let fixedInstant = Date(timeIntervalSinceReferenceDate: 2_000.25)

    // MARK: - New Kind cases

    @Test("instructions, toolCalls, and reasoning kinds round-trip through Codable")
    func newKindCasesRoundTrip() throws {
        for kind: TranscriptEvent.Kind in [.instructions, .toolCalls, .reasoning] {
            let event = TranscriptEvent(
                routerId: .generate(),
                sessionId: .generate(),
                seq: 1,
                ts: Self.fixedInstant,
                kind: kind
            )
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: data)
            #expect(decoded == event)
            #expect(decoded.kind == kind)
        }
    }

    @Test("the legacy toolCall kind still decodes")
    func legacyToolCallStillDecodes() throws {
        let routerId = ULID.generate().description
        let sessionId = ULID.generate().description
        let json = """
        {"routerId":"\(routerId)","sessionId":"\(sessionId)","seq":0,"ts":0,"kind":"toolCall"}
        """
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: Data(json.utf8))
        #expect(decoded.kind == .toolCall)
        #expect(decoded.entry == nil)
    }

    // MARK: - v1 compatibility

    @Test("a v1 line with no entry field decodes with entry == nil")
    func v1LineDecodesWithNilEntry() throws {
        let routerId = ULID.generate().description
        let sessionId = ULID.generate().description
        let json = """
        {"routerId":"\(routerId)","sessionId":"\(sessionId)","seq":0,"ts":0,"kind":"prompt","text":"hello"}
        """
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: Data(json.utf8))
        #expect(decoded.entry == nil)
        #expect(decoded.text == "hello")
    }

    // MARK: - entry threaded through Partial

    @Test("Partial carries entry through mapText unchanged")
    func partialCarriesEntryThroughMapText() {
        let payload = TranscriptEntryPayload(entryId: "e1")
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .instructions,
            entry: payload
        )
        let mapped = partial.mapText { _ in nil }
        #expect(mapped.entry == payload)
    }

    @Test("Partial.stamped carries entry onto the finished event")
    func stampedCarriesEntry() {
        let payload = TranscriptEntryPayload(entryId: "e1")
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .instructions,
            entry: payload
        )
        let event = partial.stamped(seq: 0, ts: Self.fixedInstant)
        #expect(event.entry == payload)
    }

    @Test("a Partial built without entry stamps a nil entry")
    func stampedWithoutEntryIsNil() {
        let partial = TranscriptEvent.Partial(
            routerId: .generate(),
            sessionId: .generate(),
            kind: .session
        )
        let event = partial.stamped(seq: 0, ts: Self.fixedInstant)
        #expect(event.entry == nil)
    }

    // MARK: - TranscriptEntryPayload round trips

    @Test("contentRemoved defaults to false when absent from JSON")
    func contentRemovedDefaultsFalseWhenAbsent() throws {
        let json = """
        {"entryId":"e1"}
        """
        let decoded = try JSONDecoder().decode(TranscriptEntryPayload.self, from: Data(json.utf8))
        #expect(decoded.contentRemoved == false)
    }

    @Test("TranscriptEntryPayload round-trips for the instructions entry shape")
    func instructionsShapeRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "instr-1",
            segments: [.text(id: "s1", content: "you are a helpful assistant")],
            toolDefinitions: [
                ToolDefinitionPayload(
                    name: "search",
                    description: "search the web",
                    parametersSchemaJSON: #"{"type":"object"}"#
                )
            ]
        )
        try assertRoundTrips(payload)
    }

    @Test("TranscriptEntryPayload round-trips for the prompt entry shape")
    func promptShapeRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "prompt-1",
            segments: [.text(id: "s1", content: "what's the weather")],
            options: GenerationOptionsPayload(temperature: 0.7, maximumResponseTokens: 512),
            responseFormatName: "WeatherReport",
            responseFormatSchemaJSON: #"{"type":"object","properties":{}}"#
        )
        try assertRoundTrips(payload)
    }

    @Test("TranscriptEntryPayload round-trips for the toolCalls entry shape")
    func toolCallsShapeRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "calls-1",
            toolCalls: [
                ToolCallPayload(id: "call-1", toolName: "search", argumentsJSON: #"{"query":"weather"}"#)
            ]
        )
        try assertRoundTrips(payload)
    }

    @Test("TranscriptEntryPayload round-trips for the toolOutput entry shape")
    func toolOutputShapeRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "output-1",
            segments: [.text(id: "s1", content: "sunny, 72F")],
            toolName: "search"
        )
        try assertRoundTrips(payload)
    }

    @Test("TranscriptEntryPayload round-trips for the response entry shape")
    func responseShapeRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "response-1",
            segments: [.text(id: "s1", content: "it's sunny and 72F")],
            assetIds: ["asset-1", "asset-2"]
        )
        try assertRoundTrips(payload)
    }

    @Test("TranscriptEntryPayload round-trips for the reasoning entry shape")
    func reasoningShapeRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "reasoning-1",
            segments: [.text(id: "s1", content: "the user wants the weather")],
            signature: Data("sig-bytes".utf8)
        )
        try assertRoundTrips(payload)
    }

    @Test("TranscriptEntryPayload round-trips contentRemoved true")
    func contentRemovedTrueRoundTrips() throws {
        let payload = TranscriptEntryPayload(entryId: "e1", contentRemoved: true)
        try assertRoundTrips(payload)
        #expect(payload.contentRemoved == true)
    }

    @Test("TranscriptEntryPayload round-trips with every field populated at once")
    func everyFieldPopulatedRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "kitchen-sink",
            contentRemoved: false,
            segments: [
                .text(id: "s1", content: "hi"),
                .structure(id: "s2", schemaName: "Schema", contentJSON: "{}"),
                .attachment(id: "s3", label: "img", url: "file:///x.png"),
                .custom(id: "s4", typeDiscriminator: "Foo", contentJSON: "{}", description: "d"),
            ],
            toolDefinitions: [
                ToolDefinitionPayload(name: "t", description: "d", parametersSchemaJSON: "{}")
            ],
            toolCalls: [ToolCallPayload(id: "c1", toolName: "t", argumentsJSON: "{}")],
            toolName: "t",
            assetIds: ["a1"],
            signature: Data([0x01, 0x02, 0x03]),
            options: GenerationOptionsPayload(temperature: 1.0, maximumResponseTokens: 100),
            responseFormatName: "Fmt",
            responseFormatSchemaJSON: "{}"
        )
        try assertRoundTrips(payload)
    }

    // MARK: - Segment shapes

    @Test("structure segment round-trips id, schemaName, and contentJSON")
    func structureSegmentRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [.structure(id: "s1", schemaName: "WeatherReport", contentJSON: #"{"temp":72}"#)]
        )
        try assertRoundTrips(payload)
    }

    @Test("attachment segment round-trips id, label, and url")
    func attachmentSegmentRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [.attachment(id: "s1", label: "photo", url: "file:///tmp/photo.png")]
        )
        try assertRoundTrips(payload)
    }

    @Test("attachment segment round-trips with a nil url")
    func attachmentSegmentRoundTripsWithNilURL() throws {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [.attachment(id: "s1", label: "photo", url: nil)]
        )
        try assertRoundTrips(payload)
    }

    @Test("custom segment round-trips typeDiscriminator, contentJSON, and description")
    func customSegmentRoundTrips() throws {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [
                .custom(
                    id: "s1",
                    typeDiscriminator: "com.example.MySegment",
                    contentJSON: #"{"foo":"bar"}"#,
                    description: "a flattened GUI convenience description"
                )
            ]
        )
        try assertRoundTrips(payload)
    }

    @Test("custom segment round-trips with a nil description")
    func customSegmentRoundTripsWithNilDescription() throws {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [
                .custom(id: "s1", typeDiscriminator: "com.example.MySegment", contentJSON: "{}", description: nil)
            ]
        )
        try assertRoundTrips(payload)
    }

    @Test("segments of every kind round-trip together in one payload")
    func mixedSegmentsRoundTrip() throws {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [
                .text(id: "s1", content: "hello"),
                .structure(id: "s2", schemaName: "Schema", contentJSON: "{}"),
                .attachment(id: "s3", label: "img", url: "file:///x.png"),
                .custom(id: "s4", typeDiscriminator: "Foo", contentJSON: "{}", description: "d"),
            ]
        )
        try assertRoundTrips(payload)
    }

    @Test("a payload with a nil segments array round-trips")
    func nilSegmentsRoundTrips() throws {
        let payload = TranscriptEntryPayload(entryId: "e1")
        try assertRoundTrips(payload)
        #expect(payload.segments == nil)
    }

    @Test("a segment with no type discriminator key fails to decode")
    func segmentMissingTypeKeyThrows() {
        let json = """
        {"id":"s1","content":"hello"}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SegmentPayload.self, from: Data(json.utf8))
        }
    }

    @Test("a segment with an unrecognized type discriminator fails to decode")
    func segmentUnknownTypeThrows() {
        let json = """
        {"type":"bogus","id":"s1"}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SegmentPayload.self, from: Data(json.utf8))
        }
    }

    // MARK: - MergedTranscript over mixed v1/v2 files

    @Test("MergedTranscript.merged(under:) decodes a directory mixing v1 and v2 lines")
    func mergedTranscriptDecodesMixedV1AndV2() throws {
        let routerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: routerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: routerDir) }

        // A v1 file: no `entry` field, legacy toolCall kind.
        let v1Dir = routerDir.appendingPathComponent("v1session", isDirectory: true)
        try FileManager.default.createDirectory(at: v1Dir, withIntermediateDirectories: true)
        let routerId = ULID.generate().description
        let sessionId = ULID.generate().description
        let v1Line = """
        {"routerId":"\(routerId)","sessionId":"\(sessionId)","seq":0,"ts":0,"kind":"toolCall"}
        """
        try v1Line.write(
            to: v1Dir.appendingPathComponent("transcript.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        // A v2 file: entry payload present, new kind.
        let v2Dir = routerDir.appendingPathComponent("v2session", isDirectory: true)
        try FileManager.default.createDirectory(at: v2Dir, withIntermediateDirectories: true)
        let v2Event = TranscriptEvent(
            routerId: .generate(),
            sessionId: .generate(),
            seq: 1,
            ts: Self.fixedInstant,
            kind: .toolCalls,
            entry: TranscriptEntryPayload(
                entryId: "calls-1",
                toolCalls: [ToolCallPayload(id: "c1", toolName: "search", argumentsJSON: "{}")]
            )
        )
        var v2Line = try JSONEncoder().encode(v2Event)
        v2Line.append(0x0A)
        try v2Line.write(to: v2Dir.appendingPathComponent("transcript.jsonl", isDirectory: false))

        let merged = try MergedTranscript.merged(under: routerDir)
        #expect(merged.count == 2)
        let v1Decoded = try #require(merged.first { $0.kind == .toolCall })
        #expect(v1Decoded.entry == nil)
        let v2Decoded = try #require(merged.first { $0.kind == .toolCalls })
        #expect(v2Decoded.entry?.entryId == "calls-1")
        #expect(v2Decoded.entry?.toolCalls?.first?.toolName == "search")
    }

    // MARK: - Helpers

    /// Encodes `payload` and decodes it back, asserting equality — the
    /// round-trip contract every field combination must satisfy.
    private func assertRoundTrips(_ payload: TranscriptEntryPayload) throws {
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TranscriptEntryPayload.self, from: data)
        #expect(decoded == payload)
    }
}
