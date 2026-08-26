import Foundation

/// The structural mirror of one `FoundationModels.Transcript.Entry`.
///
/// One struct carries the payload of all six entry cases. A ``TranscriptEvent``
/// of a given ``TranscriptEvent/Kind`` sets only the fields its entry kind
/// uses and leaves the rest `nil`.
///
/// `contentRemoved` is `true` when ``RecordingLevel/metadataOnly`` stripped
/// the content. Reconstruction refuses a stripped payload with a typed error.
public struct TranscriptEntryPayload: Sendable, Codable, Equatable {
    /// Apple's own `Transcript.Entry.id` for the mirrored entry.
    let entryId: String

    /// `true` when ``RecordingLevel/metadataOnly`` stripped the content.
    /// Decodes as `false` when the key is absent.
    let contentRemoved: Bool

    /// The entry's segments, in order. `nil` for `.toolCalls`.
    public let segments: [SegmentPayload]?

    /// The tool definitions declared on an `.instructions` entry.
    let toolDefinitions: [ToolDefinitionPayload]?

    /// The tool calls requested by a `.toolCalls` entry.
    let toolCalls: [ToolCallPayload]?

    /// The tool name a `.toolOutput` entry answers.
    let toolName: String?

    /// The asset ids attached to a `.response` entry.
    let assetIds: [String]?

    /// The opaque reasoning signature of a `.reasoning` entry.
    let signature: Data?

    /// The introspectable slice of a `.prompt` entry's `GenerationOptions`.
    let options: GenerationOptionsPayload?

    /// The name of a `.prompt` entry's `Transcript.ResponseFormat`.
    let responseFormatName: String?

    /// The JSON-encoded `GenerationSchema` of a `.prompt` entry's
    /// `Transcript.ResponseFormat`.
    let responseFormatSchemaJSON: String?

    /// Creates an entry payload. Each field not given stays `nil`.
    init(
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

    /// Decodes a payload. ``contentRemoved`` defaults to `false` when absent.
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
/// `.text`, `.structure`, and `.attachment` mirror SDK cases. `.custom` is the
/// legacy carrier for the removed `Transcript.Segment.custom`; a reader
/// rebuilds it as `.structure`. `.unknown` carries a segment case from a
/// newer SDK; a reader degrades it to text.
public enum SegmentPayload: Sendable, Codable, Equatable {
    /// A `Transcript.TextSegment`: plain text content.
    case text(id: String, content: String)
    /// A `Transcript.StructuredSegment`: a schema name and its
    /// `GeneratedContent.jsonString`.
    case structure(id: String, schemaName: String, contentJSON: String)
    /// A `Transcript.AttachmentSegment`. `url` is `nil` when the attachment
    /// has no URL form.
    case attachment(id: String, label: String?, url: String?)
    /// A legacy `Transcript.Segment.custom`: a type discriminator, its content
    /// as JSON, and an optional description.
    case custom(id: String, typeDiscriminator: String, contentJSON: String, description: String?)
    /// A `Transcript.Segment` case this build does not know. Carries the SDK
    /// value's `description`.
    case unknown(id: String, description: String)

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
        case unknown
    }

    /// Decodes a segment from its flat form: a `type` key and sibling
    /// case-specific keys.
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
        case .unknown:
            self = .unknown(
                id: try container.decode(String.self, forKey: .id),
                description: try container.decode(String.self, forKey: .description)
            )
        }
    }

    /// Encodes a segment in its flat form: a `type` key and sibling
    /// case-specific keys.
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
        case .unknown(let id, let description):
            try container.encode(SegmentType.unknown, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(description, forKey: .description)
        }
    }
}

/// One tool definition of a `Transcript.Instructions` entry.
struct ToolDefinitionPayload: Sendable, Codable, Equatable {
    /// The tool's declared name.
    let name: String
    /// The tool's declared description.
    let description: String
    /// The tool's parameters `GenerationSchema`, encoded to JSON.
    let parametersSchemaJSON: String

    /// Creates a tool definition payload.
    init(name: String, description: String, parametersSchemaJSON: String) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }
}

/// One call of a `Transcript.ToolCalls` entry.
struct ToolCallPayload: Sendable, Codable, Equatable {
    /// The tool call's own id.
    let id: String
    /// The name of the tool being called.
    let toolName: String
    /// The call's arguments, encoded via `GeneratedContent.jsonString`.
    let argumentsJSON: String

    /// Creates a tool call payload.
    init(id: String, toolName: String, argumentsJSON: String) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// The on-disk mirror of `GenerationOptions.ToolCallingMode.Kind`, carried
/// as stable strings.
enum ToolCallingModePayload: String, Sendable, Codable, Equatable {
    /// Mirrors `GenerationOptions.ToolCallingMode.Kind.allowed`.
    case allowed
    /// Mirrors `GenerationOptions.ToolCallingMode.Kind.required`.
    case required
    /// Mirrors `GenerationOptions.ToolCallingMode.Kind.disallowed`.
    case disallowed
}

/// The introspectable slice of a `.prompt` entry's `GenerationOptions`:
/// `temperature`, `maximumResponseTokens`, and `toolCallingMode`. The schema
/// has no field for `sampling`.
struct GenerationOptionsPayload: Sendable, Codable, Equatable {
    /// The sampling temperature, when set.
    let temperature: Double?
    /// The maximum number of response tokens, when set.
    let maximumResponseTokens: Int?
    /// The tool-calling mode, when set. `nil` when absent from the recording.
    let toolCallingMode: ToolCallingModePayload?

