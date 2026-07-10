import Foundation
import FoundationModels

/// A failure reconstructing a `Transcript.Entry` from a persisted
/// ``TranscriptEntryPayload``.
///
/// ``TranscriptEntryMapper/entry(from:kind:registry:)`` throws one of these
/// rather than crashing or silently rebuilding an incomplete/incorrect entry
/// whenever a payload cannot be honestly turned back into the SDK value it
/// mirrors.
public enum TranscriptEntryReconstructionError: Error, Equatable {
    /// The payload's content was stripped by the recording level
    /// (``TranscriptEntryPayload/contentRemoved`` is `true`, e.g. recorded at
    /// `RecordingLevel.metadataOnly`) — reconstruction refuses rather than
    /// rebuilding an empty or fabricated entry.
    case contentRemoved(entryId: String)

    /// The payload is missing a field ``kind`` requires to rebuild its
    /// `Transcript.Entry` case (e.g. a `.toolCalls`-kind payload whose
    /// ``TranscriptEntryPayload/toolCalls`` array is `nil`).
    case missingRequiredField(entryId: String, field: String)

    /// A persisted JSON string — a `GenerationSchema`, a `GeneratedContent`,
    /// or tool-call arguments — failed to decode.
    case invalidJSON(context: String, underlying: String)

    /// A `.custom` segment's persisted type-discriminator has no
    /// corresponding type registered in the ``CustomSegmentRegistry`` passed
    /// to reconstruction.
    case unregisteredCustomSegmentType(discriminator: String)

    /// `kind` is a router-only kind (``TranscriptEvent/Kind/session``,
    /// ``TranscriptEvent/Kind/embedding``) or the legacy
    /// ``TranscriptEvent/Kind/toolCall`` — none of which correspond to a real
    /// `FoundationModels.Transcript.Entry` case, so there is nothing to
    /// rebuild.
    case unsupportedKind(TranscriptEvent.Kind)
}

/// Maps a real `FoundationModels.Transcript.Entry` to and from the on-disk
/// ``TranscriptEntryPayload`` mirror — the single place SDK entries are
/// converted to/from what ``TranscriptRecorder`` persists.
///
/// `Transcript.Entry` has exactly six cases (`.instructions`, `.prompt`,
/// `.toolCalls`, `.toolOutput`, `.response`, `.reasoning`; see plan.md's
/// "Transcript fidelity" section) and every one of them, plus every segment
/// case (`.text`, `.structure`, `.attachment`, `.custom`), is mapped here in
/// both directions.
///
/// **Documented, deliberate degradations** (each covered by a test rather
/// than silently assumed): `GenerationOptions.sampling` is dropped — not
/// because it lacks public introspection (`SamplingMode.kind` *is* public
/// and `Equatable` at macOS 27+), but because ``TranscriptEntryPayload``'s
/// already-landed schema (``GenerationOptionsPayload``) only carries
/// `temperature`/`maximumResponseTokens`, with no field for it; the same is
/// true of `Prompt.contextOptions` (27+), which has no corresponding payload
/// field either. The existential `metadata` dictionaries on
/// `Prompt`/`ToolCall`/`Response`/`Reasoning` are dropped for the same
/// payload-schema reason. A `Transcript.ResponseFormat` originally built from
/// a `Generable` *type* (`ResponseFormat(type:)`) rebuilds in schema form
/// (`ResponseFormat(schema:)` is the only rebuildable initializer); an
/// attachment whose `ImageAttachment.url` is `nil` (an in-memory image with
/// no backing file — the only URL-based rebuild path is
/// `ImageAttachment(imageURL:)`) degrades on rebuild to a text segment
/// carrying the attachment's label, never a throw. `.custom` segments are
/// **not** on this list — they round-trip via ``CustomSegmentRegistry``.
public enum TranscriptEntryMapper {
    // MARK: - Encode: Transcript.Entry -> TranscriptEntryPayload

