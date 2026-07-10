import Foundation

/// The structural mirror of one `FoundationModels.Transcript.Entry`.
///
/// Apple's SDK transcript has exactly six entry cases — `.instructions`,
/// `.prompt`, `.toolCalls`, `.toolOutput`, `.response`, `.reasoning` — and each
/// carries its own payload shape (segments, tool definitions, tool calls,
/// asset ids, a reasoning signature, generation options, a response format).
/// `TranscriptEntryPayload` is one struct wide enough to carry any of those
/// shapes: a ``TranscriptEvent`` of the matching ``TranscriptEvent/Kind``
/// populates only the fields its entry kind uses and leaves the rest `nil`.
///
/// This is schema only — mapping a real `Transcript.Entry` into this shape
/// (and back) is a downstream concern; this type exists so the on-disk format
/// can hold that mapping's output once it is wired in.
///
/// `contentRemoved` distinguishes two reasons a payload might carry no
/// content: recorded at ``RecordingLevel/metadataOnly`` (content was stripped
/// by design, `contentRemoved == true`) versus not yet mapped or genuinely
/// empty (`contentRemoved == false`). Downstream reconstruction uses this to
/// refuse a stripped payload with a typed error instead of silently rebuilding
/// an empty entry. The field defaults to `false` and decodes as `false` when
/// absent, so it does not need to exist in older payloads.
public struct TranscriptEntryPayload: Sendable, Codable, Equatable {
    /// Apple's own `Transcript.Entry.id` for the mirrored entry.
    public let entryId: String

    /// Whether this payload's content was stripped by the recording level
    /// (``RecordingLevel/metadataOnly``) rather than never populated.
    ///
    /// Decodes as `false` when the key is absent, so v1-shaped and pre-gating
    /// payloads default to "not stripped."
    public let contentRemoved: Bool

    /// The entry's segments, in order — `.instructions`, `.prompt`,
    /// `.toolOutput`, `.response`, and `.reasoning` all carry segments;
    /// `.toolCalls` does not.
    public let segments: [SegmentPayload]?

    /// The tool definitions declared on an `.instructions` entry.
    public let toolDefinitions: [ToolDefinitionPayload]?

    /// The tool calls requested by a `.toolCalls` entry.
    public let toolCalls: [ToolCallPayload]?

    /// The tool name a `.toolOutput` entry answers.
    public let toolName: String?

    /// The asset ids attached to a `.response` entry.
    public let assetIds: [String]?

    /// The opaque reasoning signature carried by a `.reasoning` entry, when
    /// the model provided one.
    public let signature: Data?

    /// The introspectable slice of a `.prompt` entry's `GenerationOptions`.
    public let options: GenerationOptionsPayload?

    /// The name of a `.prompt` entry's `Transcript.ResponseFormat`, when the
    /// format was built from a named `Generable` type.
    public let responseFormatName: String?

    /// The JSON-encoded `GenerationSchema` backing a `.prompt` entry's
    /// `Transcript.ResponseFormat` — what makes the format rebuildable, since
    /// `ResponseFormat` has no `init(name:)`, only `init(schema:)`.
    public let responseFormatSchemaJSON: String?

