import Foundation
import FoundationModels
import os

/// The logger that receives unknown-case degradation reports.
private let transcriptEntryMapperLogger = makeModuleLogger(category: "Recording")

/// A failure that occurs when a `Transcript.Entry` is rebuilt from a persisted ``TranscriptEntryPayload``.
public enum TranscriptEntryReconstructionError: Error, Equatable {
    /// The recording level removed the payload's content.
    case contentRemoved(entryId: String)

    /// The payload does not have a field that `kind` requires.
    case missingRequiredField(entryId: String, field: String)

    /// A persisted JSON string failed to decode.
    case invalidJSON(context: String, underlying: String)

    /// `kind` has no matching `Transcript.Entry` case.
    case unsupportedKind(TranscriptEvent.Kind)
}

/// A failure that occurs when a value is encoded for persistence.
enum TranscriptEntryEncodingError: Error, Equatable {
    /// Encoding the value described by `context` failed with `underlying`.
    case encodingFailed(context: String, underlying: String)
}

/// Maps a `FoundationModels.Transcript.Entry` to and from its on-disk
/// ``TranscriptEntryPayload`` mirror.
///
/// Known degradations: sampling, context options, and metadata are not
/// persisted; a format name with no schema rebuilds as no format; an
/// attachment with no URL rebuilds as text; an unknown SDK case records as
/// the `unknown` carrier and rebuilds as text. An encode failure persists
/// the empty-string sentinel.
public enum TranscriptEntryMapper {
    // MARK: - Encode: Transcript.Entry -> TranscriptEntryPayload

