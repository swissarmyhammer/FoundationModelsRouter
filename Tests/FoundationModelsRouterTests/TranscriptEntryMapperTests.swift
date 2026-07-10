import CoreImage
import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Tests for ``TranscriptEntryMapper``, the single place a real
/// `FoundationModels.Transcript.Entry` is converted to/from the on-disk
/// ``TranscriptEntryPayload`` mirror.
///
/// Every one of the six entry kinds is round-tripped (`event(from:)` then
/// `entry(from:kind:)`) and asserted equal to the original on every
/// representable field. A second group of tests exercises the documented,
/// deliberate degradations (sampling, metadata, type-built response formats,
/// URL-less attachments) and a third exercises reconstruction failures
/// (stripped content, missing fields, bad JSON, unregistered custom
/// segments).
@Suite("TranscriptEntryMapper: round-trip Transcript.Entry to/from TranscriptEntryPayload")
struct TranscriptEntryMapperTests {
    // MARK: - Sample @Generable types (pure schema derivation, no GPU/model)

    @Generable
    struct Weather: Equatable {
        @Guide(description: "The temperature in Fahrenheit.")
        var temperature: Int
    }

    @Generable
    struct SearchArgs: Equatable {
        @Guide(description: "The search query.")
        var query: String
    }

    // MARK: - Test-only PersistableCustomSegment conformer

    private struct Note: Codable, Equatable, Sendable {
        var body: String
    }

    private struct NoteSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
        let id: String
        let content: Note

        init(id: String, content: Note) {
            self.id = id
            self.content = content
        }

