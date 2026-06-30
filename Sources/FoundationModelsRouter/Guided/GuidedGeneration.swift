import Foundation

/// A failure compiling or validating a ``Grammar`` for guided generation.
///
/// xgrammar accepts only a subset of JSON Schema. Grammars that use constructs
/// outside that subset and cannot be normalized are surfaced here — like a
/// metadata failure, not a crash — so a caller can correct the schema. The
/// validation that raises these is pure (no GPU), so it runs and is asserted in
/// the unit suite; real constrained decoding over MLX is gated to milestone 7.
public enum GuidedGenerationError: Error, Equatable {
    /// The JSON-schema grammar used xgrammar-unsupported keywords that this layer
    /// cannot normalize (a sorted, de-duplicated subset of `$ref`, `allOf`,
    /// `format`).
    case unsupportedSchemaConstructs([String])

    /// The JSON-schema source was not a parseable JSON object.
    case invalidJsonSchema(String)

    /// The grammar source was empty.
    case emptyGrammar
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
    /// typed ``GuidedGenerationError`` for anything that cannot be compiled.
    ///
    /// This is the real, GPU-free half of "compiling" a grammar: it parses and
    /// checks the source so unsupported constructs fail loudly here rather than
    /// deep inside the (gated) live decode. The xgrammar engine behind a
    /// ``LoadedLLMContainer``'s guided entry point calls this before constraining
    /// decode.
    ///
    /// - Throws: ``GuidedGenerationError/unsupportedSchemaConstructs(_:)`` for a
    ///   JSON schema using `$ref`/`allOf`/`format`,
    ///   ``GuidedGenerationError/invalidJsonSchema(_:)`` for a schema that is not
    ///   valid JSON, or ``GuidedGenerationError/emptyGrammar`` for empty source.
    func validateForXGrammar() throws {
        switch self {
        case .jsonSchema(let schema):
            try Grammar.validateJsonSchema(schema)
        case .ebnf(let source):
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GuidedGenerationError.emptyGrammar
            }
        }
    }

    /// Parses a JSON-schema source and rejects any xgrammar-unsupported keyword
    /// found anywhere in the schema tree.
    ///
    /// - Parameter schema: The JSON Schema source string.
    /// - Throws: ``GuidedGenerationError/invalidJsonSchema(_:)`` when the source
    ///   is not parseable JSON, or
    ///   ``GuidedGenerationError/unsupportedSchemaConstructs(_:)`` when it uses
    ///   keywords outside the supported subset.
    private static func validateJsonSchema(_ schema: String) throws {
        let trimmed = schema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GuidedGenerationError.emptyGrammar }
        guard let data = schema.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else {
            throw GuidedGenerationError.invalidJsonSchema(schema)
        }

        var found: Set<String> = []
        collectUnsupportedKeywords(in: root, into: &found)
        guard found.isEmpty else {
            throw GuidedGenerationError.unsupportedSchemaConstructs(found.sorted())
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
                // The value's keys are names; only its values are subschemas.
                collectFromSubschemaMap(value, into: &found)
            } else if !instanceDataKeywords.contains(key) {
                // Instance data is never walked; everything else is a subschema.
                collectUnsupportedKeywords(in: value, into: &found)
            }
        }
    }

    /// Recurses into the *values* of a ``subschemaMapKeywords`` map, whose keys
    /// are property/definition names rather than schema keywords.
    ///
    /// Extracted from ``collectUnsupportedKeywords(in:into:)`` so the main walk
    /// stays shallow: the map's values are each walked as a subschema, while its
    /// keys (data) are ignored.
    ///
    /// - Parameters:
    ///   - value: The keyword's value, expected to be a map of names to subschemas.
    ///   - found: The accumulating set of unsupported keywords encountered.
    private static func collectFromSubschemaMap(_ value: Any, into found: inout Set<String>) {
        guard let submap = value as? [String: Any] else { return }
        for subschema in submap.values {
            collectUnsupportedKeywords(in: subschema, into: &found)
        }
    }
}

extension LoadedLLMContainer {
    /// The default guided-generation path: validate the grammar (real, GPU-free),
    /// then surface the deferred live-inference seam.
    ///
    /// The live `ModelContainer` inherits this, so a guided turn over a real model
    /// still rejects unsupported grammars with a typed ``GuidedGenerationError``
    /// before reaching the gated decode, and otherwise makes its unwired state
    /// explicit by throwing ``GenerationError/notWiredForLiveInference`` (real
    /// constrained decoding lands in the milestone 7 integration suite). Stub
    /// containers override this to return canned constrained text.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The grammar constraining the output.
    /// - Returns: The constrained text response.
    /// - Throws: ``GuidedGenerationError`` for an invalid grammar, otherwise
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
    /// - Throws: ``GuidedGenerationError`` for an invalid grammar, or any error
    ///   the model raises (``GenerationError/notWiredForLiveInference`` over a
    ///   live container until milestone 7).
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