    /// Maps a transcript entry to its on-disk payload. Never throws.
    /// - Returns: The event kind, the payload, and the joined `.text` content, or `nil`.
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
                maximumResponseTokens: prompt.options.maximumResponseTokens,
                toolCallingMode: toolCallingModePayload(prompt.options.toolCallingMode)
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
            // mapper predates. A recording library must never turn an SDK
            // addition into a crash mid-turn, so the entry degrades: it
            // records as ``TranscriptEvent/Kind/unknown``, carrying the
            // entry's own id and its `description` as best-effort text. The
            // case's exact structure is lost until the mapper learns it (see
            // plan.md "Honest fidelity scope").
            let caseName = Mirror(reflecting: entry).children.first?.label ?? "unknown"
            transcriptEntryMapperLogger.warning(
                "TranscriptEntryMapper.event(from:): unrecognized Transcript.Entry case \(caseName, privacy: .public); recording as the unknown entry kind with best-effort text"
            )
            let description = String(describing: entry)
            let payload = TranscriptEntryPayload(
                entryId: entry.id,
                segments: [.unknown(id: entry.id, description: description)]
            )
            return (.unknown, payload, description)
        }
    }

    // MARK: - Decode: TranscriptEntryPayload -> Transcript.Entry

    /// Rebuilds a transcript entry from its on-disk payload.
    /// - Throws: ``TranscriptEntryReconstructionError`` when `payload` cannot be rebuilt.
    public static func entry(
        from payload: TranscriptEntryPayload,
        kind: TranscriptEvent.Kind
    ) throws -> Transcript.Entry {
        guard !payload.contentRemoved else {
            throw TranscriptEntryReconstructionError.contentRemoved(entryId: payload.entryId)
        }
        switch kind {
        case .instructions:
            return .instructions(try rebuildInstructions(payload))
        case .prompt:
            return .prompt(try rebuildPrompt(payload))
        case .toolCalls:
            return .toolCalls(try rebuildToolCalls(payload))
        case .toolOutput:
            return .toolOutput(try rebuildToolOutput(payload))
        case .response:
            return .response(try rebuildResponse(payload))
        case .reasoning:
            return .reasoning(try rebuildReasoning(payload))
        case .unknown:
            // The documented unknown-case degradation, rebuild side: the
            // carrier's best-effort text becomes a text-only entry, so
            // reconstruction stays total instead of crashing or dropping the
            // entry. `.response` is the one segments-carrying entry case
            // whose initializer needs nothing beyond an id and segments, so
            // it fabricates the least — through the metadata-less
            // initializer, which stamps no synthesized `metadata` key.
            transcriptEntryMapperLogger.warning(
                "TranscriptEntryMapper.entry(from:kind:): rebuilding unknown entry kind \(payload.entryId, privacy: .public) as a text-only response entry"
            )
            return .response(
                Transcript.Response(
                    id: payload.entryId,
                    segments: try requiredSegments(payload)
                )
            )
        case .session, .embedding, .divergence, .toolCall:
            throw TranscriptEntryReconstructionError.unsupportedKind(kind)
        }
    }

    // MARK: - Per-case rebuilders

    private static func rebuildInstructions(
        _ payload: TranscriptEntryPayload
    ) throws -> Transcript.Instructions {
        let segments = try requiredSegments(payload)
        let toolDefPayloads = try requireField(payload.toolDefinitions, "toolDefinitions", entryId: payload.entryId)
        let toolDefinitions = try toolDefPayloads.map { try toolDefinition($0, entryId: payload.entryId) }
        return Transcript.Instructions(id: payload.entryId, segments: segments, toolDefinitions: toolDefinitions)
    }

    private static func rebuildPrompt(
        _ payload: TranscriptEntryPayload
    ) throws -> Transcript.Prompt {
        let segments = try requiredSegments(payload)
        let options = GenerationOptions(
            samplingMode: nil,
            temperature: payload.options?.temperature,
            maximumResponseTokens: payload.options?.maximumResponseTokens,
            toolCallingMode: toolCallingMode(from: payload.options?.toolCallingMode)
        )
        var responseFormat: Transcript.ResponseFormat?
        if let schemaJSON = payload.responseFormatSchemaJSON {
            let schema = try decodeSchema(
                schemaJSON,
                context: "prompt \(payload.entryId) responseFormat schema"
            )
            responseFormat = Transcript.ResponseFormat(schema: schema)
        } else if let formatName = payload.responseFormatName {
            // The documented name-only degradation: the schema JSON is the
            // fidelity carrier `ResponseFormat(schema:)` needs, and no
            // initializer accepts a bare name. A payload carrying only the
            // name (the shape a future ResponseFormat.Kind case would
            // record) rebuilds without a response format, and the loss is
            // logged by name instead of passing silently.
            transcriptEntryMapperLogger.warning(
                "TranscriptEntryMapper.rebuildPrompt: prompt \(payload.entryId, privacy: .public) carries a response-format name \"\(formatName, privacy: .public)\" but no persisted schema; rebuilding without a response format"
            )
        }
        return Transcript.Prompt(
            id: payload.entryId,
            segments: segments,
            options: options,
            responseFormat: responseFormat
        )
    }

    private static func rebuildToolCalls(_ payload: TranscriptEntryPayload) throws -> Transcript.ToolCalls {
        let callPayloads = try requireField(payload.toolCalls, "toolCalls", entryId: payload.entryId)
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
        _ payload: TranscriptEntryPayload
    ) throws -> Transcript.ToolOutput {
        try rebuildSegmentedEntry(payload, field: \.toolName, fieldName: "toolName") {
            id, segments, toolName in
            Transcript.ToolOutput(id: id, toolName: toolName, segments: segments)
        }
    }

    private static func rebuildResponse(
        _ payload: TranscriptEntryPayload
    ) throws -> Transcript.Response {
        try rebuildSegmentedEntry(payload, field: \.assetIds, fieldName: "assetIds") {
            id, segments, assetIds in
            // A response with no asset ids rebuilds through the metadata-less
            // initializer: the assetIDs-based one stamps a synthesized
            // `metadata["assetIDs"]` key that a live generated response with
            // no asset ids never carries (see the type doc's documented
            // degradations).
            assetIds.isEmpty
                ? Transcript.Response(id: id, segments: segments)
                : Transcript.Response(id: id, assetIDs: assetIds, segments: segments)
        }
    }

    private static func rebuildReasoning(
        _ payload: TranscriptEntryPayload
    ) throws -> Transcript.Reasoning {
        let segments = try requiredSegments(payload)
        return Transcript.Reasoning(id: payload.entryId, segments: segments, signature: payload.signature)
    }

    /// Rebuilds a segments-carrying entry that requires one other payload field.
    private static func rebuildSegmentedEntry<Field, Entry>(
        _ payload: TranscriptEntryPayload,
        field: KeyPath<TranscriptEntryPayload, Field?>,
        fieldName: String,
        construct: (String, [Transcript.Segment], Field) -> Entry
    ) throws -> Entry {
        let segments = try requiredSegments(payload)
        let value = try requireField(payload[keyPath: field], fieldName, entryId: payload.entryId)
        return construct(payload.entryId, segments, value)
    }

    /// Returns `payload.segments` rebuilt into `Transcript.Segment` values.
    private static func requiredSegments(
        _ payload: TranscriptEntryPayload
    ) throws -> [Transcript.Segment] {
        let segmentPayloads = try requireField(payload.segments, "segments", entryId: payload.entryId)
        return try segmentPayloads.map { try rebuildSegment($0) }
    }

    /// Returns `value` unwrapped, or throws `missingRequiredField` naming `fieldName`.
    private static func requireField<T>(_ value: T?, _ fieldName: String, entryId: String) throws -> T {
        guard let value else {
            throw TranscriptEntryReconstructionError.missingRequiredField(entryId: entryId, field: fieldName)
        }
        return value
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

    /// Maps one transcript segment to its on-disk payload.
    static func segmentPayload(_ segment: Transcript.Segment) -> SegmentPayload {
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
        @unknown default:
            // See the matching `@unknown default` in `event(from:)` above: a
            // future SDK segment case this mapper predates. Degrade to the
            // ``SegmentPayload/unknown(id:description:)`` carrier instead of
            // crashing; the segment's `description` is the best-effort text
            // rebuild shows.
            let caseName = Mirror(reflecting: segment).children.first?.label ?? "unknown"
            transcriptEntryMapperLogger.warning(
                "TranscriptEntryMapper.segmentPayload(_:): unrecognized Transcript.Segment case \(caseName, privacy: .public); recording as the unknown segment carrier"
            )
            return .unknown(id: segment.id, description: segment.description)
        }
    }

    private static func rebuildSegment(
        _ payload: SegmentPayload
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
            // The legacy carrier, written before the SDK removed
            // `Transcript.Segment.custom`. Its type discriminator is the
            // schema name a ``PersistableStructuredSegment`` writes today, so
            // it rebuilds as the structured segment it now is. The persisted
            // description is deliberately not read: the typed value's own
            // `description` is authoritative.
            let content = try decodeGeneratedContent(
                contentJSON,
                context: "segment \(id) custom content"
            )
            return .structure(
                Transcript.StructuredSegment(id: id, schemaName: typeDiscriminator, content: content)
            )

        case .unknown(let id, let description):
            // The documented unknown-case degradation, rebuild side: the
            // carrier's best-effort text becomes a real `.text` segment, so
            // reconstruction stays total and the content stays visible.
            transcriptEntryMapperLogger.warning(
                "TranscriptEntryMapper: rebuilding unknown segment carrier \(id, privacy: .public) as a text segment"
            )
            return .text(Transcript.TextSegment(id: id, content: description))
        }
    }

    // MARK: - Tool call / definition mapping

    private static func toolDefinitionPayload(_ definition: Transcript.ToolDefinition) -> ToolDefinitionPayload {
        ToolDefinitionPayload(
            name: definition.name,
            description: definition.description,
            parametersSchemaJSON: jsonStringOrSentinel(
                for: definition.parameters,
                context: "tool \"\(definition.name)\" parameters schema"
            )
        )
    }

    private static func toolCallPayload(_ call: Transcript.ToolCall) -> ToolCallPayload {
        ToolCallPayload(id: call.id, toolName: call.toolName, argumentsJSON: call.arguments.jsonString)
    }

    // MARK: - Tool-calling mode

    /// Maps a tool-calling mode to its on-disk mirror. An unknown `kind` records as `nil`.
    private static func toolCallingModePayload(
        _ mode: GenerationOptions.ToolCallingMode?
    ) -> ToolCallingModePayload? {
        guard let mode else { return nil }
        switch mode.kind {
        case .allowed:
            return .allowed
        case .required:
            return .required
        case .disallowed:
            return .disallowed
        @unknown default:
            transcriptEntryMapperLogger.warning(
                "TranscriptEntryMapper: unrecognized GenerationOptions.ToolCallingMode kind; recording no tool-calling mode"
            )
            return nil
        }
    }

    /// Maps a persisted tool-calling mode back to the SDK value.
    private static func toolCallingMode(
        from payload: ToolCallingModePayload?
    ) -> GenerationOptions.ToolCallingMode? {
        guard let payload else { return nil }
        switch payload {
        case .allowed:
            return .allowed
        case .required:
            return .required
        case .disallowed:
            return .disallowed
        }
    }

    // MARK: - Response format

    /// The JSON-encoded `GenerationSchema` that backs `format`.
    private static func responseFormatSchemaJSON(_ format: Transcript.ResponseFormat) -> String? {
        guard case .schema(let schema) = format.kind else { return nil }
        return jsonStringOrSentinel(for: schema, context: "response format schema")
    }

    // MARK: - Text flattening

    /// The content of every `.text` segment in `segments`, joined with a newline, or `nil`.
    private static func flattenedText(_ segments: [SegmentPayload]) -> String? {
        let contents = textContents(segments)
        return contents.isEmpty ? nil : contents.joined(separator: "\n")
    }

    /// The content of every `.text` segment in `prompt`, joined with no separator.
    static func flattenedText(_ prompt: Transcript.Prompt) -> String {
        textContents(prompt.segments.map(segmentPayload)).joined()
    }

    /// One string per `.text` segment in `segments`, in order.
    private static func textContents(_ segments: [SegmentPayload]) -> [String] {
        segments.compactMap { segment -> String? in
            guard case .text(_, let content) = segment else { return nil }
            return content
        }
    }

    // MARK: - JSON helpers

    /// Encodes `value` to a JSON string.
    /// - Throws: ``TranscriptEntryEncodingError/encodingFailed(context:underlying:)``.
    static func jsonString<T: Encodable>(for value: T, context: String) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw TranscriptEntryEncodingError.encodingFailed(
                context: context,
                underlying: String(describing: error)
            )
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw TranscriptEntryEncodingError.encodingFailed(
                context: context,
                underlying: "encoded data is not valid UTF-8"
            )
        }
        return string
    }

    /// Encodes `value` to a JSON string, or logs a fault and returns `""` on failure.
    private static func jsonStringOrSentinel<T: Encodable>(for value: T, context: String) -> String {
        do {
            return try jsonString(for: value, context: context)
        } catch {
            transcriptEntryMapperLogger.fault(
                "TranscriptEntryMapper: \(String(describing: error), privacy: .public); persisting the empty-string sentinel for \(context, privacy: .public)"
            )
            return ""
        }
    }

    private static func decodeSchema(_ json: String, context: String) throws -> GenerationSchema {
        do {
            return try JSONDecoder().decode(GenerationSchema.self, from: Data(json.utf8))
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(context: context, underlying: String(describing: error))
        }
    }

    /// Decodes persisted `GeneratedContent` JSON with its key order intact.
    private static func decodeGeneratedContent(_ json: String, context: String) throws -> GeneratedContent {
        do {
            return try OrderPreservingGeneratedContentDecoder.decode(json: json)
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(context: context, underlying: String(describing: error))
        }
    }
}