    /// Maps a real transcript entry to its on-disk payload.
    ///
    /// Never throws: every persisted field is either read directly off the
    /// SDK value or produced by a `Codable`/`jsonString` conversion the SDK
    /// itself guarantees succeeds for a value it just handed back (a
    /// `GenerationSchema` or `GeneratedContent` the SDK produced, or a
    /// `CustomSegment.Content` the protocol guarantees is `Encodable`).
    ///
    /// - Parameter entry: The real transcript entry to persist.
    /// - Returns: The event ``TranscriptEvent/Kind`` this entry mirrors, its
    ///   structural payload, and the flattened text — the joined content of
    ///   every `.text` segment the entry carries, or `nil` for an entry kind
    ///   that carries no segments (`.toolCalls`) or none of type `.text`.
    public static func event(
        from entry: Transcript.Entry
    ) -> (kind: TranscriptEvent.Kind, payload: TranscriptEntryPayload, text: String?) {
        switch entry {
        case .instructions(let instructions):
            let segments = instructions.segments.map(segmentPayload)
            let payload = TranscriptEntryPayload(
                entryId: instructions.id,
                segments: segments,
                toolDefinitions: instructions.toolDefinitions.map(toolDefinitionPayload)
            )
            return (.instructions, payload, flattenedText(segments))

        case .prompt(let prompt):
            let segments = prompt.segments.map(segmentPayload)
            let options = GenerationOptionsPayload(
                temperature: prompt.options.temperature,
                maximumResponseTokens: prompt.options.maximumResponseTokens
            )
            let payload = TranscriptEntryPayload(
                entryId: prompt.id,
                segments: segments,
                options: options,
                responseFormatName: prompt.responseFormat?.name,
                responseFormatSchemaJSON: prompt.responseFormat.flatMap(responseFormatSchemaJSON)
            )
            return (.prompt, payload, flattenedText(segments))

        case .toolCalls(let toolCalls):
            let payload = TranscriptEntryPayload(
                entryId: toolCalls.id,
                toolCalls: toolCalls.map(toolCallPayload)
            )
            return (.toolCalls, payload, nil)

        case .toolOutput(let toolOutput):
            let segments = toolOutput.segments.map(segmentPayload)
            let payload = TranscriptEntryPayload(
                entryId: toolOutput.id,
                segments: segments,
                toolName: toolOutput.toolName
            )
            return (.toolOutput, payload, flattenedText(segments))

        case .response(let response):
            let segments = response.segments.map(segmentPayload)
            let payload = TranscriptEntryPayload(
                entryId: response.id,
                segments: segments,
                assetIds: response.assetIDs
            )
            return (.response, payload, flattenedText(segments))

        case .reasoning(let reasoning):
            let segments = reasoning.segments.map(segmentPayload)
            let payload = TranscriptEntryPayload(
                entryId: reasoning.id,
                segments: segments,
                signature: reasoning.signature
            )
            return (.reasoning, payload, flattenedText(segments))

        @unknown default:
            // A future SDK release added a `Transcript.Entry` case this
            // mapper predates — ``TranscriptEvent/Kind`` has no case for it
            // to map to. This is a genuine "the mapper needs updating for a
            // new SDK" situation, not a data problem a typed error is meant
            // to describe, so it fails loudly here rather than silently
            // discarding the entry or fabricating a kind that misdescribes it.
            fatalError("TranscriptEntryMapper.event(from:): unhandled Transcript.Entry case \(entry)")
        }
    }

    // MARK: - Decode: TranscriptEntryPayload -> Transcript.Entry

    /// Rebuilds a real transcript entry from its on-disk payload.
    ///
    /// - Parameters:
    ///   - payload: The structural payload to rebuild from.
    ///   - kind: Which of the six `Transcript.Entry` cases to rebuild.
    ///   - registry: The registered ``PersistableCustomSegment`` types a
    ///     `.custom` segment in `payload` may need to rebuild. Defaults to an
    ///     empty registry, so any `.custom` segment throws
    ///     ``TranscriptEntryReconstructionError/unregisteredCustomSegmentType(discriminator:)``
    ///     unless the caller supplies one.
    /// - Returns: The rebuilt entry.
    /// - Throws: ``TranscriptEntryReconstructionError`` when `payload` cannot
    ///   be honestly rebuilt — stripped content, a missing required field,
    ///   undecodable JSON, or an unregistered custom-segment discriminator.
    public static func entry(
        from payload: TranscriptEntryPayload,
        kind: TranscriptEvent.Kind,
        registry: CustomSegmentRegistry = CustomSegmentRegistry()
    ) throws -> Transcript.Entry {
        guard !payload.contentRemoved else {
            throw TranscriptEntryReconstructionError.contentRemoved(entryId: payload.entryId)
        }
        switch kind {
        case .instructions:
            return .instructions(try rebuildInstructions(payload, registry: registry))
        case .prompt:
            return .prompt(try rebuildPrompt(payload, registry: registry))
        case .toolCalls:
            return .toolCalls(try rebuildToolCalls(payload))
        case .toolOutput:
            return .toolOutput(try rebuildToolOutput(payload, registry: registry))
        case .response:
            return .response(try rebuildResponse(payload, registry: registry))
        case .reasoning:
            return .reasoning(try rebuildReasoning(payload, registry: registry))
        case .session, .embedding, .toolCall:
            throw TranscriptEntryReconstructionError.unsupportedKind(kind)
        }
    }

