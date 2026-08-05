import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    /// Compiles a caller's runtime JSON Schema **document** into Apple's
    /// `GenerationSchema`, for the ``RoutedModel/respond(to:matching:)`` (dynamic)
    /// and ``RoutedModel/respond(to:following:)`` (raw, `.jsonSchema` source)
    /// guided-generation shapes.
    ///
    /// ## Why this exists
    ///
    /// `GenerationSchema` is `Codable`, and its `encode(to:)` produces a standard
    /// JSON Schema document (confirmed by reading `MLXFoundationModels`'
    /// `SchemaConverter`, which round-trips a `GenerationSchema` through
    /// `JSONEncoder` to get xgrammar's JSON-schema source). It is tempting to
    /// assume the reverse also holds — that `JSONDecoder().decode(GenerationSchema.self,
    /// from:)` accepts any hand-written JSON Schema text. **It does not.** Verified
    /// empirically (`LanguageModelSessionBackendTests`): `GenerationSchema`'s decode
    /// requires proprietary metadata this framework's own encoder adds —
    /// an `x-order` key recording property order, and a mandatory `title` on every
    /// object/string node — and treats a *titled* string schema as a closed-enum
    /// carrier, rejecting a plain titled string outright. So `GenerationSchema`'s
    /// `Codable` conformance only round-trips *its own* encoding; it is not a
    /// general JSON-Schema ingestion path for a caller's foreign schema (an MCP
    /// tool's `inputSchema`, for example).
    ///
    /// This converter instead walks the parsed JSON tree by hand into
    /// `DynamicGenerationSchema` nodes — a pure data transform, not a generation
    /// loop of our own — and assembles them into a `GenerationSchema` via
    /// `GenerationSchema(root:dependencies:)`. Constraining generation to the
    /// resulting schema still happens entirely inside `LanguageModelSession`
    /// (and, beneath it, `MLXLanguageModel`'s xgrammar-backed `Executor`) — this
    /// converter only builds the schema value handed to it.
    ///
    /// ## Supported subset
    ///
    /// Exactly the subset ``Grammar/validateForXGrammar()`` already accepts (so a
    /// schema that passes validation always converts, and `$ref`/`allOf`/`format`
    /// are never seen here — they are rejected upstream): object (`properties` +
    /// `required`), string/number/integer/boolean leaves, closed string `enum`s,
    /// and arrays (`items`, optional `minItems`/`maxItems`), nestable to any depth.
    /// Anything else (discriminated unions / `oneOf`, `$defs`-based recursion, etc.)
    /// throws ``RuntimeJSONSchemaConverter/ConversionError`` rather than silently
    /// producing an incorrect schema — a real, narrower-than-before limitation,
    /// documented in plan.md's "Guided generation" section.
    enum RuntimeJSONSchemaConverter {
        /// A JSON Schema construct this converter does not (yet) compile into a
        /// `DynamicGenerationSchema`.
        enum ConversionError: Error, Equatable {
            /// A schema node had no recognized `type` (or an unsupported one, e.g.
            /// `oneOf`/discriminated unions), named by its JSON pointer-ish path.
            case unsupportedNode(String)

            /// An `array` node had no `items` sub-schema.
            case missingArrayItems(String)
        }

        /// Compiles a JSON Schema document string into a `GenerationSchema`.
        ///
        /// - Parameters:
        ///   - jsonSchema: The JSON Schema source, already validated against the
        ///     xgrammar-supported subset by ``Grammar/validateForXGrammar()``.
        ///   - rootName: The name given to the root `DynamicGenerationSchema` node
        ///     (schema names are otherwise invisible to callers of the raw/dynamic
        ///     guided shapes).
        /// - Returns: The compiled `GenerationSchema`.
        /// - Throws: ``GuidedRequestError/invalidJSONSchema(_:)`` if `jsonSchema` is
        ///   not a parseable JSON object, ``ConversionError`` for an unsupported
        ///   construct, or an error from `GenerationSchema(root:dependencies:)` if
        ///   the assembled schema is itself invalid (e.g. a duplicate type name).
        static func compile(_ jsonSchema: String, rootName: String = "Root") throws -> GenerationSchema {
            guard let data = jsonSchema.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw GuidedRequestError.invalidJSONSchema(jsonSchema)
            }
            let dynamic = try node(named: rootName, path: rootName, from: root)
            return try GenerationSchema(root: dynamic, dependencies: [])
        }

        /// Compiles one JSON Schema node into a `DynamicGenerationSchema`, recursing
        /// into `properties`/`items` for objects/arrays.
        ///
        /// - Parameters:
        ///   - name: The node's name (a property key, `rootName`, or a synthesized
        ///     `"<name>Item"` for an array's element schema) — `DynamicGenerationSchema`
        ///     requires every named node to carry one.
        ///   - path: A dotted path to this node, for error messages only.
        ///   - schema: The parsed JSON Schema node.
        private static func node(
            named name: String,
            path: String,
            from schema: [String: Any]
        ) throws -> DynamicGenerationSchema {
            switch schema["type"] as? String {
            case "object":
                let properties = (schema["properties"] as? [String: Any]) ?? [:]
                let required = Set((schema["required"] as? [String]) ?? [])
                // Sorted for deterministic emission order (a plain `[String: Any]`
                // has none); the model doesn't care about property order for
                // correctness, but deterministic prompts aid debugging/testing.
                let props: [DynamicGenerationSchema.Property] = try properties
                    .sorted { $0.key < $1.key }
                    .map { key, value in
                        guard let propSchema = value as? [String: Any] else {
                            throw ConversionError.unsupportedNode("\(path).\(key)")
                        }
                        let child = try node(named: key, path: "\(path).\(key)", from: propSchema)
                        return DynamicGenerationSchema.Property(
                            name: key,
                            schema: child,
                            isOptional: !required.contains(key)
                        )
                    }
                return DynamicGenerationSchema(name: name, properties: props)

            case "array":
                guard let items = schema["items"] as? [String: Any] else {
                    throw ConversionError.missingArrayItems(path)
                }
                let itemSchema = try node(named: "\(name)Item", path: "\(path)[]", from: items)
                return DynamicGenerationSchema(
                    arrayOf: itemSchema,
                    minimumElements: schema["minItems"] as? Int,
                    maximumElements: schema["maxItems"] as? Int
                )

            case "string":
                if let choices = schema["enum"] as? [String] {
                    return DynamicGenerationSchema(name: name, anyOf: choices)
                }
                return DynamicGenerationSchema(type: String.self)

            case "integer":
                try rejectUnsupportedEnum(on: schema, path: path)
                return DynamicGenerationSchema(type: Int.self)

            case "number":
                try rejectUnsupportedEnum(on: schema, path: path)
                return DynamicGenerationSchema(type: Double.self)

            case "boolean":
                try rejectUnsupportedEnum(on: schema, path: path)
                return DynamicGenerationSchema(type: Bool.self)

            default:
                throw ConversionError.unsupportedNode(path)
            }
        }

        /// Rejects an `enum` constraint on a non-string leaf rather than silently
        /// dropping it.
        ///
        /// `DynamicGenerationSchema` has a closed-choice constructor for strings
        /// (`(name:anyOf: [String])`) but none for numeric/boolean literal values,
        /// so an `{"type":"integer","enum":[1,2,3]}`-style schema cannot be
        /// faithfully compiled today. Throwing here (instead of compiling a plain,
        /// unconstrained `Int`/`Double`/`Bool` leaf) keeps this converter's
        /// documented invariant — reject what it can't express, never silently
        /// produce a looser schema than requested.
        ///
        /// - Parameters:
        ///   - schema: The parsed JSON Schema node to check.
        ///   - path: The node's dotted path, for the thrown error.
        /// - Throws: ``ConversionError/unsupportedNode(_:)`` if `schema` carries an
        ///   `enum` key.
        private static func rejectUnsupportedEnum(on schema: [String: Any], path: String) throws {
            guard schema["enum"] != nil else { return }
            throw ConversionError.unsupportedNode("\(path).enum")
        }
    }
#endif  // canImport(FoundationModels)
