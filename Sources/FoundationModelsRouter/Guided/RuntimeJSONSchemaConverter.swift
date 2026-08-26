import Foundation

#if canImport(FoundationModels)
    import FoundationModels

    /// Compiles a runtime JSON Schema document into a `GenerationSchema` by
    /// walking the parsed tree into `DynamicGenerationSchema` nodes.
    ///
    /// Supported subset: object (`properties` + `required`), string, number,
    /// integer, and boolean leaves, closed string `enum`s, and arrays (`items`,
    /// optional `minItems`/`maxItems`), nested to any depth. Any other construct
    /// throws ``RuntimeJSONSchemaConverter/ConversionError``.
    enum RuntimeJSONSchemaConverter {
        /// A JSON Schema construct this converter does not compile.
        enum ConversionError: Error, Equatable {
            /// A schema node had no recognized `type`, named by its path.
            case unsupportedNode(String)

            /// An `array` node had no `items` sub-schema.
            case missingArrayItems(String)
        }

        /// Compiles a JSON Schema document string into a `GenerationSchema`.
        ///
        /// - Parameters:
        ///   - jsonSchema: The JSON Schema source.
        ///   - rootName: The name of the root `DynamicGenerationSchema` node.
        /// - Returns: The compiled `GenerationSchema`.
        /// - Throws: ``GuidedRequestError/invalidJSONSchema(_:)`` for unparseable
        ///   source, ``ConversionError`` for an unsupported construct, or an
        ///   error from `GenerationSchema(root:dependencies:)`.
        static func compile(_ jsonSchema: String, rootName: String = "Root") throws -> GenerationSchema {
            guard let data = jsonSchema.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw GuidedRequestError.invalidJSONSchema(jsonSchema)
            }
            let dynamic = try node(named: rootName, path: rootName, from: root)
            return try GenerationSchema(root: dynamic, dependencies: [])
        }

        /// Compiles one JSON Schema node into a `DynamicGenerationSchema`.
        ///
        /// - Parameters:
        ///   - name: The node's name.
        ///   - path: A dotted path to this node, for error messages.
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

        /// Rejects an `enum` constraint on a non-string leaf.
        ///
        /// - Parameters:
        ///   - schema: The parsed JSON Schema node to check.
        ///   - path: The node's dotted path, for the thrown error.
        /// - Throws: ``ConversionError/unsupportedNode(_:)`` if `schema` has an
        ///   `enum` key.
        private static func rejectUnsupportedEnum(on schema: [String: Any], path: String) throws {
            guard schema["enum"] != nil else { return }
            throw ConversionError.unsupportedNode("\(path).enum")
        }
    }
#endif  // canImport(FoundationModels)
