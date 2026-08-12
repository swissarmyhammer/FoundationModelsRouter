import Foundation
import FoundationModels
import os

/// The logger the mapper reports unknown-case degradations to — a future
/// SDK's entry or segment case being recorded as, or rebuilt from, the
/// best-effort text carriers (``TranscriptEvent/Kind/unknown``,
/// ``SegmentPayload/unknown(id:description:)``).
private let transcriptEntryMapperLogger = makeModuleLogger(category: "Recording")

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
    /// ``TranscriptEvent/Kind/embedding``, ``TranscriptEvent/Kind/divergence``)
    /// or the legacy
    /// ``TranscriptEvent/Kind/toolCall`` — none of which correspond to a real
    /// `FoundationModels.Transcript.Entry` case, so there is nothing to
    /// rebuild.
    case unsupportedKind(TranscriptEvent.Kind)
}

/// A failure encoding a value for persistence — the record-time counterpart
/// of ``TranscriptEntryReconstructionError``.
///
/// Thrown by ``TranscriptEntryMapper``'s `jsonString(for:context:)` when a
/// value cannot be encoded to JSON (realistically, a custom segment's
/// user-provided `content`; the SDK's own `Codable` values are expected to
/// always encode). ``TranscriptEntryMapper/event(from:)`` and
/// ``TranscriptEntryMapper/segmentPayload(_:)`` never propagate it — they
/// catch it, log it at fault level, and persist the documented empty-string
/// sentinel — so the failure is loud at record time without breaking the
/// best-effort record path.
enum TranscriptEntryEncodingError: Error, Equatable {
    /// Encoding the value described by `context` failed with `underlying`.
    case encodingFailed(context: String, underlying: String)
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
/// already-landed schema (``GenerationOptionsPayload``) carries only
/// `temperature`/`maximumResponseTokens`/`toolCallingMode`, with no field
/// for it; the same is true of `Prompt.contextOptions` (27+), which has no
/// corresponding payload field either. `GenerationOptions.toolCallingMode`
/// round-trips through its public `kind` (``ToolCallingModePayload``); a
/// `kind` case a future SDK adds records as *no* mode, with a logged
/// warning. The existential `metadata` dictionaries on
/// `Prompt`/`ToolCall`/`Response`/`Reasoning` are dropped for the same
/// payload-schema reason — and a rebuilt `.response` entry with a non-empty
/// persisted asset-id list *gains* one: `Transcript.Response(id:assetIDs:segments:)`,
/// the only initializer that accepts asset ids, synthesizes a
/// `metadata["assetIDs"]` key the original entry may never have carried;
/// that synthesis is contract, pinned by test. A response with an *empty*
/// persisted asset-id list rebuilds through the metadata-less
/// `Transcript.Response(id:segments:)` initializer instead, so it carries no
/// synthesized key — the shape a live generated response with no asset ids
/// has (also pinned by test). A live tool call's `arguments` carry a
/// `GenerationID`, and `GenerationID`'s only public constructor is `init()`
/// (a fresh random id, not `Codable`), so no persisted form can rebuild the
/// same id: rebuilt tool-call arguments always carry a nil id, a permanent
/// degradation. The arguments' *property order* is not part of that loss —
/// every rebuilt `GeneratedContent` keeps the key order its persisted JSON
/// carries, via ``OrderPreservingGeneratedContentDecoder``. A
/// `Transcript.ResponseFormat` originally built from a `Generable` *type*
/// (`ResponseFormat(type:)`) rebuilds in schema form
/// (`ResponseFormat(schema:)` is the only rebuildable initializer, and its
/// `name` derives from the schema — the persisted
/// ``TranscriptEntryPayload/responseFormatName`` is the reader-facing copy,
/// the one response-format fact that survives `metadataOnly` stripping); a
/// payload carrying a format *name* but no schema JSON (the shape a future
/// `ResponseFormat.Kind` case would record) rebuilds without a response
/// format, with a logged warning naming the lost format. An attachment whose
/// `ImageAttachment.url` is `nil` (an in-memory image with no backing file —
/// the only URL-based rebuild path is `ImageAttachment(imageURL:)`) degrades
/// on rebuild to a text segment carrying the attachment's label, never a
/// throw. `.custom` segments are **not** on this list — they round-trip via
/// ``CustomSegmentRegistry``; only their persisted *description* is a reader
/// convenience the rebuild never consumes, because the conforming type's own
/// computed `description` is authoritative (pinned by test).
///
/// **Record-time encode failure** is loud, not silent: `jsonString(for:context:)`
/// throws the typed ``TranscriptEntryEncodingError`` at the cause, and the
/// never-throwing record path (``event(from:)``, ``segmentPayload(_:)``)
/// catches it, logs it at fault level, and persists the empty-string
/// sentinel in the affected JSON field. The empty string can never decode as
/// valid content, so restoring that field always throws
/// ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)``
/// instead of silently rebuilding wrong content.
///
/// **Unknown future SDK cases** are the last documented degradation: an entry
/// or segment case a future SDK adds after this mapper was written records as
/// the ``TranscriptEvent/Kind/unknown`` kind or the
/// ``SegmentPayload/unknown(id:description:)`` carrier — the value's `id`
/// plus its `description` as best-effort text — with a logged warning naming
/// the unrecognized case, never a crash. Rebuild degrades the carrier to a
/// `.text` segment (or, for the `.unknown` kind, a text-only `.response`
/// entry); the case's exact structure is lost until the mapper learns it.
/// See plan.md's "Honest fidelity scope".
public enum TranscriptEntryMapper {
    // MARK: - Encode: Transcript.Entry -> TranscriptEntryPayload