    /// Creates an entry payload.
    ///
    /// - Parameters:
    ///   - entryId: Apple's own `Transcript.Entry.id`.
    ///   - contentRemoved: Whether content was stripped by the recording
    ///     level rather than never populated; defaults to `false`.
    ///   - segments: The entry's segments, or `nil` for entry kinds that carry
    ///     none (`.toolCalls`).
    ///   - toolDefinitions: The tool definitions on an `.instructions` entry,
    ///     or `nil`.
    ///   - toolCalls: The tool calls on a `.toolCalls` entry, or `nil`.
    ///   - toolName: The tool name on a `.toolOutput` entry, or `nil`.
    ///   - assetIds: The asset ids on a `.response` entry, or `nil`.
    ///   - signature: The reasoning signature on a `.reasoning` entry, or `nil`.
    ///   - options: The introspectable generation options on a `.prompt`
    ///     entry, or `nil`.
    ///   - responseFormatName: The named response format on a `.prompt` entry,
    ///     or `nil`.
    ///   - responseFormatSchemaJSON: The JSON-encoded schema backing a
    ///     `.prompt` entry's response format, or `nil`.
    public init(
        entryId: String,
        contentRemoved: Bool = false,
        segments: [SegmentPayload]? = nil,
        toolDefinitions: [ToolDefinitionPayload]? = nil,
        toolCalls: [ToolCallPayload]? = nil,
        toolName: String? = nil,
        assetIds: [String]? = nil,
        signature: Data? = nil,
        options: GenerationOptionsPayload? = nil,
        responseFormatName: String? = nil,
        responseFormatSchemaJSON: String? = nil
    ) {
        self.entryId = entryId
        self.contentRemoved = contentRemoved
        self.segments = segments
        self.toolDefinitions = toolDefinitions
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.assetIds = assetIds
        self.signature = signature
        self.options = options
        self.responseFormatName = responseFormatName
        self.responseFormatSchemaJSON = responseFormatSchemaJSON
    }

    private enum CodingKeys: String, CodingKey {
        case entryId
        case contentRemoved
        case segments
        case toolDefinitions
        case toolCalls
        case toolName
        case assetIds
        case signature
        case options
        case responseFormatName
        case responseFormatSchemaJSON
    }

    /// Decodes a payload, defaulting ``contentRemoved`` to `false` when the
    /// key is absent — the compatibility rule that lets payloads recorded
    /// before this field existed keep decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try container.decode(String.self, forKey: .entryId)
        contentRemoved = try container.decodeIfPresent(Bool.self, forKey: .contentRemoved) ?? false
        segments = try container.decodeIfPresent([SegmentPayload].self, forKey: .segments)
        toolDefinitions = try container.decodeIfPresent([ToolDefinitionPayload].self, forKey: .toolDefinitions)
        toolCalls = try container.decodeIfPresent([ToolCallPayload].self, forKey: .toolCalls)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        assetIds = try container.decodeIfPresent([String].self, forKey: .assetIds)
        signature = try container.decodeIfPresent(Data.self, forKey: .signature)
        options = try container.decodeIfPresent(GenerationOptionsPayload.self, forKey: .options)
        responseFormatName = try container.decodeIfPresent(String.self, forKey: .responseFormatName)
        responseFormatSchemaJSON = try container.decodeIfPresent(String.self, forKey: .responseFormatSchemaJSON)
    }
}

/// One `Transcript.Segment`, mirrored losslessly.
///
/// Apple's SDK has four segment cases: `.text`, `.structure`, `.attachment`,
/// and `.custom` (an existential over the `CustomSegment` protocol). Three
/// map directly to concrete fields; `.custom` carries a type-discriminator
/// string plus its content encoded to JSON, since `CustomSegment.Content` is
/// protocol-guaranteed `Codable` — persisting a custom segment is always
/// lossless, only *rebuilding* it needs a registry (a downstream concern).
public enum SegmentPayload: Sendable, Codable, Equatable {
    /// A `Transcript.TextSegment`: plain text content.
    case text(id: String, content: String)
    /// A `Transcript.StructuredSegment`: named-schema content, carried as its
    /// `GeneratedContent.jsonString`.
    case structure(id: String, schemaName: String, contentJSON: String)
    /// A `Transcript.AttachmentSegment`: a label and, when the in-memory
    /// attachment has one, its URL. `url` is `nil` when the attachment cannot
    /// be represented as a URL (e.g. in-memory image bytes with no backing
    /// file).
    case attachment(id: String, label: String?, url: String?)
    /// A `Transcript.Segment.custom` existential: its own `id`, a stable
    /// type-discriminator string identifying the concrete conforming type,
    /// its `content` encoded to JSON, and the flattened GUI convenience
    /// description alongside — not the fidelity carrier.
    case custom(id: String, typeDiscriminator: String, contentJSON: String, description: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case content
        case schemaName
        case contentJSON
        case label
        case url
        case typeDiscriminator
        case description
    }

