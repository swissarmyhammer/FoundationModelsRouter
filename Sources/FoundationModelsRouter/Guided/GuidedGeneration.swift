import Foundation

/// A failure compiling or validating a ``Grammar`` for guided generation.
///
/// xgrammar accepts only a subset of JSON Schema. Grammars that use constructs
/// outside that subset and cannot be normalized are surfaced here — like a
/// metadata failure, not a crash — so a caller can correct the schema. The
/// validation that raises these is pure (no GPU), so it runs and is asserted in
/// the unit suite; real constrained decoding over MLX is gated to milestone 7.
public enum GuidedRequestError: Error, Equatable {
    /// The JSON-schema grammar used xgrammar-unsupported keywords that this layer
    /// cannot normalize (a sorted, de-duplicated subset of `$ref`, `allOf`,
    /// `format`).
    case unsupportedSchemaConstructs([String])

    /// The JSON-schema source was not a parseable JSON object.
    case invalidJsonSchema(String)

    /// The grammar source was empty.
    case emptyGrammar

    /// The constrained model output could not be turned into the requested shape:
    /// the raw text did not decode into the caller's `Generable` type (typed
    /// shape) or did not parse into a ``JSONValue`` (dynamic shape). The
    /// associated value is the offending raw output.
    ///
    /// This makes the higher-level shapes (milestone 8b) surface a decode failure
    /// through the *same* typed error as an xgrammar-subset rejection, so a caller
    /// handles both kinds of guided-generation failure in one `catch`.
    case decodingFailed(String)
}

extension Grammar {
    /// JSON Schema keywords outside the xgrammar-supported subset that this layer
    /// does not attempt to normalize, and therefore rejects.
    static let unsupportedSchemaKeywords: Set<String> = ["$ref", "allOf", "format"]

    /// Keywords whose value is a map of *names* to subschemas — the map's keys are
    /// property/definition names (data), not schema keywords, so they must not be
    /// checked against ``unsupportedSchemaKeywords``; only their values are
    /// subschemas to recurse into.
    private static let subschemaMapKeywords: Set<String> =
        ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]

    /// Keywords whose value is instance *data*, not a subschema — their contents
    /// are not walked, so a data value that happens to contain a key named like a
    /// keyword is not mistaken for that keyword in use.
    private static let instanceDataKeywords: Set<String> =
        ["enum", "const", "default", "examples"]

    /// Validates this grammar against the xgrammar-supported subset, throwing a
    /// typed ``GuidedRequestError`` for anything that cannot be compiled.
    ///
    /// This is the real, GPU-free half of "compiling" a grammar: it parses and
    /// checks the source so unsupported constructs fail loudly here rather than
    /// deep inside the (gated) live decode. The xgrammar engine behind a
    /// ``LoadedLLMContainer``'s guided entry point calls this before constraining
    /// decode.
    ///
    /// - Throws: ``GuidedRequestError/unsupportedSchemaConstructs(_:)`` for a
    ///   JSON schema using `$ref`/`allOf`/`format`,
    ///   ``GuidedRequestError/invalidJsonSchema(_:)`` for a schema that is not
    ///   valid JSON, or ``GuidedRequestError/emptyGrammar`` for empty source.
    func validateForXGrammar() throws {
        switch self {
        case .jsonSchema(let schema):
            try Grammar.validateJsonSchema(schema)
        case .ebnf(let source):
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GuidedRequestError.emptyGrammar
            }
        }
    }

    /// Parses a JSON-schema source and rejects any xgrammar-unsupported keyword
    /// found anywhere in the schema tree.
    ///
    /// - Parameter schema: The JSON Schema source string.
    /// - Throws: ``GuidedRequestError/invalidJsonSchema(_:)`` when the source
    ///   is not parseable JSON, or
    ///   ``GuidedRequestError/unsupportedSchemaConstructs(_:)`` when it uses
    ///   keywords outside the supported subset.
    private static func validateJsonSchema(_ schema: String) throws {
        let trimmed = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GuidedRequestError.emptyGrammar }
        guard let data = schema.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else {
            throw GuidedRequestError.invalidJsonSchema(schema)
        }

        var found: Set<String> = []
        collectUnsupportedKeywords(in: root, into: &found)
        guard found.isEmpty else {
            throw GuidedRequestError.unsupportedSchemaConstructs(found.sorted())
        }
    }

    /// Walks a parsed JSON *schema* node, inserting any
    /// ``unsupportedSchemaKeywords`` used in *keyword position* into `found`.
    ///
    /// The walk is position-aware so a property (or definition) that merely has a
    /// name like a keyword is not mistaken for the keyword itself: the keys of a
    /// ``subschemaMapKeywords`` map are names, so only their values are recursed
    /// into as subschemas, and the contents of ``instanceDataKeywords`` are
    /// instance data and are not walked at all. An array node is a list of
    /// subschemas (e.g. under `anyOf`/`oneOf`), so each element is walked as a
    /// schema.
    ///
    /// - Parameters:
    ///   - node: A parsed JSON value occupying a schema position.
    ///   - found: The accumulating set of unsupported keywords encountered.
    private static func collectUnsupportedKeywords(in node: Any, into found: inout Set<String>) {
        if let array = node as? [Any] {
            // An array node is a list of subschemas (e.g. under `anyOf`/`oneOf`).
            for element in array {
                collectUnsupportedKeywords(in: element, into: &found)
            }
            return
        }
        guard let object = node as? [String: Any] else { return }
        for (key, value) in object {
            if unsupportedSchemaKeywords.contains(key) {
                found.insert(key)
            }
            if subschemaMapKeywords.contains(key) {
                // The value's keys are property/definition names, not schema
                // keywords; only its values are subschemas to recurse into.
                guard let submap = value as? [String: Any] else { continue }
                for subschema in submap.values {
                    collectUnsupportedKeywords(in: subschema, into: &found)
                }
            } else if !instanceDataKeywords.contains(key) {
                // Instance data is never walked; everything else is a subschema.
                collectUnsupportedKeywords(in: value, into: &found)
            }
        }
    }
}

