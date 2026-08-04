/// How a completed operation run ended.
///
/// This is envelope-grade information — the same class of fact as
/// `OperationEventKind` — because every host that consumes `OperationEvent`
/// (Router's `SessionOutbox` consumers, the ACP agent's `tool_call_update`
/// mapping) needs to answer "how did the run end" without parsing each
/// tool's private `detail` dialect. `OperationEvent.detail` stays opaque for
/// everything else — exit codes, `isError` provenance, progress counts —
/// only this one fact is promoted to the envelope.
///
/// The authority distinction between `.stopped`, `.cancelled`, and `.lost`
/// is deliberate and must not be flattened:
///
/// - `.stopped` means the work is *certainly* dead — it was terminated
///   authoritatively (e.g. Shelltool's `killpg(SIGKILL)` on the child's own
///   process group).
/// - `.cancelled` means cancellation was only *requested* — the work may
///   still be running (e.g. MCP's advisory `notifications/cancelled`,
///   honestly "we stopped listening").
/// - `.lost` means the outcome is *unknowable* (e.g. MCP's transport-drop
///   case, where a `ProgressToken` is meaningless across connections).
///
/// Not every emitting tool can produce every case, and that's fine — what
/// matters is that each case means the same one thing to every consumer.
/// Downstream mappings must respect the distinction (e.g. the ACP agent
/// maps `.lost` to its own `_lost` status, never to `.failed` — "we do not
/// know if this ran" is not the same claim as "this ran and failed").
///
/// Unknown-preserving: an unrecognized wire value decodes to `.other(_)`
/// instead of failing, mirroring ACP's `_`-prefixed extensible-enum
/// position. This lets a tool ship a novel outcome without a lockstep
/// release of this package.
public enum OperationOutcome: Sendable, Equatable {
    /// The work finished and reported success.
    case succeeded

    /// The work finished and reported failure, definitively known — a
    /// server said `isError`, a child process exited nonzero, or a local
    /// synthesis that never launched.
    case failed

    /// The run's own hard timeout ended it.
    case timedOut

    /// Terminated authoritatively; the work is certainly dead.
    case stopped

    /// Cancellation was requested; the work may continue.
    case cancelled

    /// The outcome is unknowable.
    case lost

    /// An outcome not recognized by this version of the package, carrying
    /// its original wire-format value.
    case other(String)

    /// The wire-format vocabulary for every case except `.other`, defined
    /// exactly once and consulted from both `rawValue` and
    /// `init(rawValue:)` so the case-to-string mapping cannot drift between
    /// the two directions.
    private static let wireVocabulary: [(rawValue: String, outcome: OperationOutcome)] = [
        ("succeeded", .succeeded),
        ("failed", .failed),
        ("timed_out", .timedOut),
        ("stopped", .stopped),
        ("cancelled", .cancelled),
        ("lost", .lost),
    ]

    /// The wire-format, snake_case raw string for this outcome.
    public var rawValue: String {
        if case let .other(value) = self {
            return value
        }
        // Every non-`.other` case is present in `wireVocabulary`, so this
        // lookup always succeeds; the empty-string fallback is unreachable.
        return Self.wireVocabulary.first(where: { $0.outcome == self })?.rawValue ?? ""
    }

    /// Creates an outcome from its wire-format, snake_case raw string.
    ///
    /// Never fails: a value not recognized by this version of the package
    /// is preserved as `.other(rawValue)`.
    public init(rawValue: String) {
        self = Self.wireVocabulary.first(where: { $0.rawValue == rawValue })?.outcome ?? .other(rawValue)
    }
}

extension OperationOutcome: Codable {
    /// Decodes an outcome from a bare wire-format string, preserving an
    /// unrecognized value as `.other(_)` rather than throwing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    /// Encodes this outcome as its bare wire-format, snake_case string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
