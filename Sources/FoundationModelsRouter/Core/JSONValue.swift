import Foundation

/// A dynamically-typed JSON value.
///
/// Schema-guided generation produces output whose shape is known only at
/// runtime, so the router cannot map it onto a static Swift type. `JSONValue`
/// models any JSON document — the six JSON kinds — and round-trips losslessly
/// through `JSONEncoder`/`JSONDecoder`.
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`,
/// `Equatable`, and `Codable`. Its custom `Codable` conformance encodes each
/// case as the corresponding native JSON value rather than a tagged wrapper, so
/// the encoded form is ordinary JSON.
public enum JSONValue: Sendable, Equatable, Codable {
    /// JSON `null`.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON number. JSON does not distinguish integers from reals, so all
    /// numbers are carried as `Double`.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array of values.
    case array([JSONValue])
    /// A JSON object keyed by string.
    case object([String: JSONValue])

    /// Decodes a value as ordinary JSON, dispatching on the encountered kind.
    ///
    /// - Throws: `DecodingError.dataCorrupted` if the value is not a JSON kind
    ///   (`null`, boolean, number, string, array, or object).
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "Value is not a valid JSON kind"
                )
            )
        }
    }

    /// Encodes the value as ordinary JSON, emitting the native JSON value for
    /// the case rather than a tagged wrapper.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}
