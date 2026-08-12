import CoreImage
import Foundation
import FoundationModels
import OSLog
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

    /// Content that always fails a `JSONEncoder` encode: `Double.infinity`
    /// is rejected by the default non-conforming-float strategy.
    private struct Unencodable: Codable, Equatable, Sendable {
        var value: Double
    }

    private struct UnencodableSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
        let id: String
        let content: Unencodable

        init(id: String, content: Unencodable) {
            self.id = id
            self.content = content
        }

        var description: String { "Unencodable: \(content.value)" }
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
                options: GenerationOptions(
                    temperature: 0.7,
                    maximumResponseTokens: 512,
                    toolCallingMode: .required
                ),
                responseFormat: Transcript.ResponseFormat(schema: Weather.generationSchema)
            )
        )
        try assertRoundTrips(original, kind: .prompt)
    }

    @Test("GenerationOptions.toolCallingMode persists in the payload and rebuilds, for every mode kind")
    func toolCallingModePersistsAndRebuilds() throws {
        let modes: [(GenerationOptions.ToolCallingMode, ToolCallingModePayload)] = [
            (.allowed, .allowed),
            (.required, .required),
            (.disallowed, .disallowed),
        ]
        for (mode, expectedPayloadMode) in modes {
            let original = Transcript.Entry.prompt(
                Transcript.Prompt(
                    id: "prompt-1",
                    segments: [.text(Transcript.TextSegment(content: "hi"))],
                    options: GenerationOptions(toolCallingMode: mode)
                )
            )
            let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
            #expect(payload.options?.toolCallingMode == expectedPayloadMode)

            let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
            guard case .prompt(let rebuiltPrompt) = rebuilt else {
                Issue.record("expected a rebuilt .prompt entry")
                return
            }
            #expect(rebuiltPrompt.options.toolCallingMode == mode)
        }
    }

    @Test("a .toolCalls entry round-trips through event(from:) and entry(from:kind:)")
    func toolCallsRoundTrips() throws {
        // Arguments are properties-built — the shape a live call's arguments
        // take (minus the unrepresentable GenerationID). A json-parsed
        // GeneratedContent never compares equal to the rebuilt live form.
        let original = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1",
                        toolName: "search",
                        arguments: GeneratedContent(properties: ["query": "weather"])
                    )
                ]
            )
        )
        try assertRoundTrips(original, kind: .toolCalls)
    }

    @Test("a multi-call .toolCalls entry round-trips with full entry equality, keeping both calls in order")
    func multiCallToolCallsRoundTrips() throws {
        // Two calls in one entry — the shape a model produces when it asks
        // for two independent calls at once. Distinct ids, names, and
        // arguments (properties-built, the live form), so a rebuild that
        // dropped, reordered, or merged calls cannot pass.
        let original = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: "calls-1",
                [
                    Transcript.ToolCall(
                        id: "call-1",
                        toolName: "search",
                        arguments: GeneratedContent(properties: ["query": "weather"])
                    ),
                    Transcript.ToolCall(
                        id: "call-2",
                        toolName: "lookup",
                        arguments: GeneratedContent(properties: ["value": "ONE"])
                    ),
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
        let entry = Transcript.Entry.response(Transcript.Response(segments: []))
        let (_, _, text) = TranscriptEntryMapper.event(from: entry)
        #expect(text == nil)
    }

    // MARK: - Structured segment: GeneratedContent.jsonString semantics

    @Test("a structured segment's GeneratedContent round-trips through jsonString semantics")
    func structuredSegmentPreservesGeneratedContentSemantics() throws {
        let originalContent = try GeneratedContent(json: #"{"temperature":72}"#)
        let original = Transcript.Entry.response(
            Transcript.Response(
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

    @Test("a structured segment keeps its GeneratedContent property order through the round trip")
    func structuredSegmentKeepsPropertyOrder() throws {
        // A live structured segment's content carries its property order
        // (`orderedKeys`), and `Transcript.StructuredSegment` equality
        // compares it. Keys in non-alphabetical insertion order, plus a
        // structure nested inside an array, so a rebuild that reads the
        // order from anywhere but the persisted JSON document cannot pass.
        let liveContent = GeneratedContent(properties: [
            "marker": "TWO",
            "alpha": "A",
            "steps": GeneratedContent(elements: [
                GeneratedContent(properties: ["z": "last", "a": "first"])
            ]),
        ])
        let original = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: "output-1",
                toolName: "marker",
                segments: [
                    .structure(
                        Transcript.StructuredSegment(id: "s1", schemaName: "Marker", content: liveContent))
                ]
            )
        )
        try assertRoundTrips(original, kind: .toolOutput)

        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
        guard case .toolOutput(let rebuiltOutput) = rebuilt,
            case .structure(let rebuiltSegment) = rebuiltOutput.segments.first,
            case .structure(_, let rebuiltKeys) = rebuiltSegment.content.kind
        else {
            Issue.record("expected a rebuilt .toolOutput entry with a .structure segment")
            return
        }
        #expect(rebuiltKeys == ["marker", "alpha", "steps"])
    }

    @Test("a .response with no asset ids rebuilds without a synthesized metadata key, equal to the live entry")
    func responseWithoutAssetIDsRebuildsWithoutSynthesizedMetadata() throws {
        // A live generated response with no asset ids carries no metadata at
        // all, so the rebuild must not stamp a `metadata["assetIDs"]` key
        // onto it — full entry equality holds, and the rebuilt metadata
        // dictionary stays empty.
        let original = Transcript.Entry.response(
            Transcript.Response(
                id: "response-1",
                segments: [.text(Transcript.TextSegment(id: "s1", content: "plain text answer"))]
            )
        )
        try assertRoundTrips(original, kind: .response)

        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)
        guard case .response(let rebuiltResponse) = rebuilt else {
            Issue.record("expected a rebuilt .response entry")
            return
        }
        #expect(rebuiltResponse.metadata.isEmpty)
    }

    @Test("a .response entry with mixed segments (text and structure) round-trips with full entry equality")
    func mixedSegmentEntryRoundTrips() throws {
        // Two different segment kinds inside one entry, so a rebuild that
        // dropped a segment, reordered them, or degraded one kind into
        // another cannot pass. An `.attachment` segment is deliberately not
        // in the mix: `Transcript.ImageAttachment`'s `==` compares the
        // identity of the per-instance image buffer it decodes into, so no
        // rebuilt attachment can ever equal its original —
        // ``urlBackedAttachmentRoundTrips()`` holds that segment kind to
        // every representable field instead.
        let original = Transcript.Entry.response(
            Transcript.Response(
                id: "response-1",
                segments: [
                    .text(Transcript.TextSegment(id: "s1", content: "here is the weather")),
                    .structure(
                        Transcript.StructuredSegment(
                            id: "s2",
                            schemaName: "Weather",
                            // Properties-built, the live form — a json-parsed
                            // GeneratedContent never compares equal to the
                            // rebuilt live form.
                            content: GeneratedContent(properties: ["temperature": 72])
                        )
                    ),
                ]
            )
        )
        try assertRoundTrips(original, kind: .response)
    }

    // MARK: - Custom segments: registered round-trip

    @Test("event(from:) encodes a custom segment without needing a registry")
    func customSegmentEncodesWithoutRegistry() {
        let segment = NoteSegment(id: "n1", content: Note(body: "hello"))
        let entry = Transcript.Entry.response(
            Transcript.Response(segments: [.custom(segment)])
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

    @Test("a registered custom segment round-trips with full entry equality, to the same concrete type")
    func registeredCustomSegmentRoundTrips() throws {
        let segment = NoteSegment(id: "n1", content: Note(body: "hello"))
        let entry = Transcript.Entry.response(
            Transcript.Response(segments: [.custom(segment)])
        )
        var registry = CustomSegmentRegistry()
        registry.register(NoteSegment.self)

        // Full `Transcript.Entry` equality, not a cherry-picked field
        // comparison, so the entry's id, asset ids, and segment list are all
        // held to the round trip too.
        try assertRoundTrips(entry, kind: .response, registry: registry)

        // And the rebuilt segment really is the registered concrete type,
        // not merely something that compares equal.
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
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
            Transcript.Response(segments: [.custom(segment)])
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

    @Test("a .custom segment's persisted description is not read at rebuild — the type's own description is authoritative")
    func customSegmentRebuildsWithTheTypesOwnDescription() throws {
        let original = NoteSegment(id: "n1", content: Note(body: "hello"))
        // A payload whose persisted description disagrees with what the
        // conforming type computes for the same content — the rebuilt segment
        // must carry the type's description, proving the persisted copy is a
        // reader convenience the rebuild never consumes.
        let doctored = TranscriptEntryPayload(
            entryId: "e1",
            segments: [
                .custom(
                    id: original.id,
                    typeDiscriminator: NoteSegment.typeDiscriminator,
                    contentJSON: #"{"body":"hello"}"#,
                    description: "a doctored description the type never produced"
                )
            ],
            assetIds: []
        )
        var registry = CustomSegmentRegistry()
        registry.register(NoteSegment.self)

        let rebuilt = try TranscriptEntryMapper.entry(from: doctored, kind: .response, registry: registry)

        guard case .response(let response) = rebuilt,
            case .custom(let rebuiltSegment) = response.segments.first
        else {
            Issue.record("expected a rebuilt .response entry with a .custom segment")
            return
        }
        #expect(rebuiltSegment.description == original.description)
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
        // The payload has no metadata field, and a response whose persisted
        // asset-id list is empty rebuilds through the metadata-less
        // initializer — so the original's own metadata key is gone and no
        // key is synthesized in its place: the rebuilt dictionary is empty.
        #expect(rebuiltResponse.metadata.isEmpty)
    }

    @Test("a .response with asset ids still synthesizes the metadata key on rebuild")
    func responseWithAssetIDsSynthesizesMetadataKey() throws {
        // With a non-empty asset-id list the only rebuildable initializer is
        // the assetIDs-based one (no public initializer accepts both
        // `assetIDs:` and `metadata:` together), and it stamps a
        // `metadata["assetIDs"]` key. That synthesis stays a documented,
        // pinned contract for this case.
        let original = Transcript.Entry.response(
            Transcript.Response(
                id: "response-1",
                assetIDs: ["asset-1"],
                segments: [.text(Transcript.TextSegment(id: "s1", content: "hi"))]
            )
        )
        let (kind, payload, _) = TranscriptEntryMapper.event(from: original)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .response(let rebuiltResponse) = rebuilt else {
            Issue.record("expected a rebuilt .response entry")
            return
        }
        #expect(rebuiltResponse.assetIDs == ["asset-1"])
        #expect(rebuiltResponse.metadata["assetIDs"] != nil)
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
        // The name still round-trips — recovered from the rebuilt schema, and
        // equal to the `responseFormatName` the payload persisted alongside
        // it (the persisted name is the reader-facing copy; the schema is the
        // fidelity carrier the rebuild reads).
        #expect(rebuiltFormat.name == Transcript.ResponseFormat(type: Weather.self).name)
        #expect(rebuiltFormat.name == payload.responseFormatName)
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

    @Test("a payload with a response-format name but no schema rebuilds without a responseFormat and logs a warning naming it")
    func nameOnlyResponseFormatDegradesToNilAndWarns() throws {
        // The shape a future ResponseFormat.Kind case would record: the
        // format's name persists, but there is no schema JSON to rebuild
        // from, so the rebuilt prompt carries no response format and the loss
        // is logged by name rather than passing silently.
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [.text(id: "s1", content: "hi")],
            responseFormatName: "Weather"
        )
        let logStart = Date()

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: .prompt)

        guard case .prompt(let rebuiltPrompt) = rebuilt else {
            Issue.record("expected a rebuilt .prompt entry")
            return
        }
        #expect(rebuiltPrompt.responseFormat == nil)
        try assertLogged(containing: "response-format name \"Weather\"", since: logStart)
    }

    @Test("an attachment with a nil ImageAttachment.url degrades on rebuild to a labeled text segment")
    func urlLessAttachmentDegradesToLabeledText() throws {
        let ciImage = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let imageAttachment = Transcript.ImageAttachment(ciImage, orientation: nil)
        #expect(imageAttachment.url == nil)

        let original = Transcript.Entry.response(
            Transcript.Response(
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

    @Test("an attachment with a non-nil ImageAttachment.url round-trips on every representable field")
    func urlBackedAttachmentRoundTrips() throws {
        // Full `Transcript.Entry` equality is not reachable for an
        // attachment: `Transcript.ImageAttachment`'s `==` compares the
        // identity of the per-instance image buffer it decodes into, so two
        // attachments built from the same URL — the original here and the
        // mapper's rebuild — are never equal. Every field a rebuild can
        // reproduce is compared instead: the entry's own id and asset ids,
        // the segment count, and the attachment's id, label, and URL.
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let original = Transcript.Entry.response(
            Transcript.Response(
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
        #expect(kind == .response)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: kind)

        guard case .response(let originalResponse) = original,
            case .response(let rebuiltResponse) = rebuilt,
            case .attachment(let rebuiltSegment) = rebuiltResponse.segments.first
        else {
            Issue.record("expected the rebuilt segment to stay an .attachment")
            return
        }
        #expect(rebuiltResponse.id == originalResponse.id)
        #expect(rebuiltResponse.assetIDs == originalResponse.assetIDs)
        #expect(rebuiltResponse.segments.count == originalResponse.segments.count)
        #expect(rebuiltSegment.id == "a1")
        #expect(rebuiltSegment.label == "photo")
        guard case .image(let rebuiltImage) = rebuiltSegment.content else {
            Issue.record("expected an .image attachment")
            return
        }
        #expect(rebuiltImage.url == url)
    }

    // MARK: - Unknown-case degradation (task 9n7fna4)

    @Test("an unknown segment carrier rebuilds as the documented text degradation and logs a warning")
    func unknownSegmentCarrierDegradesToTextAndWarns() throws {
        // A real unknown SDK segment cannot be constructed against the
        // current SDK, so the carrier enters through its own decode path —
        // exactly what a recording written by a router that met a future
        // segment case holds on disk.
        let json = """
        {"type":"unknown","id":"s9","description":"future segment content"}
        """
        let carrier = try JSONDecoder().decode(SegmentPayload.self, from: Data(json.utf8))
        let payload = TranscriptEntryPayload(entryId: "e1", segments: [carrier], assetIds: [])
        let logStart = Date()

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: .response)

        guard case .response(let response) = rebuilt, case .text(let textSegment) = response.segments.first
        else {
            Issue.record("expected the unknown carrier to degrade to .text")
            return
        }
        #expect(textSegment.id == "s9")
        #expect(textSegment.content == "future segment content")
        try assertLogged(containing: "unknown segment carrier", since: logStart)
    }

    @Test("an unknown-kind payload rebuilds as a text-only entry and logs a warning")
    func unknownKindRebuildsAsTextOnlyEntryAndWarns() throws {
        // The shape record time writes for a future Transcript.Entry case:
        // the entry's own id, plus one unknown segment carrying the SDK
        // value's description as best-effort text.
        let payload = TranscriptEntryPayload(
            entryId: "e1",
            segments: [.unknown(id: "e1", description: "future entry content")]
        )
        let logStart = Date()

        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: .unknown)

        guard case .response(let response) = rebuilt, case .text(let textSegment) = response.segments.first
        else {
            Issue.record("expected the unknown-kind payload to rebuild as a text-only entry")
            return
        }
        #expect(response.id == "e1")
        #expect(response.assetIDs.isEmpty)
        #expect(response.segments.count == 1)
        #expect(textSegment.content == "future entry content")
        try assertLogged(containing: "unknown entry kind", since: logStart)
    }

    // MARK: - Record-time encode failures

    @Test("jsonString(for:context:) throws a typed encode error for an unencodable value")
    func jsonStringThrowsATypedEncodeError() {
        // Double.infinity is unencodable under JSONEncoder's default
        // non-conforming-float strategy, so the encode fails at the cause
        // with the typed record-time error rather than a silent sentinel.
        #expect(throws: TranscriptEntryEncodingError.self) {
            try TranscriptEntryMapper.jsonString(for: Double.infinity, context: "test value")
        }
    }

    @Test("an unencodable custom-segment content records the empty-string sentinel and logs the failure")
    func unencodableCustomContentRecordsSentinelAndLogs() throws {
        let segment = UnencodableSegment(id: "u1", content: Unencodable(value: .infinity))
        let logStart = Date()

        let payload = TranscriptEntryMapper.segmentPayload(.custom(segment))

        guard case .custom(_, _, let contentJSON, _) = payload else {
            Issue.record("expected a .custom segment payload")
            return
        }
        #expect(contentJSON.isEmpty)
        try assertLogged(containing: "persisting the empty-string sentinel", since: logStart)
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
    /// `entry(from:kind:registry:)`, asserting the rebuilt entry equals the
    /// original — the round-trip contract every non-degraded field
    /// combination must satisfy.
    ///
    /// - Parameters:
    ///   - original: The entry to round-trip.
    ///   - kind: The event kind `event(from:)` must map `original` to.
    ///   - registry: The registry the rebuild runs against. Defaults to an
    ///     empty registry, which every non-`.custom` entry rebuilds under.
    private func assertRoundTrips(
        _ original: Transcript.Entry,
        kind: TranscriptEvent.Kind,
        registry: CustomSegmentRegistry = CustomSegmentRegistry()
    ) throws {
        let (mappedKind, payload, _) = TranscriptEntryMapper.event(from: original)
        #expect(mappedKind == kind)
        let rebuilt = try TranscriptEntryMapper.entry(from: payload, kind: mappedKind, registry: registry)
        #expect(rebuilt == original)
    }

    /// Asserts this process logged, since `start`, a message under this
    /// module's subsystem containing `fragment` — proof a degradation warning
    /// or an encode-failure fault actually reached the log, read back through
    /// `OSLogStore(scope: .currentProcessIdentifier)`.
    private func assertLogged(containing fragment: String, since start: Date) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == moduleName }
        #expect(
            entries.contains { $0.composedMessage.contains(fragment) },
            "no \(moduleName) log entry since \(start) contains \"\(fragment)\""
        )
    }
}
