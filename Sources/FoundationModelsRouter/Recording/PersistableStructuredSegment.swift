import Foundation
import FoundationModels
import os

/// The logger the structured-segment bridge reports encode failures to.
private let structuredSegmentLogger = makeModuleLogger(category: "Recording")

/// A typed value the router carries in a transcript as a
/// `Transcript.StructuredSegment`, and reads back from one.
///
/// A conforming type moves between the two forms with ``transcriptSegment``
/// and ``init(structuredSegment:)``. `schemaName` identifies the type on disk.
/// The router conforms ``CompactionSegment`` and ``OperationEventSegment``.
/// A legacy ``SegmentPayload/custom(id:typeDiscriminator:contentJSON:description:)``
/// carrier reads back as a structured segment.
public protocol PersistableStructuredSegment: Sendable {
    /// The typed body this segment carries, persisted as JSON.
    associatedtype Content: Codable & Sendable & Equatable

    /// The stable string that identifies this concrete type on disk.
    /// Defaults to `String(reflecting: Self.self)`.
    static var schemaName: String { get }

    /// This segment's own id.
    var id: String { get }

    /// The typed body.
    var content: Content { get }

    /// Rebuilds a segment from its persisted `id` and decoded `content`.
    /// - Throws: If `content` cannot become a valid segment.
    init(id: String, content: Content) throws
}

extension PersistableStructuredSegment {
    /// The default schema name: this type's fully-qualified name.
    public static var schemaName: String { String(reflecting: Self.self) }

    /// This value as the SDK structured segment that carries it.
    ///
    /// The body is encoded to JSON and parsed into `GeneratedContent` with
    /// its key order intact, so a live segment and its restored twin compare equal.
    /// An encode failure is logged at fault level and the segment carries
    /// ``encodingFailureContentJSON``, which no `Content` decodes from.
    public var structuredSegment: Transcript.StructuredSegment {
        Transcript.StructuredSegment(
            id: id,
            schemaName: Self.schemaName,
            content: Self.generatedContent(from: content, id: id)
        )
    }

    /// This value as a `Transcript.Segment`, ready to put in an entry.
    public var transcriptSegment: Transcript.Segment { .structure(structuredSegment) }

    /// Rebuilds this type from a live structured segment.
    /// - Returns: The rebuilt value, or `nil` when the segment carries another type's `schemaName`.
    /// - Throws: ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)`` when the body does not decode.
    public init?(structuredSegment: Transcript.StructuredSegment) throws {
        guard structuredSegment.schemaName == Self.schemaName else { return nil }
        try self.init(
            id: structuredSegment.id,
            content: Self.decodedContent(
                json: structuredSegment.content.jsonString,
                id: structuredSegment.id
            )
        )
    }

    /// Rebuilds this type from a persisted schema name and body JSON.
    /// - Returns: The rebuilt value, or `nil` when `schemaName` names another type.
    /// - Throws: ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)`` when the body does not decode.
    public init?(schemaName: String, contentJSON: String, id: String) throws {
        guard schemaName == Self.schemaName else { return nil }
        try self.init(id: id, content: Self.decodedContent(json: contentJSON, id: id))
    }

    /// The body a structured segment carries when its `Content` fails to encode.
    /// No router `Content` decodes from it, so a read throws.
    static var encodingFailureContentJSON: String { #"{"_encodingFailed":true}"# }

    /// Encodes `content` to `GeneratedContent`, or logs and returns the
    /// ``encodingFailureContentJSON`` marker. Both paths keep document key order.
    private static func generatedContent(from content: Content, id: String) -> GeneratedContent {
        do {
            let json = try TranscriptEntryMapper.jsonString(
                for: content,
                context: "structured segment \(id) (\(schemaName)) content"
            )
            return try orderPreserving(json: json)
        } catch {
            structuredSegmentLogger.fault(
                "PersistableStructuredSegment: \(String(describing: error), privacy: .public); carrying the encoding-failure marker for segment \(id, privacy: .public) (\(schemaName, privacy: .public))"
            )
            // A literal this file controls, and valid JSON, so the parse
            // cannot fail; the fallback keeps this path total.
            return (try? orderPreserving(json: encodingFailureContentJSON)) ?? GeneratedContent("")
        }
    }

    /// Parses `json` with its document key order intact.
    private static func orderPreserving(json: String) throws -> GeneratedContent {
        try OrderPreservingGeneratedContentDecoder.decode(json: json)
    }

    /// Decodes persisted body JSON into `Content`, as the typed error.
    private static func decodedContent(json: String, id: String) throws -> Content {
        do {
            return try JSONDecoder().decode(Content.self, from: Data(json.utf8))
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(
                context: "structured segment \(id) (\(schemaName)) content",
                underlying: String(describing: error)
            )
        }
    }
}

/// The schema names of the router's own ``PersistableStructuredSegment`` types.
/// ``SegmentPayload/contentByteCount`` excludes these segments from its size estimate.
enum RouterSegmentSchemaNames {
    /// Every schema name the router itself writes.
    static let all: Set<String> = [
        CompactionSegment.schemaName,
        OperationEventSegment.schemaName,
    ]
}