        var description: String { "Note: \(content.body)" }
    }

    // MARK: - Per-kind round trips

    @Test("an .instructions entry round-trips through event(from:) and entry(from:kind:)")
    func instructionsRoundTrips() throws {
        let original = Transcript.Entry.instructions(
            Transcript.Instructions(
                id: "instr-1",
                segments: [.text(Transcript.TextSegment(id: "s1", content: "you are a helpful assistant"))],
                toolDefinitions: [
                    Transcript.ToolDefinition(
                        name: "search",
                        description: "search the web",
                        parameters: SearchArgs.generationSchema
                    )
                ]
            )
        )
        try assertRoundTrips(original, kind: .instructions)
    }

    @Test("a .prompt entry round-trips through event(from:) and entry(from:kind:)")
    func promptRoundTrips() throws {
        let original = Transcript.Entry.prompt(
            Transcript.Prompt(
                id: "prompt-1",
                segments: [.text(Transcript.TextSegment(id: "s1", content: "what's the weather"))],
                options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 512),
                responseFormat: Transcript.ResponseFormat(schema: Weather.generationSchema)
            )
        )
        try assertRoundTrips(original, kind: .prompt)
    }

    @Test("a .toolCalls entry round-trips through event(from:) and entry(from:kind:)")
    func toolCallsRoundTrips() throws {
        let original = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1",
                        toolName: "search",
                        arguments: try GeneratedContent(json: #"{"query":"weather"}"#)
                    )
                ]
            )
        )
        try assertRoundTrips(original, kind: .toolCalls)
    }

    @Test("a .toolOutput entry round-trips through event(from:) and entry(from:kind:)")
    func toolOutputRoundTrips() throws {
        let original = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: "output-1",
                toolName: "search",
                segments: [.text(Transcript.TextSegment(id: "s1", content: "sunny, 72F"))]
            )
        )
        try assertRoundTrips(original, kind: .toolOutput)
    }

    @Test("a .response entry round-trips through event(from:) and entry(from:kind:)")
    func responseRoundTrips() throws {
        let original = Transcript.Entry.response(
            Transcript.Response(
                id: "response-1",
                assetIDs: ["asset-1", "asset-2"],
                segments: [.text(Transcript.TextSegment(id: "s1", content: "it's sunny and 72F"))]
            )
        )
        try assertRoundTrips(original, kind: .response)
    }

    @Test("a .reasoning entry round-trips through event(from:) and entry(from:kind:)")
    func reasoningRoundTrips() throws {
        let original = Transcript.Entry.reasoning(
            Transcript.Reasoning(
                id: "reasoning-1",
                segments: [.text(Transcript.TextSegment(id: "s1", content: "the user wants the weather"))],
                signature: Data("sig-bytes".utf8)
            )
        )
        try assertRoundTrips(original, kind: .reasoning)
    }

    @Test("a .reasoning entry with a nil signature round-trips")
    func reasoningWithNilSignatureRoundTrips() throws {
        let original = Transcript.Entry.reasoning(
            Transcript.Reasoning(
                id: "reasoning-2",
                segments: [.text(Transcript.TextSegment(id: "s1", content: "thinking"))],
                signature: nil
            )
        )
        try assertRoundTrips(original, kind: .reasoning)
    }

    // MARK: - text flattening

    @Test("event(from:) flattens joined text-segment content into text")
    func textIsFlattenedFromTextSegments() {
        let entry = Transcript.Entry.response(
            Transcript.Response(
                assetIDs: [],
                segments: [
                    .text(Transcript.TextSegment(content: "line one")),
                    .text(Transcript.TextSegment(content: "line two")),
                ]
            )
        )
        let (_, _, text) = TranscriptEntryMapper.event(from: entry)
        #expect(text == "line one\nline two")
    }

    @Test("event(from:) reports nil text for a .toolCalls entry, which carries no segments")
    func toolCallsHasNilText() {
        let entry = Transcript.Entry.toolCalls(Transcript.ToolCalls(id: "calls-1", []))
        let (_, _, text) = TranscriptEntryMapper.event(from: entry)
        #expect(text == nil)
    }

    @Test("event(from:) reports nil text when a response has no text segments")
    func nilTextWhenNoTextSegments() {
        let entry = Transcript.Entry.response(Transcript.Response(assetIDs: [], segments: []))
        let (_, _, text) = TranscriptEntryMapper.event(from: entry)
        #expect(text == nil)
    }

    // MARK: - Structured segment: GeneratedContent.jsonString semantics

    @Test("a structured segment's GeneratedContent round-trips through jsonString semantics")
    func structuredSegmentPreservesGeneratedContentSemantics() throws {
        let originalContent = try GeneratedContent(json: #"{"temperature":72}"#)
        let original = Transcript.Entry.response(
            Transcript.Response(
                assetIDs: [],
                segments: [.structure(Transcript.StructuredSegment(id: "s1", schemaName: "Weather", content: originalContent))]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .response(let rebuiltResponse) = rebuilt,
            case .structure(let rebuiltSegment) = rebuiltResponse.segments.first
        else {
            Issue.record("expected a rebuilt .response entry with a .structure segment")
            return
        }
        let originalValue = try originalContent.value(Weather.self)
        let rebuiltValue = try rebuiltSegment.content.value(Weather.self)
        #expect(originalValue == rebuiltValue)
    }

    // MARK: - Custom segments: registered round-trip

    @Test("event(from:) encodes a custom segment without needing a registry")
    func customSegmentEncodesWithoutRegistry() {
        let segment = NoteSegment(id: "n1", content: Note(body: "hello"))
        let entry = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.custom(segment)])
        )
        let (_, payload, _) = TranscriptEntryMapper.event(from: entry)
        guard case .custom(let id, let discriminator, let contentJSON, let description) = payload.segments?.first else {
            Issue.record("expected a .custom segment payload")
            return
        }
        #expect(id == "n1")
        #expect(discriminator == NoteSegment.typeDiscriminator)
        #expect(description == segment.description)
        let decodedContent = try? JSONDecoder().decode(Note.self, from: Data(contentJSON.utf8))
        #expect(decodedContent == Note(body: "hello"))
    }

    @Test("a registered custom segment round-trips to an equal .custom segment")
    func registeredCustomSegmentRoundTrips() throws {
        let segment = NoteSegment(id: "n1", content: Note(body: "hello"))
        let entry = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.custom(segment)])
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)

        var registry = CustomSegmentRegistry()
        registry.register(NoteSegment.self)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind, registry: registry)

        guard case .response(let rebuiltResponse) = rebuilt,
            case .custom(let rebuiltSegment) = rebuiltResponse.segments.first,
            let rebuiltNote = rebuiltSegment as? NoteSegment
        else {
            Issue.record("expected a rebuilt .response entry with a .custom NoteSegment")
            return
        }
        #expect(rebuiltNote == segment)
    }

    @Test("rebuilding a custom segment with an unregistered discriminator throws, naming the discriminator")
    func unregisteredCustomSegmentThrows() throws {
        let segment = NoteSegment(id: "n1", content: Note(body: "hello"))
        let entry = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.custom(segment)])
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)

        #expect(throws: TranscriptEntryReconstructionError.unregisteredCustomSegmentType(discriminator: NoteSegment.typeDiscriminator)) {
            try TranscriptEntryMapper.entry(from: payload, kind: kind)
        }
    }

    @Test("PersistableCustomSegment's default typeDiscriminator is the type's fully-qualified name")
    func defaultTypeDiscriminatorIsFullyQualifiedName() {
        #expect(NoteSegment.typeDiscriminator == String(reflecting: NoteSegment.self))
    }

    // MARK: - Documented degradations

    @Test("GenerationOptions.sampling is dropped on rebuild")
    func samplingModeIsDropped() throws {
        let original = Transcript.Entry.prompt(
            Transcript.Prompt(
                id: "prompt-1",
                segments: [.text(Transcript.TextSegment(content: "hi"))],
                options: GenerationOptions(samplingMode: .greedy, temperature: 0.5, maximumResponseTokens: 100)
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .prompt(let rebuiltPrompt) = rebuilt else {
            Issue.record("expected a rebuilt .prompt entry")
            return
        }
        #expect(rebuiltPrompt.options.temperature == 0.5)
        #expect(rebuiltPrompt.options.maximumResponseTokens == 100)
        #expect(rebuiltPrompt.options.samplingMode == nil)
    }

    @Test("a Response's metadata dictionary is dropped on rebuild")
    func responseMetadataIsDropped() throws {
        let original = Transcript.Entry.response(
            Transcript.Response(
                metadata: ["k": "v"],
                segments: [.text(Transcript.TextSegment(content: "hi"))]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .response(let rebuiltResponse) = rebuilt else {
            Issue.record("expected a rebuilt .response entry")
            return
        }
        // The rebuilder uses the assetIDs-based initializer (there is no
        // public initializer that accepts both `assetIDs:` and `metadata:`
        // together), so `.metadata` synthesizes an `"assetIDs"` entry rather
        // than reporting truly empty — the assertion that matters is that the
        // *original's own* custom metadata key never survives the round trip.
        #expect(rebuiltResponse.metadata["k"] == nil)
    }

    @Test("a Prompt's metadata dictionary is dropped on rebuild")
    func promptMetadataIsDropped() throws {
        let original = Transcript.Entry.prompt(
            Transcript.Prompt(
                metadata: ["k": "v"],
                segments: [.text(Transcript.TextSegment(content: "hi"))]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .prompt(let rebuiltPrompt) = rebuilt else {
            Issue.record("expected a rebuilt .prompt entry")
            return
        }
        #expect(rebuiltPrompt.metadata.isEmpty)
    }

    @Test("a Prompt's contextOptions are dropped on rebuild — TranscriptEntryPayload has no field for them")
    func contextOptionsAreDropped() throws {
        let originalPrompt = Transcript.Prompt(
            segments: [.text(Transcript.TextSegment(content: "hi"))],
            contextOptions: ContextOptions(includeSchemaInPrompt: false, reasoningLevel: .deep)
        )
        // Sanity check: the original prompt's contextOptions really are non-default.
        #expect(originalPrompt.contextOptions != ContextOptions())

        let original = Transcript.Entry.prompt(originalPrompt)
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .prompt(let rebuiltPrompt) = rebuilt else {
            Issue.record("expected a rebuilt .prompt entry")
            return
        }
        #expect(rebuiltPrompt.contextOptions == ContextOptions())
    }

    @Test("a Reasoning's metadata dictionary is dropped on rebuild")
    func reasoningMetadataIsDropped() throws {
        let original = Transcript.Entry.reasoning(
            Transcript.Reasoning(
                metadata: ["k": "v"],
                segments: [.text(Transcript.TextSegment(content: "thinking"))]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .reasoning(let rebuiltReasoning) = rebuilt else {
            Issue.record("expected a rebuilt .reasoning entry")
            return
        }
        #expect(rebuiltReasoning.metadata.isEmpty)
    }

    @Test("a ToolCall's metadata dictionary is dropped on rebuild")
    func toolCallMetadataIsDropped() throws {
        let original = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1",
                        metadata: ["k": "v"],
                        toolName: "search",
                        arguments: try GeneratedContent(json: "{}")
                    )
                ]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .toolCalls(let rebuiltCalls) = rebuilt else {
            Issue.record("expected a rebuilt .toolCalls entry")
            return
        }
        #expect(rebuiltCalls.first?.metadata.isEmpty == true)
    }

    @Test("a ResponseFormat originally built from a Generable type rebuilds in schema form")
    func typeBuiltResponseFormatRebuildsInSchemaForm() throws {
        let original = Transcript.Entry.prompt(
            Transcript.Prompt(
                id: "prompt-1",
                segments: [.text(Transcript.TextSegment(content: "hi"))],
                responseFormat: Transcript.ResponseFormat(type: Weather.self)
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .prompt(let rebuiltPrompt) = rebuilt, let rebuiltFormat = rebuiltPrompt.responseFormat else {
            Issue.record("expected a rebuilt .prompt entry with a responseFormat")
            return
        }
        // The name still round-trips...
        #expect(rebuiltFormat.name == Transcript.ResponseFormat(type: Weather.self).name)
        // ...and the schema JSON the mapper persisted structurally matches a
        // fresh encode of the rebuilt format's own schema (schema-form, not
        // the original type-built form) — compared as parsed JSON values
        // (object-key order is not part of `GenerationSchema`'s encoded
        // identity, only its structure).
        guard case .schema(let rebuiltSchema) = rebuiltFormat.kind,
            let persistedSchemaJSON = payload.responseFormatSchemaJSON
        else {
            Issue.record("expected the rebuilt responseFormat's kind to be .schema, and a persisted schema JSON")
            return
        }
        let rebuiltSchemaJSON = try JSONEncoder().encode(rebuiltSchema)
        let persistedValue = try JSONDecoder().decode(JSONValue.self, from: Data(persistedSchemaJSON.utf8))
        let rebuiltValue = try JSONDecoder().decode(JSONValue.self, from: rebuiltSchemaJSON)
        #expect(persistedValue == rebuiltValue)
    }

    @Test("an attachment with a nil ImageAttachment.url degrades on rebuild to a labeled text segment")
    func urlLessAttachmentDegradesToLabeledText() throws {
        let ciImage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let imageAttachment = Transcript.ImageAttachment(ciImage, orientation: nil)
        #expect(imageAttachment.url == nil)

        let original = Transcript.Entry.response(
            Transcript.Response(
                assetIDs: [],
                segments: [
                    .attachment(
                        Transcript.AttachmentSegment(id: "a1", content: .image(imageAttachment), label: "a red pixel")
                    )
                ]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .response(let rebuiltResponse) = rebuilt, case .text(let textSegment) = rebuiltResponse.segments.first
        else {
            Issue.record("expected the rebuilt segment to degrade to .text")
            return
        }
        #expect(textSegment.id == "a1")
        #expect(textSegment.content == "a red pixel")
    }

    @Test("an attachment with a non-nil ImageAttachment.url round-trips as an attachment segment")
    func urlBackedAttachmentRoundTrips() throws {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let original = Transcript.Entry.response(
            Transcript.Response(
                assetIDs: [],
                segments: [
                    .attachment(
                        Transcript.AttachmentSegment(
                            id: "a1",
                            content: .image(Transcript.ImageAttachment(imageURL: url)),
                            label: "photo"
                        )
                    )
                ]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .response(let rebuiltResponse) = rebuilt, case .attachment(let attachmentSegment) = rebuiltResponse.segments.first
        else {
            Issue.record("expected the rebuilt segment to stay an .attachment")
            return
        }
        #expect(attachmentSegment.label == "photo")
        guard case .image(let rebuiltImage) = attachmentSegment.content else {
            Issue.record("expected an .image attachment")
            return
        }
        #expect(rebuiltImage.url == url)
    }

    // MARK: - Reconstruction failures

    @Test("reconstruction refuses a contentRemoved payload with a typed error")
    func contentRemovedThrows() {
        let payload = TranscriptEntryPayload(entryId: "e1", contentRemoved: true)
        #expect(throws: TranscriptEntryReconstructionError.contentRemoved(entryId: "e1")) {
            try TranscriptEntryMapper.entry(from: payload, kind: .response)
        }
    }

    @Test("reconstruction throws a typed error when a required field is missing (no segments)")
    func missingSegmentsThrows() {
        let payload = TranscriptEntryPayload(entryId: "e1")
        #expect(throws: TranscriptEntryReconstructionError.missingRequiredField(entryId: "e1", field: "segments")) {
            try TranscriptEntryMapper.entry(from: payload, kind: .response)
        }
    }

    @Test("reconstruction throws a typed error when toolCalls is missing for a .toolCalls-kind payload")
    func missingToolCallsThrows() {
        let payload = TranscriptEntryPayload(entryId: "e1")
        #expect(throws: TranscriptEntryReconstructionError.missingRequiredField(entryId: "e1", field: "toolCalls")) {
            try TranscriptEntryMapper.entry(from: payload, kind: .toolCalls)
        }
    }

    @Test("reconstruction throws a typed error for undecodable response-format schema JSON")
    func invalidResponseFormatSchemaJSONThrows() {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [.text(id: "s1", content: "hi")],
            responseFormatName: "Bogus",
            responseFormatSchemaJSON: "not json"
        )
        #expect(throws: (any Error).self) {
            try TranscriptEntryMapper.entry(from: payload, kind: .prompt)
        }
    }

    @Test("reconstruction throws a typed error for undecodable tool-call arguments JSON")
    func invalidToolCallArgumentsJSONThrows() {
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            toolCalls: [ToolCallPayload(id: "c1", toolName: "search", argumentsJSON: "not json")]
        )
        #expect(throws: (any Error).self) {
            try TranscriptEntryMapper.entry(from: payload, kind: .toolCalls)
        }
    }

    @Test("reconstruction throws unsupportedKind for a router-only kind")
    func unsupportedKindThrows() {
        let payload = TranscriptEntryPayload(entryId: "e1")
        #expect(throws: TranscriptEntryReconstructionError.unsupportedKind(.session)) {
            try TranscriptEntryMapper.entry(from: payload, kind: .session)
        }
    }

    // MARK: - Helpers

    /// Maps `original` through `event(from:)` then rebuilds it through
    /// `entry(from:kind:)`, asserting the rebuilt entry equals the original —
    /// the round-trip contract every non-degraded field combination must
    /// satisfy.
    private func assertRoundTrips(_ original: Transcript.Entry, kind: TranscriptEvent.Kind) throws {
        let (mappedKind, payload, _) = TranscriptEntryMapper.event(from: original)
        #expect(mappedKind == kind)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: mappedKind)
        #expect(rebuilt == original)
    }
}