extension LoadedLLMContainer {
    /// The default guided-generation path for conformers without a real
    /// constrained-decode pipeline: validate the grammar (real, GPU-free), then
    /// surface the unwired seam.
    ///
    /// The live `ModelContainer` overrides this (see ``LiveModelLoader``) with the
    /// real xgrammar `GuidedGenerationLoop` decode; the unit stubs either inherit
    /// this fallback or override it to return canned constrained text. Either way
    /// the grammar is validated first, so an unsupported grammar fails with a typed
    /// ``GuidedRequestError`` before any decode.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The grammar constraining the output.
    /// - Returns: The constrained text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, otherwise
    ///   ``GenerationError/notWiredForLiveInference`` until milestone 7.
    public func respond(
        to prompt: String,
        instructions: String?,
        following grammar: Grammar
    ) async throws -> String {
        try grammar.validateForXGrammar()
        throw GenerationError.notWiredForLiveInference
    }
}

/// The guided-generation surface on the generation handle.
///
/// Like ``RoutedModel/makeSession(instructions:workingDirectory:)``, these arrive
/// as a container-constrained extension so they are invisible on
/// ``RoutedEmbedder``. Both produce *raw* constrained text — no token streaming
/// (``RoutedSession/streamResponse(to:)`` stays unconstrained-only) and no typed
/// parsing (the typed/dynamic shapes build on this in milestone 8b).
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Generates a single constrained response, recorded through the same
    /// chokepoint a guided session uses.
    ///
    /// This vends a one-shot guided ``RoutedSession`` over the resident container
    /// and responds through it, so the turn funnels through the recorder-bracketed
    /// `generate` chokepoint and is stamped with `grammar` — exactly as a
    /// long-lived guided session's turns are.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - grammar: The grammar constraining the output.
    /// - Returns: The constrained, unparsed text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, or any error
    ///   the model raises during constrained decoding.
    public func respond(to prompt: String, following grammar: Grammar) async throws -> String {
        try await makeGuidedSession(grammar).respond(to: prompt)
    }

    /// Vends a guided generation session whose every ``RoutedSession/respond(to:)``
    /// is constrained to `grammar`.
    ///
    /// The grammar travels with the session, so a milestone-9 fork inherits it.
    /// The session is otherwise identical to one from
    /// ``makeSession(instructions:workingDirectory:)`` — it inherits this handle's
    /// recorder and router id, retains the owning profile, and funnels every turn
    /// through the recorder-bracketed chokepoint, which stamps the grammar onto
    /// each event. Its ``RoutedSession/streamResponse(to:)`` stays
    /// unconstrained-only.
    ///
    /// - Parameters:
    ///   - grammar: The grammar constraining every `respond` on the session.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil` to default to
    ///     the recording directory.
    /// - Returns: A new guided ``RoutedSession``.
    public func makeGuidedSession(
        _ grammar: Grammar,
        instructions: String? = nil,
        workingDirectory: URL? = nil
    ) -> RoutedSession {
        makeSession(grammar: grammar, instructions: instructions, workingDirectory: workingDirectory)
    }
}

/// The pure, GPU-free steps behind the two higher-level guided response shapes
/// (milestone 8b): deriving a JSON Schema from a `@Generable` type, decoding raw
/// constrained output into that type, and parsing raw constrained output into a
/// dynamically-typed ``JSONValue``.
///
/// These are factored out of the ``RoutedModel`` shapes so they can be exercised
/// directly in the unit suite without a model: the only gated part of guided
/// generation is the constrained decode itself (milestone 7), which the shapes
/// reach through the raw ``RoutedModel/respond(to:following:)`` layer. The
/// `Generable`-facing steps are compiled only where Apple's FoundationModels
/// framework is available (see the `canImport(FoundationModels)` extension below).
enum GuidedShapes {
    /// Parses raw constrained model output into a dynamically-typed ``JSONValue``.
    ///
    /// Used by the dynamic-JSON shape, whose schema has no Swift type, so the
    /// output is introspected as a ``JSONValue`` rather than decoded into a fixed
    /// type. The constrained output is already schema-valid; a parse failure here
    /// means the raw text was not JSON at all.
    ///
    /// - Parameter raw: The raw constrained output text.
    /// - Returns: The parsed ``JSONValue``.
    /// - Throws: ``GuidedRequestError/decodingFailed(_:)`` if `raw` is not
    ///   parseable JSON.
    static func parse(_ raw: String) throws -> JSONValue {
        guard let data = raw.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            throw GuidedRequestError.decodingFailed(raw)
        }
        return value
    }
}

