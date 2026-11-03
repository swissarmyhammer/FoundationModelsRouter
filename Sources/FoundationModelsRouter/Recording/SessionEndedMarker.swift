import Foundation

/// Why a host marked a session as ended.
///
/// The host that owns the run gives the reason. Router stores it and never
/// acts on it.
public enum SessionEndReason: String, Sendable, Codable, Equatable, CaseIterable {
    /// The run reached its goal.
    case finished

    /// The run stopped with an error.
    case failed

    /// The run was stopped before it reached its goal.
    case cancelled
}

/// The ended marker of a session: when the host marked it and why.
///
/// A session with this marker has no work to restore. The recording stays,
/// for history and debugging, and a host can still restore the session when
/// it asks. A record with no marker counts as not ended.
public struct SessionEndedMarker: Sendable, Codable, Equatable {
    /// The instant the host marked the session as ended, rounded to
    /// milliseconds as the `index.md` stores it.
    public let endedAt: Date

    /// Why the session ended.
    public let reason: SessionEndReason

    /// Makes an ended marker.
    ///
    /// - Parameters:
    ///   - endedAt: The instant of the mark.
    ///   - reason: Why the session ended.
    public init(endedAt: Date, reason: SessionEndReason) {
        self.endedAt = endedAt
        self.reason = reason
    }
}

extension SessionFacts {
    /// The ended marker of the session, or `nil` when it is not ended.
    ///
    /// A record that holds an end instant but no reason, or the reverse, is
    /// not ended: the marker is whole or it is absent.
    public var end: SessionEndedMarker? {
        guard let endedAt, let endReason else { return nil }
        return SessionEndedMarker(endedAt: endedAt, reason: endReason)
    }
}