    private enum SegmentType: String, Codable {
        case text
        case structure
        case attachment
        case custom
    }

    /// Decodes a segment from its flattened representation, switching on the
    /// `type` discriminator key to decode the case-specific fields.
    ///
    /// Synthesized `Codable` can't consume this shape: it expects each case's
    /// payload nested under a single key named after the case (e.g.
    /// `{"text": {...}}`), but this format is a flat `type` field plus sibling
    /// keys. This mirrors ``encode(to:)``, which produces that same flat
    /// shape by switching on `self`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(SegmentType.self, forKey: .type) {
        case .text:
            self = .text(
                id: try container.decode(String.self, forKey: .id),
                content: try container.decode(String.self, forKey: .content)
            )
        case .structure:
            self = .structure(
                id: try container.decode(String.self, forKey: .id),
                schemaName: try container.decode(String.self, forKey: .schemaName),
                contentJSON: try container.decode(String.self, forKey: .contentJSON)
            )
        case .attachment:
            self = .attachment(
                id: try container.decode(String.self, forKey: .id),
                label: try container.decodeIfPresent(String.self, forKey: .label),
                url: try container.decodeIfPresent(String.self, forKey: .url)
            )
        case .custom:
            self = .custom(
                id: try container.decode(String.self, forKey: .id),
                typeDiscriminator: try container.decode(String.self, forKey: .typeDiscriminator),
                contentJSON: try container.decode(String.self, forKey: .contentJSON),
                description: try container.decodeIfPresent(String.self, forKey: .description)
            )
        }
    }

    /// Encodes a segment by hand, writing a `type` discriminator alongside
    /// each case's associated values.
    ///
    /// Synthesized `Codable` can't produce this shape: Swift's compiler-
    /// generated enum encoding nests each case's payload under a single key
    /// named after the case (e.g. `{"text": {...}}`), but this format needs a
    /// flat `type` field plus sibling keys so on-disk JSON stays uniform and
    /// human-inspectable across all four segment kinds. This mirrors
    /// ``init(from:)``, which decodes by switching on that same `type` key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let id, let content):
            try container.encode(SegmentType.text, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(content, forKey: .content)
        case .structure(let id, let schemaName, let contentJSON):
            try container.encode(SegmentType.structure, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(schemaName, forKey: .schemaName)
            try container.encode(contentJSON, forKey: .contentJSON)
        case .attachment(let id, let label, let url):
            try container.encode(SegmentType.attachment, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(url, forKey: .url)
        case .custom(let id, let typeDiscriminator, let contentJSON, let description):
            try container.encode(SegmentType.custom, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(typeDiscriminator, forKey: .typeDiscriminator)
            try container.encode(contentJSON, forKey: .contentJSON)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }
}

/// A `Transcript.Instructions`-entry tool definition: `name`, `description`,
/// and its parameters schema encoded to JSON (`GenerationSchema` is `Codable`
/// per the SDK interface, so the schema itself round-trips through its own
/// encoding).
public struct ToolDefinitionPayload: Sendable, Codable, Equatable {
    /// The tool's declared name.
    public let name: String
    /// The tool's declared description.
    public let description: String
    /// The tool's parameters `GenerationSchema`, encoded to JSON.
    public let parametersSchemaJSON: String

    /// Creates a tool definition payload.
    ///
    /// - Parameters:
    ///   - name: The tool's declared name.
    ///   - description: The tool's declared description.
    ///   - parametersSchemaJSON: The tool's parameters schema, encoded to JSON.
    public init(name: String, description: String, parametersSchemaJSON: String) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }
}

/// One `Transcript.ToolCalls`-entry call: `id`, `toolName`, and its arguments
/// (a `GeneratedContent`, carried via its `jsonString` round-trip).
public struct ToolCallPayload: Sendable, Codable, Equatable {
    /// The tool call's own id.
    public let id: String
    /// The name of the tool being called.
    public let toolName: String
    /// The call's arguments, encoded via `GeneratedContent.jsonString`.
    public let argumentsJSON: String

    /// Creates a tool call payload.
    ///
    /// - Parameters:
    ///   - id: The tool call's own id.
    ///   - toolName: The name of the tool being called.
    ///   - argumentsJSON: The call's arguments, as `GeneratedContent.jsonString`.
    public init(id: String, toolName: String, argumentsJSON: String) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// The introspectable slice of a `.prompt` entry's `GenerationOptions`.
///
/// `GenerationOptions` is not itself `Codable`, so this payload carries only
/// `temperature` and `maximumResponseTokens`. `sampling: SamplingMode?` is
/// omitted too — not because it lacks public introspection (`SamplingMode.kind`
/// is public and `Equatable` at macOS 27+), but because this schema has no
/// field for it; the loss is documented and deliberate (see plan.md "Honest
/// fidelity scope" and ``TranscriptEntryMapper``).
public struct GenerationOptionsPayload: Sendable, Codable, Equatable {
    /// The sampling temperature, when set.
    public let temperature: Double?
    /// The maximum number of response tokens, when set.
    public let maximumResponseTokens: Int?

    /// Creates a generation options payload.
    ///
    /// - Parameters:
    ///   - temperature: The sampling temperature, or `nil`.
    ///   - maximumResponseTokens: The maximum response tokens, or `nil`.
    public init(temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
    }
}

// MARK: - Gating: metadataOnly stripping and full-level redaction

/// Both `GatingRecorder` operations below act on the payload's content-bearing
/// fields only — the recorder-facing seam is ``TranscriptEvent/Partial/mapBody(_:)``,
/// which calls these methods on ``TranscriptEvent/Partial/entry``.
extension TranscriptEntryPayload {
    /// Returns a copy with every content-bearing field emptied, keeping shape:
    /// ``entryId``, segment ids and case tags, custom-segment
    /// ``SegmentPayload/custom(id:typeDiscriminator:contentJSON:description:)``'s
    /// `typeDiscriminator`, ``toolName``, and every array's element count
    /// (``segments``, ``toolDefinitions``, ``toolCalls``, ``assetIds``) all
    /// survive; only the content each element carries is removed.
    ///
    /// ``assetIds`` keeps its element *count* — asset identifiers are
    /// themselves considered content, so each id is blanked to an empty
    /// string rather than dropped, preserving the array's length as the
    /// "how many assets" shape fact ``RecordingLevel/metadataOnly`` promises
    /// to keep.
    ///
    /// ``options`` and ``responseFormatName`` are not content — generation
    /// configuration and a format's declared name, not user- or model-authored
    /// text — so both pass through unchanged.
    ///
    /// Marks ``contentRemoved`` `true`, so reconstruction can refuse a
    /// stripped payload with a typed error instead of silently rebuilding an
    /// empty entry.
    ///
    /// - Returns: A shape-only copy with `contentRemoved == true`.
    func strippingContent() -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: entryId,
            contentRemoved: true,
            segments: segments?.map { $0.strippingContent() },
            toolDefinitions: toolDefinitions?.map { $0.strippingContent() },
            toolCalls: toolCalls?.map { $0.strippingContent() },
            toolName: toolName,
            assetIds: assetIds.map { ids in Array(repeating: "", count: ids.count) },
            signature: nil,
            options: options,
            responseFormatName: responseFormatName,
            responseFormatSchemaJSON: responseFormatSchemaJSON.map { _ in "" }
        )
    }

    /// Returns a copy with `transform` applied to every textual content site
    /// at ``RecordingLevel/full``: segment text/structure/custom content and
    /// custom descriptions (via ``SegmentPayload/redacted(with:)``) and
    /// tool-call arguments (via ``ToolCallPayload/redacted(with:)``).
    ///
    /// JSON-valued sites (``SegmentPayload/structure(id:schemaName:contentJSON:)``'s
    /// `contentJSON`, a custom segment's `contentJSON`, and a tool call's
    /// `argumentsJSON`) are redacted as opaque whole strings, exactly like any
    /// other text body — a hook that must keep JSON valid after redacting it
    /// is the caller's responsibility, consistent with the flattened `text`
    /// contract (see the "redact is applied verbatim" tests).
    ///
    /// Tool definitions, the response-format schema, the reasoning
    /// `signature`, and an attachment's `url` are declared/structural or
    /// opaque-binary data, not user- or model-authored text, so `transform`
    /// never touches them. ``contentRemoved`` is left as-is (`full` never
    /// strips).
    ///
    /// - Parameter transform: The redaction hook applied to each content site.
    /// - Returns: A copy with every textual content site redacted.
    func redacted(with transform: (String) -> String) -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: entryId,
            contentRemoved: contentRemoved,
            segments: segments?.map { $0.redacted(with: transform) },
            toolDefinitions: toolDefinitions,
            toolCalls: toolCalls?.map { $0.redacted(with: transform) },
            toolName: toolName,
            assetIds: assetIds,
            signature: signature,
            options: options,
            responseFormatName: responseFormatName,
            responseFormatSchemaJSON: responseFormatSchemaJSON
        )
    }
}