    /// Maps a real transcript entry to its on-disk payload.
    ///
    /// Never throws: every persisted field is either read directly off the
    /// SDK value or produced by a `Codable`/`jsonString` conversion. When a
    /// conversion *does* fail — realistically only a custom segment's
    /// user-provided `content`, since the SDK's own `Codable` values encode
    /// reliably — the typed ``TranscriptEntryEncodingError`` is caught here,
    /// logged at fault level, and the affected JSON field persists the
    /// documented empty-string sentinel (see the type doc's "Record-time
    /// encode failure" contract) rather than propagating a throw onto the
    /// best-effort record path.
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

    /// Rebuilds a real transcript entry from its on-disk payload.
    ///
    /// - Parameters:
    ///   - payload: The structural payload to rebuild from.
    ///   - kind: Which of the six `Transcript.Entry` cases to rebuild, or
    ///     ``TranscriptEvent/Kind/unknown`` for the documented text-only
    ///     degradation.
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
                    segments: try requiredSegments(payload, registry: registry)
                )
            )
        case .session, .embedding, .divergence, .toolCall:
            throw TranscriptEntryReconstructionError.unsupportedKind(kind)
        }
    }

    // MARK: - Per-case rebuilders

    private static func rebuildInstructions(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Instructions {
        let segments = try requiredSegments(payload, registry: registry)
        let toolDefPayloads = try requireField(payload.toolDefinitions, "toolDefinitions", entryId: payload.entryId)
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
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.ToolOutput {
        try rebuildSegmentedEntry(payload, registry: registry, field: \.toolName, fieldName: "toolName") {
            id, segments, toolName in
            Transcript.ToolOutput(id: id, toolName: toolName, segments: segments)
        }
    }

    private static func rebuildResponse(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Response {
        try rebuildSegmentedEntry(payload, registry: registry, field: \.assetIds, fieldName: "assetIds") {
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
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> Transcript.Reasoning {
        let segments = try requiredSegments(payload, registry: registry)
        return Transcript.Reasoning(id: payload.entryId, segments: segments, signature: payload.signature)
    }

    /// Rebuilds a segments-carrying entry that requires exactly one other
    /// payload field, sharing the "fetch segments, require the field,
    /// construct" shape common to ``rebuildToolOutput`` and
    /// ``rebuildResponse`` — those two rebuilders differ only in which
    /// payload field they require (`toolName` vs `assetIds`) and how they
    /// pass it to their entry's initializer.
    ///
    /// - Parameters:
    ///   - payload: The structural payload to rebuild from.
    ///   - registry: Passed through to segment reconstruction.
    ///   - field: The single required payload field the entry needs beyond
    ///     its segments.
    ///   - fieldName: The field's name, used in the thrown error when it is
    ///     `nil`.
    ///   - construct: Builds the entry from its id, rebuilt segments, and the
    ///     required field's unwrapped value.
    private static func rebuildSegmentedEntry<Field, Entry>(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry,
        field: KeyPath<TranscriptEntryPayload, Field?>,
        fieldName: String,
        construct: (String, [Transcript.Segment], Field) -> Entry
    ) throws -> Entry {
        let segments = try requiredSegments(payload, registry: registry)
        let value = try requireField(payload[keyPath: field], fieldName, entryId: payload.entryId)
        return construct(payload.entryId, segments, value)
    }

    /// Returns `payload.segments` rebuilt into real `Transcript.Segment`
    /// values, or throws ``TranscriptEntryReconstructionError/missingRequiredField(entryId:field:)``
    /// when `payload.segments` is `nil` — every entry kind that carries
    /// segments (every kind but `.toolCalls`) requires this field.
    private static func requiredSegments(
        _ payload: TranscriptEntryPayload,
        registry: CustomSegmentRegistry
    ) throws -> [Transcript.Segment] {
        let segmentPayloads = try requireField(payload.segments, "segments", entryId: payload.entryId)
        return try segmentPayloads.map { try rebuildSegment($0, registry: registry) }
    }

    /// Returns `value` unwrapped, or throws
    /// ``TranscriptEntryReconstructionError/missingRequiredField(entryId:field:)``
    /// naming `fieldName` when it is `nil` — the shared shape behind every
    /// "this entry kind requires this payload field to rebuild" check above.
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

    /// Maps one real transcript segment to its on-disk payload.
    ///
    /// Exposed beyond `event(from:)`'s internal use so a caller building a
    /// segment that was never part of a live `Transcript.Entry` — e.g.
    /// ``RoutedSessionActor`` wrapping a drained ``OperationEvent`` in an
    /// ``OperationEventSegment`` to append onto an already-mapped `.prompt`
    /// entry's payload — reuses the exact same encoding (discriminator
    /// resolution, content JSON, description) rather than duplicating it.
    ///
    /// - Parameter segment: The segment to map.
    /// - Returns: The segment's on-disk payload.
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
        case .custom(let custom):
            return customSegmentPayload(custom)
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
            contentJSON: jsonStringOrSentinel(for: segment.content, context: "custom segment \(segment.id) content"),
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
            // The persisted description is deliberately not read here: the
            // conforming type's own computed `description` is authoritative,
            // and the registry rebuilds the segment from its `id` and
            // `contentJSON` alone (see the documented degradations above).
            return try registry.rebuildSegment(discriminator: typeDiscriminator, id: id, contentJSON: contentJSON)

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

    /// Maps a live `GenerationOptions.ToolCallingMode` to its on-disk mirror
    /// via its public `kind` — the documented `toolCallingMode` round-trip's
    /// encode side.
    ///
    /// A `kind` case a future SDK adds records as `nil` (no mode), with a
    /// logged warning naming the degradation — the same never-crash rule as
    /// the unknown entry/segment carriers.
    ///
    /// - Parameter mode: The live tool-calling mode, or `nil`.
    /// - Returns: The mode's on-disk mirror, or `nil`.
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

    /// Maps a persisted tool-calling mode back to the live SDK value — the
    /// documented `toolCallingMode` round-trip's rebuild side.
    ///
    /// - Parameter payload: The persisted mode, or `nil` (also what a
    ///   recording written before the field existed decodes as).
    /// - Returns: The live tool-calling mode, or `nil`.
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

    /// The JSON-encoded `GenerationSchema` backing `format`, regardless of
    /// whether `format` was built via `ResponseFormat(type:)` or
    /// `ResponseFormat(schema:)` — `Kind` has exactly one case, `.schema`, so
    /// both constructors converge on the same representation here.
    private static func responseFormatSchemaJSON(_ format: Transcript.ResponseFormat) -> String? {
        guard case .schema(let schema) = format.kind else { return nil }
        return jsonStringOrSentinel(for: schema, context: "response format schema")
    }

    // MARK: - Text flattening

    /// The joined content of every `.text` segment in `segments`, in order,
    /// or `nil` if there are none — the flattened GUI/redaction convenience
    /// body ``TranscriptEvent/text`` carries.
    private static func flattenedText(_ segments: [SegmentPayload]) -> String? {
        let contents = textContents(segments)
        return contents.isEmpty ? nil : contents.joined(separator: "\n")
    }

    /// The joined content of every `.text` segment in `prompt`, in order and
    /// with nothing between them — the plain-text form
    /// ``RoutedSession/dispatchNextPrompt()`` hands
    /// ``LanguageModelSessionBackend/respond(to:maxTokens:)``/
    /// ``LanguageModelSessionBackend/respond(to:following:maxTokens:)`` for a
    /// queued prompt, since the backend's generation surface takes a `String`,
    /// not a `Transcript.Prompt`.
    ///
    /// Shares one segment extraction with the recording-side
    /// `flattenedText(_:)` above — the same `.text` filter over the same
    /// ``SegmentPayload`` mapping ``event(from:)`` applies to a live
    /// `.prompt` entry — so the two cannot drift on *what* counts as text.
    /// They deliberately differ on the two things that are not shared:
    ///
    /// - **No separator.** The recording side joins with a newline for a
    ///   human-readable body; a submitted prompt is the literal string the
    ///   model receives, so nothing may be inserted into it.
    /// - **`""`, never `nil`.** Non-text segments (e.g. a `.custom` segment)
    ///   are silently skipped, and a prompt carrying none of type `.text`
    ///   flattens to the empty string: queuing anything richer than plain text
    ///   is not supported by that dispatch path.
    ///
    /// - Parameter prompt: The queued prompt to flatten.
    /// - Returns: The joined text, or `""` if `prompt` carries no `.text`
    ///   segment.
    static func flattenedText(_ prompt: Transcript.Prompt) -> String {
        textContents(prompt.segments.map(segmentPayload)).joined()
    }

    /// The content of every `.text` segment in `segments`, in order — the one
    /// place the `.text` filter lives, read by both `flattenedText(_:)`
    /// overloads so the recording-side and prompt-side flattening agree on
    /// which segments carry text.
    ///
    /// - Parameter segments: The segments to read text content from.
    /// - Returns: One string per `.text` segment, in `segments` order; empty
    ///   when `segments` carries none.
    private static func textContents(_ segments: [SegmentPayload]) -> [String] {
        segments.compactMap { segment -> String? in
            guard case .text(_, let content) = segment else { return nil }
            return content
        }
    }

    // MARK: - JSON helpers

    /// Encodes `value` to a JSON string.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - context: What `value` is, named in the thrown error.
    /// - Returns: The encoded JSON string.
    /// - Throws: ``TranscriptEntryEncodingError/encodingFailed(context:underlying:)``
    ///   when the encode fails — the typed record-time error, thrown at the
    ///   cause instead of a silent sentinel.
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

    /// Encodes `value` to a JSON string on the never-throwing record path,
    /// degrading to the documented empty-string sentinel on failure.
    ///
    /// The seam between the throwing `jsonString(for:context:)` and the
    /// best-effort record path (``event(from:)``, ``segmentPayload(_:)``):
    /// the typed ``TranscriptEntryEncodingError`` is caught here and logged
    /// at fault level, at record time, and the field persists `""` — a value
    /// that can never decode as valid content, so restore refuses it with
    /// ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)``
    /// instead of rebuilding wrong content (see the type doc's "Record-time
    /// encode failure" contract).
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - context: What `value` is, named in the fault log.
    /// - Returns: The encoded JSON string, or `""` on encode failure.
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

    /// Decodes persisted `GeneratedContent` JSON with its document key order
    /// intact, via ``OrderPreservingGeneratedContentDecoder`` — a plain
    /// `GeneratedContent(json:)` parse reports a structure's property order
    /// in arbitrary dictionary order, and the live equality the rebuilt
    /// content must satisfy compares that order.
    ///
    /// - Parameters:
    ///   - json: The persisted JSON to decode.
    ///   - context: What the JSON is, named in the thrown error.
    private static func decodeGeneratedContent(_ json: String, context: String) throws -> GeneratedContent {
        do {
            return try OrderPreservingGeneratedContentDecoder.decode(json: json)
        } catch {
            throw TranscriptEntryReconstructionError.invalidJSON(context: context, underlying: String(describing: error))
        }
    }
}
