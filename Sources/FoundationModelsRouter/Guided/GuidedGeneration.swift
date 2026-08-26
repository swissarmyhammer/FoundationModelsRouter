import Foundation

/// A failure to compile or validate a ``Grammar`` for guided generation.
///
/// xgrammar accepts only a subset of JSON Schema. A grammar outside that
/// subset fails here, so a caller can correct the schema.
enum GuidedRequestError: Error, Equatable {
    /// The JSON-schema grammar used unsupported keywords (a sorted subset of
    /// `$ref`, `allOf`, `format`).
    case unsupportedSchemaConstructs([String])

    /// The JSON-schema source was not a parseable JSON object.
    case invalidJSONSchema(String)

    /// The grammar source was empty.
    case emptyGrammar

    /// The constrained output did not decode into the requested shape. The
    /// associated value is the raw output.
    case decodingFailed(String)

    /// A ``Grammar/ebnf(_:)`` grammar was routed to the `LanguageModelSession`
    /// backend, which accepts only a `GenerationSchema` and has no raw-grammar
    /// entry point.
    case ebnfNotSupportedByLanguageModelSession
}

extension Grammar {
    /// JSON Schema keywords outside the xgrammar-supported subset.
    static let unsupportedSchemaKeywords: Set<String> = ["$ref", "allOf", "format"]

    /// Keywords whose value maps names to subschemas.
    private static let subschemaMapKeywords: Set<String> =
        ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]

    /// Keywords whose value is instance data, not a subschema.
    private static let instanceDataKeywords: Set<String> =
        ["enum", "const", "default", "examples"]

    /// Validates this grammar against the xgrammar-supported subset.
    ///
    /// - Throws: ``GuidedRequestError/unsupportedSchemaConstructs(_:)``,
    ///   ``GuidedRequestError/invalidJSONSchema(_:)``, or
    ///   ``GuidedRequestError/emptyGrammar``.
    func validateForXGrammar() throws {
        switch self {
        case .jsonSchema(let schema):
            try Grammar.validateJSONSchema(schema: schema)
        case .ebnf(let source):
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GuidedRequestError.emptyGrammar
            }
        }
    }

    /// Parses a JSON-schema source and rejects any unsupported keyword in the
    /// schema tree.
    ///
    /// - Parameter schema: The JSON Schema source string.
    /// - Throws: ``GuidedRequestError/invalidJSONSchema(_:)`` or
    ///   ``GuidedRequestError/unsupportedSchemaConstructs(_:)``.
    private static func validateJSONSchema(schema: String) throws {
        let trimmed = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GuidedRequestError.emptyGrammar }
        guard let data = schema.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else {
            throw GuidedRequestError.invalidJSONSchema(schema)
        }

        var found: Set<String> = []
        collectUnsupportedKeywords(in: root, into: &found)
        guard found.isEmpty else {
            throw GuidedRequestError.unsupportedSchemaConstructs(found.sorted())
        }
    }

    /// Walks a parsed JSON schema node and inserts each
    /// ``unsupportedSchemaKeywords`` entry used in keyword position into `found`.
    ///
    /// - Parameters:
    ///   - node: A parsed JSON value in a schema position.
    ///   - found: The accumulating set of unsupported keywords.
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
                collectUnsupportedKeywords(inSubschemaMap: value, into: &found)
            } else if !instanceDataKeywords.contains(key) {
                // Instance data is never walked; everything else is a subschema.
                collectUnsupportedKeywords(in: value, into: &found)
            }
        }
    }

    /// Walks the values of a ``subschemaMapKeywords`` map and inserts any
    /// unsupported keywords into `found`.
    ///
    /// - Parameters:
    ///   - value: The value found at a ``subschemaMapKeywords`` key.
    ///   - found: The accumulating set of unsupported keywords.
    private static func collectUnsupportedKeywords(inSubschemaMap value: Any, into found: inout Set<String>) {
        guard let submap = value as? [String: Any] else { return }
        for subschema in submap.values {
            collectUnsupportedKeywords(in: subschema, into: &found)
        }
    }
}