/// The dynamic-JSON guided response shape (milestone 8b).
///
/// Like the raw guided surface, it arrives as a container-constrained extension so
/// it is invisible on ``RoutedEmbedder``.
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Generates a response constrained to a runtime JSON schema that has no Swift
    /// type, parsed into a dynamically-typed ``JSONValue``.
    ///
    /// This is the shape for a schema known only at runtime — an MCP tool's
    /// `inputSchema`, say — where there is no `Generable` type to decode into. The
    /// caller's schema string is wrapped as a ``Grammar/jsonSchema(_:)`` and
    /// routed through the raw ``respond(to:following:)`` layer (which validates it
    /// against the xgrammar subset), then the constrained output is parsed into a
    /// ``JSONValue`` the caller introspects dynamically — never decoded to a fixed
    /// type.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - jsonSchema: The runtime JSON Schema source constraining the output.
    /// - Returns: The schema-valid output parsed into a ``JSONValue``.
    /// - Throws: ``GuidedRequestError`` — an xgrammar-subset rejection for an
    ///   over-spec schema, or ``GuidedRequestError/decodingFailed(_:)`` if the
    ///   output does not parse as JSON — or any error the model raises during
    ///   constrained decoding.
    public func respond(to prompt: String, matching jsonSchema: String) async throws -> JSONValue {
        let raw = try await respond(to: prompt, following: .jsonSchema(jsonSchema))
        return try GuidedShapes.parse(raw)
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    extension GuidedShapes {
        /// Derives a JSON Schema source string from a `@Generable` type — the one
        /// source of truth for the typed shape's constraint.
        ///
        /// A `Generable` type carries a `GenerationSchema`, which is itself
        /// `Codable` and encodes to a standard JSON Schema, so encoding it yields
        /// the schema string the raw guided layer constrains against. This is a
        /// pure transform (no GPU), so it is asserted directly in the unit suite.
        ///
        /// - Parameter type: The `Generable` type to derive a schema from.
        /// - Returns: The derived JSON Schema source string.
        /// - Throws: An encoding error if the schema cannot be encoded (not
        ///   expected for a valid `Generable` type).
        static func derivedSchema<T: Generable>(for type: T.Type) throws -> String {
            let data = try JSONEncoder().encode(T.generationSchema)
            return String(decoding: data, as: UTF8.self)
        }

        /// Decodes raw constrained output into a `Generable` type.
        ///
        /// The raw text is parsed into `GeneratedContent` and then initialized into
        /// `T` through its `Generable` conformance. This is a pure transform (no
        /// GPU), so it is asserted directly in the unit suite.
        ///
        /// - Parameters:
        ///   - raw: The raw constrained output text.
        ///   - type: The `Generable` type to decode into.
        /// - Returns: The decoded value of type `T`.
        /// - Throws: ``GuidedRequestError/decodingFailed(_:)`` if `raw` is not
        ///   parseable as `T` — malformed JSON or a shape the type rejects.
        static func decode<T: Generable>(_ raw: String, as type: T.Type) throws -> T {
            do {
                return try T(GeneratedContent(json: raw))
            } catch {
                throw GuidedRequestError.decodingFailed(raw)
            }
        }
    }

    /// The typed guided response shape (milestone 8b).
    extension RoutedModel where Container == any LoadedLLMContainer {
        /// Generates a response constrained to a `@Generable` type's schema and
        /// decoded back into that type — one source of truth for the shape.
        ///
        /// The schema is *derived from* `T` (its `GenerationSchema` encoded to JSON
        /// Schema), wrapped as a ``Grammar/jsonSchema(_:)``, and routed through the
        /// raw ``respond(to:following:)`` layer; the constrained output is then
        /// decoded into `T`. Both the derivation and the decode are pure and
        /// unit-tested; only the constrained decode in between is gated to
        /// milestone 7.
        ///
        /// - Parameters:
        ///   - prompt: The prompt to respond to.
        ///   - type: The `Generable` type to generate and decode into.
        /// - Returns: The decoded value of type `T`.
        /// - Throws: ``GuidedRequestError`` — an xgrammar-subset rejection for a
        ///   schema `T` derives that the subset cannot express, or
        ///   ``GuidedRequestError/decodingFailed(_:)`` if the output does not
        ///   decode into `T` — or any error the model raises during constrained
        ///   decoding.
        public func respond<T: Generable>(
            to prompt: String,
            generating type: T.Type
        ) async throws -> T {
            let schema = try GuidedShapes.derivedSchema(for: T.self)
            let raw = try await respond(to: prompt, following: .jsonSchema(schema))
            return try GuidedShapes.decode(raw, as: T.self)
        }
    }
#endif  // canImport(FoundationModels)
