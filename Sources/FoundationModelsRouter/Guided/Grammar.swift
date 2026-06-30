import Foundation

/// A grammar that constrains a model's decoding so its output is guaranteed to be
/// syntactically valid — the raw input to xgrammar-backed guided generation.
///
/// Two source forms are supported, mirroring the xgrammar engine's two compile
/// paths (see ``RoutedModel/respond(to:following:)``):
///
/// - ``jsonSchema(_:)`` — a standard JSON Schema source string, compiled through
///   xgrammar's JSON-schema path. Only the xgrammar-supported subset is accepted;
///   constructs that cannot be normalized (`$ref`, `allOf`, `format`) are rejected
///   with a typed ``GuidedGenerationError`` rather than crashing.
/// - ``ebnf(_:)`` — a GBNF/EBNF grammar source string, compiled through xgrammar's
///   EBNF path, for shapes a JSON schema cannot express.
///
/// A `Grammar` is a plain value: it travels with a guided ``RoutedSession`` (so a
/// milestone-9 fork inherits it) and is recorded onto each guided turn's
/// ``TranscriptEvent/grammar``.
public enum Grammar: Sendable, Equatable {
    /// A JSON Schema source string constraining the output to schema-valid JSON.
    case jsonSchema(String)

    /// A GBNF/EBNF grammar source string constraining the output to the grammar.
    case ebnf(String)

    /// The underlying grammar source string handed to the xgrammar engine — the
    /// JSON-schema text for ``jsonSchema(_:)`` or the EBNF text for ``ebnf(_:)``.
    ///
    /// This is also the value stamped onto a guided turn's
    /// ``TranscriptEvent/grammar``.
    public var source: String {
        switch self {
        case .jsonSchema(let source), .ebnf(let source):
            return source
        }
    }
}