/// The raw guided-generation surface on the generation handle. It produces
/// constrained text with no token streaming and no typed parsing.
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Generates one constrained response through a one-shot guided session.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - grammar: The grammar that constrains the output.
    ///   - maxTokens: The maximum token count, or `nil` for the container default.
    /// - Returns: The constrained, unparsed text response.
    /// - Throws: ``GuidedRequestError`` for an invalid grammar, or a model error.
    func respond(
        to prompt: String,
        following grammar: Grammar,
        maxTokens: Int? = nil
    ) async throws -> String {
        try await makeGuidedSession(grammar: grammar).respond(to: prompt, maxTokens: maxTokens)
    }

    // sah:allow duplication a frozen public thin alias (^pckk91c, kept undeprecated for the six call sites) whose body only forwards its parameters plus the grammar into a SessionConfiguration and on to makeSession(configuration:); the plain makeSession forwards the same nine, and neither body holds logic that can drift
    /// Vends a guided session whose every ``RoutedSession/respond(to:)`` is
    /// constrained to `grammar`. A fork inherits the grammar.
    ///
    /// - Parameters:
    ///   - grammar: The grammar that constrains every `respond` on the session.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil`.
    ///   - tools: The tools the model can call. Defaults to none.
    ///   - budget: The auto-compaction opt-in. Defaults to `nil`.
    ///   - compactionPrompt: The prompt each compaction fold sends to the summarizer.
    ///   - summarization: The model-assisted compaction stage each fold runs.
    ///   - agentSpawn: The parent session and tool call this session was spawned from.
    ///   - discoveryPriming: The pre-discovery seeding opt-in. Defaults to `nil`.
    /// - Returns: A new guided ``RoutedSession``.
    public func makeGuidedSession(
        grammar: Grammar,
        instructions: String? = nil,
        workingDirectory: URL? = nil,
        tools: [any Tool] = [],
        budget: TokenBudget? = nil,
        compactionPrompt: CompactionPrompt = .default,
        summarization: Summarization = Summarization(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil
    ) -> RoutedSession {
        makeSession(
            configuration: SessionConfiguration(
                instructions: instructions,
                workingDirectory: workingDirectory,
                tools: tools,
                budget: budget,
                compactionPrompt: compactionPrompt,
                summarization: summarization,
                agentSpawn: agentSpawn,
                discoveryPriming: discoveryPriming,
                grammar: grammar))
    }
}

/// The pure steps behind the typed and dynamic guided response shapes: schema
/// derivation, typed decode, and dynamic parse.
enum GuidedShapes {
    /// Parses raw constrained output into a ``JSONValue``.
    ///
    /// - Parameter raw: The raw constrained output text.
    /// - Returns: The parsed ``JSONValue``.
    /// - Throws: ``GuidedRequestError/decodingFailed(_:)`` if `raw` is not JSON.
    static func parse(_ raw: String) throws -> JSONValue {
        guard let data = raw.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            throw GuidedRequestError.decodingFailed(raw)
        }
        return value
    }
}

/// The dynamic-JSON guided response shape.
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Generates a response constrained to a runtime JSON schema and parses it
    /// into a ``JSONValue``.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - jsonSchema: The runtime JSON Schema source that constrains the output.
    ///   - maxTokens: The maximum token count, or `nil` for the container default.
    /// - Returns: The schema-valid output parsed into a ``JSONValue``.
    /// - Throws: ``GuidedRequestError`` for a rejected schema or unparseable
    ///   output, or a model error.
    func respond(
        to prompt: String,
        matching jsonSchema: String,
        maxTokens: Int? = nil
    ) async throws -> JSONValue {
        let raw = try await respond(to: prompt, following: .jsonSchema(jsonSchema), maxTokens: maxTokens)
        return try GuidedShapes.parse(raw)
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    extension GuidedShapes {
        /// Derives a JSON Schema source string from a `@Generable` type.
        ///
        /// - Parameter type: The `Generable` type to derive a schema from.
        /// - Returns: The derived JSON Schema source string.
        /// - Throws: An encoding error if the schema cannot be encoded.
        static func derivedSchema<T: Generable>(for type: T.Type) throws -> String {
            let data = try JSONEncoder().encode(T.generationSchema)
            return String(decoding: data, as: UTF8.self)
        }

        /// Decodes raw constrained output into a `Generable` type.
        ///
        /// - Parameters:
        ///   - raw: The raw constrained output text.
        ///   - type: The `Generable` type to decode into.
        /// - Returns: The decoded value of type `T`.
        /// - Throws: ``GuidedRequestError/decodingFailed(_:)`` if `raw` does not
        ///   decode as `T`.
        static func decode<T: Generable>(_ raw: String, as type: T.Type) throws -> T {
            do {
                return try T(GeneratedContent(json: raw))
            } catch {
                throw GuidedRequestError.decodingFailed(raw)
            }
        }
    }

    /// The typed guided response shape.
    extension RoutedModel where Container == any LoadedLLMContainer {
        /// Generates a response constrained to a `@Generable` type's schema and
        /// decodes it into that type.
        ///
        /// - Parameters:
        ///   - prompt: The prompt to respond to.
        ///   - type: The `Generable` type to generate and decode into.
        ///   - maxTokens: The maximum token count, or `nil` for the container default.
        /// - Returns: The decoded value of type `T`.
        /// - Throws: ``GuidedRequestError`` for a rejected schema or a failed
        ///   decode, or a model error.
        func respond<T: Generable>(
            to prompt: String,
            generating type: T.Type,
            maxTokens: Int? = nil
        ) async throws -> T {
            let schema = try GuidedShapes.derivedSchema(for: T.self)
            let raw = try await respond(to: prompt, following: .jsonSchema(schema), maxTokens: maxTokens)
            return try GuidedShapes.decode(raw, as: T.self)
        }
    }
#endif  // canImport(FoundationModels)
