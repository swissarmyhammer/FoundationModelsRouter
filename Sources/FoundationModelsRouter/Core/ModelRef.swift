/// A reference to a model on the Hugging Face Hub, optionally pinned to a
/// specific revision.
///
/// A `ModelRef` names a repository (e.g. `"mlx-community/Qwen2.5-Coder-32B"`)
/// and, when revision-pinned, a particular commit, tag, or branch within it.
/// The pinned form uses an `@` separator: `"org/repo@rev"` parses into the
/// `repo` `"org/repo"` and the `revision` `"rev"`. Without an `@`, the whole
/// string is the `repo` and `revision` is `nil`.
///
/// Because authored profiles list models inline, `ModelRef` is
/// `ExpressibleByStringLiteral`: a bare string literal such as
/// `"mlx-community/Qwen2.5-Coder-32B-Instruct-8bit"` is a valid `ModelRef`.
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`,
/// `Hashable`, and `Codable`. It encodes to and decodes from its canonical
/// string form (`repo` or `repo@revision`).
public struct ModelRef: Sendable, Hashable, ExpressibleByStringLiteral, Codable {
    /// The Hugging Face repository id, e.g. `"org/repo"`. Never includes the
    /// revision suffix.
    public let repo: String

    /// The pinned revision (commit hash, tag, or branch), or `nil` when the
    /// reference tracks the repository's default revision.
    public let revision: String?

    /// The separator between repository id and revision in the canonical
    /// string form.
    private static let revisionSeparator: Character = "@"

    /// Creates a model reference from an explicit repository id and optional
    /// revision.
    ///
    /// - Parameters:
    ///   - repo: The Hugging Face repository id, e.g. `"org/repo"`.
    ///   - revision: The pinned revision, or `nil` to track the default.
    public init(repo: String, revision: String? = nil) {
        self.repo = repo
        self.revision = revision
    }

    /// Parses a model reference from its string form.
    ///
    /// Splits on the first `@`: text before it becomes `repo` and text after it
    /// becomes `revision`. Without an `@`, the whole string is `repo` and
    /// `revision` is `nil`.
    ///
    /// - Parameter string: The reference, e.g. `"org/repo"` or `"org/repo@rev"`.
    public init(_ string: String) {
        if let separatorIndex = string.firstIndex(of: Self.revisionSeparator) {
            self.repo = String(string[..<separatorIndex])
            self.revision = String(string[string.index(after: separatorIndex)...])
        } else {
            self.repo = string
            self.revision = nil
        }
    }

    /// Parses a model reference from a string literal, enabling bare literals
    /// such as `let ref: ModelRef = "org/repo@rev"`.
    ///
    /// - Parameter value: The string literal to parse.
    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The canonical string form: `repo` when unpinned, or `repo@revision` when
    /// a revision is set.
    public var stringValue: String {
        guard let revision else { return repo }
        return "\(repo)\(Self.revisionSeparator)\(revision)"
    }

    /// Encodes the reference as its canonical string form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    /// Decodes a reference from its canonical string form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }
}