    // MARK: - Per-case rebuilders

    private static func rebuildInstructions(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Instructions {
        let segments = try requiredSegments(payload, registry: registry)
        guard let toolDefPayloads = payload.toolDefinitions else {
            throw TranscriptEntryReconstructionError.missingRequiredField(
                entryId: payload.entryId,
                field: "toolDefinitions"
            )
        }
        let toolDefinitions = try toolDefPayloads.map { try toolDefinition($0, entryId: payload.entryId) }
        return Transcript.Instructions(id: payload.entryId, segments: segments, toolDefinitions: toolDefinitions)
    }

    private static func rebuildPrompt(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Prompt {
        let segments = try requiredSegments(payload, registry: registry)
        let options = GenerationOptions(
            samplingMode: nil,
            temperature: payload.options?.temperature,
            maximumResponseTokens: payload.options?.maximumResponseTokens
        )
        var responseFormat: Transcript.ResponseFormat?
        if let schemaJSON = payload.responseFormatSchemaJSON {
            let schema = try decodeSchema(
                schemaJSON,
                context: "prompt \(payload.entryId) responseFormat schema"
            )
            responseFormat = Transcript.ResponseFormat(schema: schema)
        }
        return Transcript.Prompt(
            id: payload.entryId,
            segments: segments,
            options: options,
            responseFormat: responseFormat
        )
    }

    private static func rebuildToolCalls(_ payload: TranscriptEntryPayload) throws -> Transcript.ToolCalls {
        guard let callPayloads = payload.toolCalls else {
            throw TranscriptEntryReconstructionError.missingRequiredField(
                entryId: payload.entryId,
                field: "toolCalls"
            )
        }
        let calls = try callPayloads.map { call -> Transcript.ToolCall in
            let arguments = try decodeGeneratedContent(
                call.argumentsJSON,
                context: "toolCall \(call.id) arguments"
            )
            return Transcript.ToolCall(id: call.id, toolName: call.toolName, arguments: arguments)
        }
        return Transcript.ToolCalls(id: payload.entryId, calls)
    }

    private static func rebuildToolOutput(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.ToolOutput {
        let segments = try requiredSegments(payload, registry: registry)
        guard let toolName = payload.toolName else {
            throw TranscriptEntryReconstructionError.missingRequiredField(
                entryId: payload.entryId,
                field: "toolName"
            )
        }
        return Transcript.ToolOutput(id: payload.entryId, toolName: toolName, segments: segments)
    }

    private static func rebuildResponse(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Response {
        let segments = try requiredSegments(payload, registry: registry)
        guard let assetIds = payload.assetIds else {
            throw TranscriptEntryReconstructionError.missingRequiredField(
                entryId: payload.entryId,
                field: "assetIds"
            )
        }
        return Transcript.Response(id: payload.entryId, assetIDs: assetIds, segments: segments)
    }

    private static func rebuildReasoning(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Reasoning {
        let segments = try requiredSegments(payload, registry: registry)
        return Transcript.Reasoning(id: payload.entryId, segments: segments, signature: payload.signature)
    }

    /// Returns `payload.segments` rebuilt into real `Transcript.Segment`
    /// values, or throws ``TranscriptEntryReconstructionError/missingRequiredField(entryId:field:)``
    /// when `payload.segments` is `nil` — every entry kind that carries
    /// segments (every kind but `.toolCalls`) requires this field.
    private static func requiredSegments(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> [Transcript.Segment] {
        guard let segmentPayloads = payload.segments else {
            throw TranscriptEntryReconstructionError.missingRequiredField(entryId: payload.entryId, field: "segments")
        }
        return try segmentPayloads.map { try rebuildSegment($0, registry: registry) }
    }

    private static func toolDefinition(
        _ payload: ToolDefinitionPayload,
        entryId: String
    ) throws -> Transcript.ToolDefinition {
        let schema = try decodeSchema(
            payload.parametersSchemaJSON,
            context: "instructions \(entryId) tool \"\(payload.name)\" parameters schema"
        )
        return Transcript.ToolDefinition(name: payload.name, description: payload.description, parameters: schema)
    }

    // MARK: - Segment mapping

    private static func segmentPayload(_ segment: Transcript.Segment) -> SegmentPayload {
        switch segment {
        case .text(let text):
            return .text(id: text.id, content: text.content)
        case .structure(let structured):
            return .structure(id: structured.id, schemaName: structured.schemaName, contentJSON: structured.content.jsonString)
        case .attachment(let attachment):
            var url: String?
            if case .image(let image) = attachment.content {
                url = image.url?.absoluteString
            }
            return .attachment(id: attachment.id, label: attachment.label, url: url)
        case .custom(let custom):
            return customSegmentPayload(custom)
        @unknown default:
            // See the matching `@unknown default` in `event(from:)` above:
            // a future SDK segment case this mapper predates.
            fatalError("TranscriptEntryMapper: unhandled Transcript.Segment case \(segment)")
        }
    }

    /// Opens the `.custom` existential generically so the concrete
    /// conforming type's `Content` is known at the call site — needed to
    /// encode `content` and to check for a ``PersistableCustomSegment``
    /// conformance.
    private static func customSegmentPayload(_ segment: any Transcript.CustomSegment) -> SegmentPayload {
        encodeCustomSegment(segment)
    }

    private static func encodeCustomSegment<S: Transcript.CustomSegment>(_ segment: S) -> SegmentPayload {
        let discriminator = (S.self as? any PersistableCustomSegment.Type)?.typeDiscriminator
            ?? String(reflecting: S.self)
        return .custom(
            id: segment.id,
            typeDiscriminator: discriminator,
            contentJSON: jsonString(for: segment.content),
            description: segment.description
        )
    }

    private static func rebuildSegment(
        _ payload: SegmentPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Segment {
        switch payload {
        case .text(let id, let content):
            return .text(Transcript.TextSegment(id: id, content: content))

        case .structure(let id, let schemaName, let contentJSON):
            let content = try decodeGeneratedContent(contentJSON, context: "segment \(id) structure content")
            return .structure(Transcript.StructuredSegment(id: id, schemaName: schemaName, content: content))

        case .attachment(let id, let label, let url):
            // An in-memory attachment (no backing file, so no URL to persist)
            // has no rebuildable representation — `ImageAttachment`'s only
            // URL-based initializer is `init(imageURL:)`. Degrade to a text
            // segment carrying the label rather than throwing (see the
            // documented degradations above).
            if let url, let attachmentURL = URL(string: url) {
                let attachment = Transcript.ImageAttachment(imageURL: attachmentURL)
                return .attachment(Transcript.AttachmentSegment(id: id, content: .image(attachment), label: label))
            }
            return .text(Transcript.TextSegment(id: id, content: label ?? ""))

        case .custom(let id, let typeDiscriminator, let contentJSON, _):
            return try registry.rebuildSegment(discriminator: typeDiscriminator, id: id, contentJSON: contentJSON)
        }
    }

    // MARK: - Tool call / definition mapping

    private static func toolDefinitionPayload(_ definition: Transcript.ToolDefinition) -> ToolDefinitionPayload {
        ToolDefinitionPayload(
            name: definition.name,
            description: definition.description,
            parametersSchemaJSON: jsonString(for: definition.parameters)
        )
    }

    private static func toolCallPayload(_ call: Transcript.ToolCall) -> ToolCallPayload {
        ToolCallPayload(id: call.id, toolName: call.toolName, argumentsJSON: call.arguments.jsonString)
    }

    // MARK: - Response format

    /// The JSON-encoded `GenerationSchema` backing `format`, regardless of
    /// whether `format` was built via `ResponseFormat(type:)` or
    /// `ResponseFormat(schema:)` — `Kind` has exactly one case, `.schema`, so
    /// both constructors converge on the same representation here.
    private static func responseFormatSchemaJSON(_ format: Transcript.ResponseFormat) -> String? {
        guard case .schema(let schema) = format.kind else { return nil }
        return jsonString(for: schema)
    }

    // MARK: - Text flattening

    /// The joined content of every `.text` segment in `segments`, in order,
    /// or `nil` if there are none — the flattened GUI/redaction convenience
    /// body ``TranscriptEvent/text`` carries.
    private static func flattenedText(_ segments: [SegmentPayload]) -> String? {
        let textContents = segments.compactMap { segment -> String? in
            guard case .text(_, let content) = segment else { return nil }
            return content
        }
        return textContents.isEmpty ? nil : textContents.joined(separator: "\n")
    }

    // MARK: - JSON helpers

    /// Encodes `value` to a JSON string, or `""` on the near-impossible
    /// failure of encoding a value the SDK itself just produced.
    private static func jsonString<T: Encodable>(for value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    private static func decodeSchema(_ json: String, context: String) throws -> GenerationSchema {
        do {
            return try JSONDecoder().decode(GenerationSchema.self, from: Data(json.utf8))
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(context: context, underlying: String(describing: error))
        }
    }

    private static func decodeGeneratedContent(_ json: String, context: String) throws -> GeneratedContent {
        do {
            return try GeneratedContent(json: json)
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(context: context, underlying: String(describing: error))
        }
    }
}
