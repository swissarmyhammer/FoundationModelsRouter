import Foundation
import FoundationModelsExtras

/// A recorded sub-agent session of a parent session, as
/// ``RouterSessionDirectory/recordedChildren(of:)`` reads it from the
/// `index.md` of the child, without a restore.
///
/// A host that restarts after a crash lists the children of a session with
/// this value. It restores a child only when ``ended`` is `nil` and the run
/// named by ``parentToolCallId`` is not completed in the parent
/// (``RouterSessionDirectory/runStatuses(of:)``).
public struct RecordedChild: Sendable, Equatable {
    /// The session id of the child.
    public let sessionID: ULID

    /// The agent id of the child. A record with no agent id gives the default
    /// agent, as the recorded session listing does.
    public let agentID: String

    /// The agent name of the child, or `nil` when the record holds none.
    public let agentName: String?

    /// The session that spawned the child
    /// (``SessionRecord/AgentSpawn/parentSessionId``).
    public let parentSessionId: ULID

    /// The completion token of the call of the parent that started the child
    /// (``SessionRecord/AgentSpawn/parentToolCallId``). It is the
    /// ``RunKey/correlationID`` of the run of that call in the journal of the
    /// parent.
    public let parentToolCallId: String

    /// The ended marker of the child, or `nil` when the child is not ended
    /// (``RouterSessionDirectory/markEnded(_:reason:)``).
    public let ended: SessionEndedMarker?

    /// Makes a recorded child.
    ///
    /// - Parameters:
    ///   - sessionID: The session id of the child.
    ///   - agentID: The agent id of the child.
    ///   - agentName: The agent name of the child, or `nil`.
    ///   - parentSessionId: The session that spawned the child.
    ///   - parentToolCallId: The completion token of the spawning call.
    ///   - ended: The ended marker of the child, or `nil`.
    public init(
        sessionID: ULID, agentID: String, agentName: String?, parentSessionId: ULID, parentToolCallId: String,
        ended: SessionEndedMarker?
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentName = agentName
        self.parentSessionId = parentSessionId
        self.parentToolCallId = parentToolCallId
        self.ended = ended
    }

    /// Makes the recorded child of a record that holds an agent spawn.
    ///
    /// - Parameter record: The record of a session.
    /// - Returns: The child, or `nil` when the record holds no agent spawn.
    init?(record: SessionRecord) {
        guard let spawn = record.agentSpawn else { return nil }
        self.init(
            sessionID: record.sessionId,
            agentID: record.facts.agentID ?? RouterSessionDirectory.defaultAgentID,
            agentName: record.facts.agentName,
            parentSessionId: spawn.parentSessionId,
            parentToolCallId: spawn.parentToolCallId,
            ended: record.facts.end)
    }
}