extension SegmentPayload {
    /// Returns a copy with this segment's content emptied, keeping its `id`
    /// and case — and, for ``custom(id:typeDiscriminator:contentJSON:description:)``,
    /// its `typeDiscriminator` — intact.
    ///
    /// - Returns: A shape-only copy of this segment.
    func strippingContent() -> SegmentPayload {
        switch self {
        case .text(let id, _):
            return .text(id: id, content: "")
        case .structure(let id, let schemaName, _):
            return .structure(id: id, schemaName: schemaName, contentJSON: "")
        case .attachment(let id, _, _):
            return .attachment(id: id, label: nil, url: nil)
        case .custom(let id, let typeDiscriminator, _, _):
            return .custom(id: id, typeDiscriminator: typeDiscriminator, contentJSON: "", description: nil)
        }
    }

    /// Returns a copy with `transform` applied to this segment's textual
    /// content sites: `.text`'s `content`, `.structure`'s `contentJSON` (as an
    /// opaque string), `.attachment`'s `label` (its `url` is untouched), and
    /// `.custom`'s `contentJSON` (as an opaque string) and `description`.
    ///
    /// - Parameter transform: The redaction hook applied to each content site.
    /// - Returns: A copy with this segment's textual content sites redacted.
    func redacted(with transform: (String) -> String) -> SegmentPayload {
        switch self {
        case .text(let id, let content):
            return .text(id: id, content: transform(content))
        case .structure(let id, let schemaName, let contentJSON):
            return .structure(id: id, schemaName: schemaName, contentJSON: transform(contentJSON))
        case .attachment(let id, let label, let url):
            return .attachment(id: id, label: label.map(transform), url: url)
        case .custom(let id, let typeDiscriminator, let contentJSON, let description):
            return .custom(
                id: id,
                typeDiscriminator: typeDiscriminator,
                contentJSON: transform(contentJSON),
                description: description.map(transform)
            )
        }
    }
}

extension ToolDefinitionPayload {
    /// Returns a copy with `description` and `parametersSchemaJSON` emptied,
    /// keeping `name` intact.
    ///
    /// - Returns: A shape-only copy of this tool definition.
    func strippingContent() -> ToolDefinitionPayload {
        ToolDefinitionPayload(name: name, description: "", parametersSchemaJSON: "")
    }
}

extension ToolCallPayload {
    /// Returns a copy with `argumentsJSON` emptied, keeping `id` and
    /// `toolName` intact.
    ///
    /// - Returns: A shape-only copy of this tool call.
    func strippingContent() -> ToolCallPayload {
        ToolCallPayload(id: id, toolName: toolName, argumentsJSON: "")
    }

    /// Returns a copy with `transform` applied to `argumentsJSON` as an
    /// opaque string, keeping `id` and `toolName` untouched.
    ///
    /// - Parameter transform: The redaction hook applied to `argumentsJSON`.
    /// - Returns: A copy with `argumentsJSON` redacted.
    func redacted(with transform: (String) -> String) -> ToolCallPayload {
        ToolCallPayload(id: id, toolName: toolName, argumentsJSON: transform(argumentsJSON))
    }
}
