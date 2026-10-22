/// The loop guards that ``RouterSessionDirectory/send(_:)`` applies to each
/// message (ROUTER-5, the guard table of session.md section 5.7). A session
/// sender and a UI sender get the same guards, so the `sessions` tool and
/// the `sessions` graph get the same rules.
///
/// A send above ``maxChainDepth``, the send of a turn after
/// ``maxSendsPerTurn``, and each target of a tag send after
/// ``maxTagTargets`` get a `refused` receipt with a reason that names the
/// limit. A text longer than ``maxMessageBytes`` throws
/// `SessionDirectoryError.messageTooLong(limit:)` before any delivery.
///
/// No guard limits the sessions that work at the same time: no start and no
/// delivery waits for a free slot (D72).
public struct SessionMessageLimits: Sendable, Equatable {
    /// The default deepest chain of messages.
    public static let defaultMaxChainDepth = 3

    /// The default most sends of one turn.
    public static let defaultMaxSendsPerTurn = 16

    /// The default most targets of one tag send.
    public static let defaultMaxTagTargets = 8

    /// The bytes of one KB.
    static let bytesPerKilobyte = 1024

    /// The default longest message, in KB.
    static let defaultMaxMessageKilobytes = 16

    /// The default longest message: 16 KB of UTF-8.
    public static let defaultMaxMessageBytes = defaultMaxMessageKilobytes * bytesPerKilobyte

    /// The deepest chain of messages. A user turn and a UI message give
    /// depth 1, and a turn that a message of depth d started gives depth
    /// d + 1 to each message it sends. A send above the limit is refused.
    public var maxChainDepth: Int

    /// The most sends that one turn of a session makes. Each later send of
    /// the turn is refused. A UI sender has no turn, so this guard does not
    /// apply to it.
    public var maxSendsPerTurn: Int

    /// The most targets that one tag send delivers to. Each later target is
    /// refused.
    public var maxTagTargets: Int

    /// The longest text of a message, in UTF-8 bytes. A longer text throws
    /// `SessionDirectoryError.messageTooLong(limit:)`.
    public var maxMessageBytes: Int

    /// Makes the loop guards.
    ///
    /// - Parameters:
    ///   - maxChainDepth: The deepest chain. The default is
    ///     ``defaultMaxChainDepth``.
    ///   - maxSendsPerTurn: The most sends of one turn. The default is
    ///     ``defaultMaxSendsPerTurn``.
    ///   - maxTagTargets: The most targets of one tag send. The default is
    ///     ``defaultMaxTagTargets``.
    ///   - maxMessageBytes: The longest text, in UTF-8 bytes. The default is
    ///     ``defaultMaxMessageBytes``.
    public init(
        maxChainDepth: Int = defaultMaxChainDepth,
        maxSendsPerTurn: Int = defaultMaxSendsPerTurn,
        maxTagTargets: Int = defaultMaxTagTargets,
        maxMessageBytes: Int = defaultMaxMessageBytes
    ) {
        self.maxChainDepth = maxChainDepth
        self.maxSendsPerTurn = maxSendsPerTurn
        self.maxTagTargets = maxTagTargets
        self.maxMessageBytes = maxMessageBytes
    }

    /// The reason of the `refused` receipt of a send above ``maxChainDepth``.
    var chainTooDeepReason: String {
        "The message chain is deeper than the limit of \(maxChainDepth)."
    }

    /// The reason of the `refused` receipt of a send of a turn after
    /// ``maxSendsPerTurn``.
    var tooManySendsReason: String {
        "The turn sent the most messages that one turn can send: \(maxSendsPerTurn)."
    }

    /// The reason of the `refused` receipt of each target of a tag send
    /// after ``maxTagTargets``.
    var tooManyTargetsReason: String {
        "The tag send reached its limit of \(maxTagTargets) targets."
    }
}