    /// Creates a generation options payload.
    init(
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        toolCallingMode: ToolCallingModePayload? = nil
    ) {
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.toolCallingMode = toolCallingMode
    }
}

// MARK: - Content sizing

/// The total UTF-8 size, in bytes, of every non-`nil` string in `strings`.
private func utf8ByteCount(of strings: [String?]) -> Int {
    strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
}

extension TranscriptEntryPayload {
    /// The total UTF-8 size, in bytes, of the model-visible content of this
    /// payload. Ids, `"type"` discriminators, JSON punctuation, ``options``,
    /// and ``responseFormatName`` do not count.
    var contentByteCount: Int {
        utf8ByteCount(of: [toolName, responseFormatSchemaJSON])
            + utf8ByteCount(of: assetIds ?? [])
            + (signature?.count ?? 0)
            + (segments ?? []).reduce(0) { $0 + $1.contentByteCount }
            + (toolDefinitions ?? []).reduce(0) { $0 + $1.contentByteCount }
            + (toolCalls ?? []).reduce(0) { $0 + $1.contentByteCount }
    }
}

extension SegmentPayload {
    /// The total UTF-8 size, in bytes, of this segment's model-visible
    /// content. A router manifest segment (``RouterSegmentSchemaNames``) and
    /// a legacy `.custom` carrier count as zero.
    var contentByteCount: Int {
        switch self {
        case .text(_, let content):
            return utf8ByteCount(of: [content])
        case .structure(_, let schemaName, let contentJSON):
            guard !RouterSegmentSchemaNames.all.contains(schemaName) else { return 0 }
            return utf8ByteCount(of: [schemaName, contentJSON])
        case .attachment(_, let label, let url):
            return utf8ByteCount(of: [label, url])
        case .custom:
            return 0
        // An `.unknown` carrier counts its description: rebuild degrades it
        // to a `.text` segment holding exactly that string, so it is
        // model-visible on a reconstructed seed the same way `.text` content
        // is.
        case .unknown(_, let description):
            return utf8ByteCount(of: [description])
        }
    }
}

extension ToolDefinitionPayload {
    /// The total UTF-8 size, in bytes, of the name, description, and schema.
    var contentByteCount: Int {
        utf8ByteCount(of: [name, description, parametersSchemaJSON])
    }
}

extension ToolCallPayload {
    /// The total UTF-8 size, in bytes, of the tool name and arguments.
    var contentByteCount: Int {
        utf8ByteCount(of: [toolName, argumentsJSON])
    }
}

// MARK: - Gating: metadataOnly stripping and full-level redaction

/// Content gating for ``RecordingLevel/metadataOnly`` and ``RecordingLevel/full``.
extension TranscriptEntryPayload {
    /// Returns a copy with every content field emptied. Ids, case tags,
    /// array counts, ``toolName``, ``options``, and ``responseFormatName``
    /// stay. Sets ``contentRemoved`` to `true`.
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

    /// Returns a copy with `transform` applied to each segment text site and
    /// each tool-call `argumentsJSON`. JSON sites are transformed as opaque
    /// strings. Tool definitions, the schema, `signature`, and attachment
    /// URLs are not transformed.
    ///
    /// - Parameter transform: The redaction hook.
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

    /// Returns a copy with `additional` appended to ``segments``, in order.
    func appendingSegments(_ additional: [SegmentPayload]) -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: entryId,
            contentRemoved: contentRemoved,
            segments: (segments ?? []) + additional,
            toolDefinitions: toolDefinitions,
            toolCalls: toolCalls,
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
    /// The schema name and content JSON of a `.structure` segment or a legacy
    /// `.custom` carrier, or `nil` for any other segment.
    var persistedStructure: (schemaName: String, contentJSON: String)? {
        switch self {
        case .structure(_, let schemaName, let contentJSON):
            return (schemaName, contentJSON)
        case .custom(_, let typeDiscriminator, let contentJSON, _):
            return (typeDiscriminator, contentJSON)
        case .text, .attachment, .unknown:
            return nil
        }
    }

    /// Returns a copy with the content emptied. The `id`, case, and
    /// `typeDiscriminator` stay.
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
        case .unknown(let id, _):
            return .unknown(id: id, description: "")
        }
    }

    /// Returns a copy with `transform` applied to each text site. An
    /// attachment `url` is not transformed.
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
        case .unknown(let id, let description):
            return .unknown(id: id, description: transform(description))
        }
    }
}

extension ToolDefinitionPayload {
    /// Returns a copy with `description` and `parametersSchemaJSON` emptied.
    func strippingContent() -> ToolDefinitionPayload {
        ToolDefinitionPayload(name: name, description: "", parametersSchemaJSON: "")
    }
}

extension ToolCallPayload {
    /// Returns a copy with `argumentsJSON` emptied.
    func strippingContent() -> ToolCallPayload {
        ToolCallPayload(id: id, toolName: toolName, argumentsJSON: "")
    }

    /// Returns a copy with `transform` applied to `argumentsJSON` as an
    /// opaque string.
    func redacted(with transform: (String) -> String) -> ToolCallPayload {
        ToolCallPayload(id: id, toolName: toolName, argumentsJSON: transform(argumentsJSON))
    }
}
