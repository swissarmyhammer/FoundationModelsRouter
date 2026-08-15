import Foundation
import FoundationModels
import os

/// The logger the structured-segment bridge reports encode failures to.
private let structuredSegmentLogger = makeModuleLogger(category: "Recording")

/// A typed value the router carries in a transcript as a
/// `Transcript.StructuredSegment`, and reads back from one.
///
/// The SDK gives each structured segment a `schemaName` and a
/// `GeneratedContent` body. This protocol adds the two things a typed value
/// needs on top of that pair: a stable `schemaName` for the concrete type,
/// and an initializer that rebuilds the value from its persisted `id` and
/// decoded `content`.
///
/// A conforming type moves between the two forms with
/// ``transcriptSegment`` (typed value to SDK segment) and
/// ``init(structuredSegment:)`` (SDK segment back to typed value). No
/// registry is necessary: `schemaName` identifies the type on disk, and the
/// reader that wants the typed value already knows which type it asks for.
///
/// The router conforms two of its own types: ``CompactionSegment`` and
/// ``OperationEventSegment``. An integrator can conform more.
///
/// ### Replaces the removed custom-segment API
///
/// The router carried these values as `Transcript.Segment.custom` until the
/// macOS 27 SDK removed `Transcript.CustomSegment` and the `.custom` case.
/// `.structure` is the replacement extension point. The default
/// ``schemaName`` is the same string the removed `typeDiscriminator` used
/// (`String(reflecting: Self.self)`), and reconstruction reads the old
/// ``SegmentPayload/custom(id:typeDiscriminator:contentJSON:description:)``
/// carrier as a structured segment, so a recording written before the SDK
/// change still restores.
public protocol PersistableStructuredSegment: Sendable {
    /// The typed body this segment carries.
    ///
    /// `Codable` because the body is persisted as JSON, `Equatable` because
    /// the tests and the projection compare rebuilt segments with live ones.
    associatedtype Content: Codable & Sendable & Equatable

    /// The stable string that identifies this concrete type on disk and in
    /// the transcript.
    ///
    /// Defaults to the type's fully-qualified name
    /// (`String(reflecting: Self.self)`).
    static var schemaName: String { get }

    /// This segment's own id.
    var id: String { get }

    /// The typed body.
    var content: Content { get }

    /// Rebuilds a segment from its persisted `id` and decoded `content`.
    ///
    /// - Parameters:
    ///   - id: The segment's persisted `id`.
    ///   - content: The segment's body, decoded from its persisted JSON.
    /// - Throws: If `content` cannot become a valid segment.
    init(id: String, content: Content) throws
}

extension PersistableStructuredSegment {
    /// The default schema name: this type's fully-qualified name.
    public static var schemaName: String { String(reflecting: Self.self) }

    /// This value as the SDK structured segment that carries it.
    ///
    /// The body is encoded to JSON and then parsed into `GeneratedContent`.
    /// `GeneratedContent` keeps every value it parses, so the body decodes
    /// back unchanged.
    ///
    /// The parse keeps the encoded document's own key order (see
    /// ``generatedContent(from:id:)``): a `Transcript.StructuredSegment`
    /// compares equal only to a segment whose body carries its keys in the
    /// same order, and a restore reads the persisted body back in document
    /// order. Parsing in that same order here is what makes a live segment
    /// and its restored twin compare equal.
    ///
    /// **An encode failure is loud, and it never fabricates a body.** A
    /// `Content` that fails to encode is a programmer error. This property
    /// cannot throw, because a transcript is built on paths that do not
    /// throw, so it logs the failure at fault level and carries
    /// ``encodingFailureContentJSON`` instead. That marker can never decode
    /// as any `Content`, so a later read refuses it rather than returning
    /// wrong content. This is the same rule the record path applies with its
    /// empty-string sentinel — see ``TranscriptEntryMapper``.
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
    ///
    /// - Parameter structuredSegment: The segment to read.
    /// - Returns: The rebuilt value, or `nil` when the segment carries
    ///   another type's `schemaName`.
    /// - Throws: ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)``
    ///   when the schema name matches but the body does not decode, or when
    ///   ``init(id:content:)`` throws.
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

    /// Rebuilds this type from a persisted schema name and body JSON — the
    /// same read as ``init(structuredSegment:)``, for a reader that holds the
    /// recorded ``SegmentPayload`` instead of a live segment.
    ///
    /// - Parameters:
    ///   - schemaName: The persisted schema name.
    ///   - contentJSON: The persisted body JSON.
    ///   - id: The persisted segment id.
    /// - Returns: The rebuilt value, or `nil` when `schemaName` names another
    ///   type.
    /// - Throws: ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)``
    ///   when the schema name matches but the body does not decode, or when
    ///   ``init(id:content:)`` throws.
    public init?(schemaName: String, contentJSON: String, id: String) throws {
        guard schemaName == Self.schemaName else { return nil }
        try self.init(id: id, content: Self.decodedContent(json: contentJSON, id: id))
    }

    /// The body a structured segment carries when its `Content` fails to
    /// encode.
    ///
    /// A single `_encodingFailed` flag. No router `Content` decodes from it,
    /// so a read of that segment throws instead of returning wrong content.
    static var encodingFailureContentJSON: String { #"{"_encodingFailed":true}"# }

    /// Encodes `content` to `GeneratedContent`, or logs and returns the
    /// ``encodingFailureContentJSON`` marker.
    ///
    /// Both paths parse through ``OrderPreservingGeneratedContentDecoder``,
    /// the same decoder a rebuild reads the persisted body with.
    /// `GeneratedContent` compares equal whatever the key order, but
    /// `Transcript.StructuredSegment` does not, so a body parsed in the SDK's
    /// arbitrary dictionary order would never equal its restored twin's.
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

    /// Parses `json` with its document key order intact, through the same
    /// ``OrderPreservingGeneratedContentDecoder`` a rebuild reads the
    /// persisted body with — see ``generatedContent(from:id:)``.
    ///
    /// - Parameter json: The body JSON to parse.
    /// - Returns: The parsed body, keys in document order.
    /// - Throws: Whatever the decoder throws for invalid JSON.
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

/// The schema names of the router's own ``PersistableStructuredSegment``
/// types.
///
/// ``SegmentPayload/contentByteCount`` reads this set: these segments carry
/// bookkeeping for a reader of the recording, and the router synthesizes the
/// model-visible part of the same entry as separate `.text` segments, so the
/// size estimate must not count the bookkeeping twice. See
/// ``SegmentPayload/contentByteCount`` for what counting it did to a fold.
enum RouterSegmentSchemaNames {
    /// Every schema name the router itself writes.
    static let all: Set<String> = [
        CompactionSegment.schemaName,
        OperationEventSegment.schemaName,
    ]
}
