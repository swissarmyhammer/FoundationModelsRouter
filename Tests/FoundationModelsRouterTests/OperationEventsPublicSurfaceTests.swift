import Foundation
import Testing

import FoundationModelsRouter

/// Exercises ``TranscriptEvent/operationEvents`` — the one public entry point a
/// package outside this one reads a recorded entry's typed operation events
/// through.
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: were that property to lose `public`, this file would stop
/// compiling before a single test ran. That is the assertion that matters,
/// because the only consumer of this surface lives in another package, where
/// `@testable` is not available to it.
///
/// The fixture is written as raw JSONL and read back through
/// ``TranscriptEvent/merged(under:)``, because ``TranscriptEvent``'s memberwise
/// initializer is internal — which is exactly what an outside caller sees, so
/// the suite reaches the property the same way that caller does.
@Suite("TranscriptEvent.operationEvents: read an entry's operation events over the public surface")
struct OperationEventsPublicSurfaceTests {
    /// The temp-directory prefix every fixture in this suite is built with, so a
    /// leaked directory is attributable to this suite.
    private static let tempDirPrefix = "OperationEventsPublicSurfaceTests"

    /// The transcript file name a recorder writes under each session directory,
    /// and the one the merge discovers.
    private static let transcriptFileName = "transcript.jsonl"

    /// The `schemaName` the router persists an operation-event segment under.
    ///
    /// The segment type is internal, and the string is `String(reflecting:)` of
    /// it. This suite spells it out only to BUILD a fixture by hand; the
    /// property under test is precisely what stops an outside reader from
    /// needing to know it.
    private static let operationEventSchemaName = "FoundationModelsRouter.OperationEventSegment"

    /// A `schemaName` that names some other structured segment, so the segment
    /// carrying it is one no operation-event read can rebuild.
    private static let foreignSchemaName = "FoundationModelsRouter.CompactionSegment"

    /// The completion token every event in this suite is correlated under.
    private static let correlationID = "01AN4Z07BY79KA1307SR9X4MV3"

    // MARK: - The read

    @Test("only the segments carrying a decodable operation event come back, and in segment order")
    func onlyDecodableSegmentsComeBackInSegmentOrder() throws {
        let first = Self.event(kind: .progress, detail: "812 lines so far")
        let last = Self.event(kind: .completed, detail: "exit 0, 2481 lines")
        let segments: [SegmentPayload] = [
            try Self.operationEventSegment(id: "first-run-report", carrying: first),
            // A segment of another case entirely: the flattened preamble line
            // the model reads.
            .text(
                id: "preamble-line",
                content: "[shell] run command (\(Self.correlationID)) completed"
            ),
            // A structured segment of another schema: it decodes as JSON, and it
            // is not an operation event.
            .structure(
                id: "foreign-schema-segment",
                schemaName: Self.foreignSchemaName,
                contentJSON: #"{"turnsCompacted":3}"#
            ),
            // A structured segment under the operation-event schema whose body
            // is missing every required field, so decoding it throws.
            .structure(
                id: "undecodable-segment",
                schemaName: Self.operationEventSchemaName,
                contentJSON: #"{"tool":"shell"}"#
            ),
            try Self.operationEventSegment(id: "last-run-report", carrying: last),
        ]

        let read = try Self.readBackEvent(withSegments: segments)

        #expect(read.operationEvents == [first, last])
    }

    @Test("an event that mirrors no entry carries no operation events")
    func eventWithoutAnEntryCarriesNoOperationEvents() throws {
        // A router-only kind records no `Transcript.Entry`, and the consumer
        // flat-maps over every recorded event, this one included.
        let read = try Self.readBackEvent(withSegments: nil)

        #expect(read.entry == nil)
        #expect(read.operationEvents.isEmpty)
    }

    // MARK: - Fixtures

    /// Builds one canned ``OperationEvent`` under ``correlationID``.
    ///
    /// - Parameters:
    ///   - kind: The event's kind.
    ///   - detail: The event's detail payload.
    /// - Returns: The event.
    private static func event(kind: OperationEventKind, detail: String) -> OperationEvent {
        OperationEvent(
            tool: "shell",
            op: "run command",
            correlationID: correlationID,
            kind: kind,
            detail: detail,
            outcome: kind == .completed ? .succeeded : nil
        )
    }

    /// Builds the structured segment the router persists for one operation
    /// event, with the body encoded from the event itself rather than written
    /// out by hand.
    ///
    /// - Parameters:
    ///   - id: The segment's id.
    ///   - event: The event the segment carries.
    /// - Returns: The segment payload.
    /// - Throws: Whatever encoding `event` throws.
    private static func operationEventSegment(
        id: String, carrying event: OperationEvent
    ) throws -> SegmentPayload {
        let body = try JSONEncoder().encode(event)
        return .structure(
            id: id,
            schemaName: operationEventSchemaName,
            contentJSON: String(decoding: body, as: UTF8.self)
        )
    }

    /// Writes a one-line fixture transcript carrying `segments`, and reads it
    /// back through the public merge.
    ///
    /// - Parameter segments: The entry's segments, or `nil` for a recorded event
    ///   that mirrors no entry at all.
    /// - Returns: The single decoded event.
    /// - Throws: Whatever encoding the fixture, writing it, or merging it
    ///   throws.
    private static func readBackEvent(withSegments segments: [SegmentPayload]?) throws
        -> TranscriptEvent
    {
        let routerDirectory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: routerDirectory) }

        try write(line: try line(withSegments: segments), under: routerDirectory)
        let merged = try TranscriptEvent.merged(under: routerDirectory)
        return try #require(merged.first)
    }

    /// Builds the recorded JSON line for a fixture event.
    ///
    /// - Parameter segments: The entry's segments, or `nil` for a line that
    ///   carries no `entry` key.
    /// - Returns: The line, as a JSON object.
    /// - Throws: Whatever encoding `segments` throws.
    private static func line(withSegments segments: [SegmentPayload]?) throws -> [String: Any] {
        var line: [String: Any] = [
            "routerId": ULID.generate().description,
            "sessionId": ULID.generate().description,
            "seq": 0,
            "ts": 0,
            "kind": segments == nil ? "divergence" : "prompt",
        ]
        if let segments {
            line["entry"] = [
                "entryId": "the-recorded-entry",
                "segments": try JSONSerialization.jsonObject(
                    with: try JSONEncoder().encode(segments)
                ),
            ]
        }
        return line
    }

    /// Writes one session directory under `routerDirectory`, holding `line` as
    /// the only line of its `transcript.jsonl`.
    ///
    /// - Parameters:
    ///   - line: The recorded line, as a JSON object.
    ///   - routerDirectory: The router's recording root the merge reads under.
    /// - Throws: Whatever serializing the line, creating the directory, or
    ///   writing the file throws.
    private static func write(line: [String: Any], under routerDirectory: URL) throws {
        let sessionDirectory = routerDirectory.appendingPathComponent(
            ULID.generate().description,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        var body = try JSONSerialization.data(withJSONObject: line)
        body.append(contentsOf: Array("\n".utf8))
        try body.write(
            to: sessionDirectory.appendingPathComponent(transcriptFileName, isDirectory: false)
        )
    }
}
