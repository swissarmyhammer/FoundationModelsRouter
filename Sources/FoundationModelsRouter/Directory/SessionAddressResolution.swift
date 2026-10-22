import Foundation
import FoundationModelsExtras

/// What a send does with the address of a message (ROUTER-4, the
/// addressing table of session.md section 9): the live sessions that get the
/// message, a recorded session to restore first, an agent to start, or the
/// reason and target of a refusal.
///
/// ``FoundationModelsExtras/SessionAddress/resolution(from:among:recordedSummary:)``
/// gives the decision. It is pure: it reads only the summaries it is given,
/// and it starts, restores and delivers nothing. The send acts on it: it
/// delivers, restores through the launcher (ROUTER-5), or starts a root
/// session with origin `message` through the launcher (ROUTER-8).
///
/// An unknown session is not a decision: as the FoundationModelsExtras send
/// contract says, the resolver throws `SessionDirectoryError.unknownSession`
/// for a session sender or a session id target that no live or recorded
/// session has, and the send lets that error out.
enum SessionAddressResolution: Sendable, Equatable {
    /// Deliver the message to each of these live sessions, in this order.
    case deliver([ULID])

    /// Restore this recorded session that is not live, then deliver the
    /// message to it.
    case restoreThenDeliver(ULID)

    /// Start a root session of the agent, with the message as its first
    /// message. The folder is the folder of the address, else the folder of
    /// the sender session, else `nil` for a user sender with no folder.
    case startAgent(agentID: String, folder: URL?)

    /// Refuse the send with this reason, the text of
    /// `SessionSendReceipt.reason`, for this target, the
    /// `SessionSendReceipt.target`: the session that matched the address, or
    /// `nil` when no session matched it.
    case refused(reason: String, target: ULID?)

    /// The reason for a session id of an archived session (session.md
    /// section 10.2).
    static let archivedReason = "archived"

    /// The reason for a folder with no live root session: a folder alone does
    /// not name an agent (D61).
    static let noRootSessionInTheFolderReason = "Name an agent: @agent:/path."

    /// The reason for a tag that no live session other than the sender has.
    static let noSessionHasTheTagReason = "No live session has the tag."

    /// The decision for a session id address.
    ///
    /// - Parameter target: The summary of the session with the id, live or
    ///   recorded.
    /// - Returns: Refused as archived with the session as its target, a
    ///   delivery to a live session, or a restore of a recorded one.
    fileprivate static func reaching(session target: SessionSummary) -> Self {
        guard target.state != .archived else { return .refused(reason: archivedReason, target: target.id) }
        return target.isLive ? .deliver([target.id]) : .restoreThenDeliver(target.id)
    }

    /// The decision for an agent address.
    ///
    /// - Parameters:
    ///   - agentID: The agent of the address.
    ///   - folder: The folder to look in, or `nil` for any folder.
    ///   - live: The live sessions.
    /// - Returns: A delivery to the newest live root session of the agent in
    ///   the folder, else a start of the agent in the folder.
    fileprivate static func reaching(
        agent agentID: String,
        in folder: URL?,
        among live: [SessionSummary]
    ) -> Self {
        guard let target = newestRoot(among: live, agentID: agentID, in: folder) else {
            return .startAgent(agentID: agentID, folder: folder)
        }
        return .deliver([target.id])
    }

    /// The decision for a folder address.
    ///
    /// - Parameters:
    ///   - folder: The folder of the address.
    ///   - live: The live sessions.
    /// - Returns: A delivery to the newest live root session of any agent in
    ///   the folder, else refused with the hint to name an agent and no
    ///   target.
    fileprivate static func reaching(folder: URL, among live: [SessionSummary]) -> Self {
        guard let target = newestRoot(among: live, agentID: nil, in: folder) else {
            return .refused(reason: noRootSessionInTheFolderReason, target: nil)
        }
        return .deliver([target.id])
    }

    /// The decision for a tag address. The directory never starts a session
    /// for a tag.
    ///
    /// - Parameters:
    ///   - tag: The tag of the address.
    ///   - sender: The session id of the sender, or `nil` for a user sender.
    ///   - live: The live sessions.
    /// - Returns: A delivery to each live session with the tag but the
    ///   sender, the oldest first, else one refusal with no target.
    fileprivate static func reaching(
        tag: String,
        from sender: ULID?,
        among live: [SessionSummary]
    ) -> Self {
        let targets = live
            .filter { $0.tags.contains(tag) && $0.id != sender }
            .map(\.id)
            .sorted()
        guard !targets.isEmpty else { return .refused(reason: noSessionHasTheTagReason, target: nil) }
        return .deliver(targets)
    }

    /// The newest live root session, of the agent when it is given, in the
    /// folder when it is given. A subagent or a fork never matches. Newest is
    /// ULID order, as in `RouterSessionDirectory.sessions(matching:)`.
    ///
    /// - Parameters:
    ///   - live: The live sessions.
    ///   - agentID: The agent, or `nil` for any agent.
    ///   - folder: The folder, or `nil` for any folder. It compares by
    ///     ``RouterSessionDirectory/comparablePath(of:)``.
    /// - Returns: The summary, or `nil` when none matches.
    private static func newestRoot(
        among live: [SessionSummary],
        agentID: String?,
        in folder: URL?
    ) -> SessionSummary? {
        let path = folder.map(RouterSessionDirectory.comparablePath(of:))
        return live
            .filter { summary in
                summary.kind == .root
                    && (agentID.map { $0 == summary.agentID } ?? true)
                    && (path.map { $0 == RouterSessionDirectory.comparablePath(of: summary.workingDirectory) } ?? true)
            }
            .max { $0.id < $1.id }
    }
}

extension SessionAddress {
    /// The decision of a send to this address, by the rules of session.md
    /// section 9.
    ///
    /// - A session sender must be a live or recorded session, for each
    ///   address: an unknown one throws, and is never read as a user.
    /// - A session id gives that session when it is live, a restore when it
    ///   is recorded, a refusal with the session as its target when it is
    ///   archived, and throws when no session has it (section 9: the session
    ///   must exist).
    /// - An agent gives its newest live root session in the folder of the
    ///   address, else in the working folder of a session sender. A user
    ///   sender has no folder, so an agent with no folder from a user matches
    ///   in any folder. With no match, the agent is started.
    /// - A folder gives its newest live root session of any agent, else a
    ///   refusal with the hint "Name an agent: @agent:/path.".
    /// - A tag gives each live session with the tag but the sender, else one
    ///   refusal.
    ///
    /// Folders compare with symbolic links resolved and no trailing `/`.
    ///
    /// - Parameters:
    ///   - sender: The sender of the message.
    ///   - live: The summaries of the live sessions.
    ///   - recordedSummary: The summary of a recorded session by its id, or
    ///     `nil` when no session on disk has the id.
    /// - Returns: The decision.
    /// - Throws: `SessionDirectoryError.unknownSession(_:)` with the id of a
    ///   session sender, or of a session id target, that no live or recorded
    ///   session has, as the FoundationModelsExtras send throws it.
    func resolution(
        from sender: SessionMessageSender,
        among live: [SessionSummary],
        recordedSummary: (ULID) -> SessionSummary?
    ) throws(SessionDirectoryError) -> SessionAddressResolution {
        func knownSummary(of id: ULID) throws(SessionDirectoryError) -> SessionSummary {
            guard let summary = live.first(where: { $0.id == id }) ?? recordedSummary(id) else {
                throw .unknownSession(id)
            }
            return summary
        }
        let senderSummary = try sender.sessionID.map(knownSummary(of:))
        switch self {
        case .session(let id):
            return .reaching(session: try knownSummary(of: id))
        case .agent(let agentID, let folder):
            return .reaching(agent: agentID, in: folder ?? senderSummary?.workingDirectory, among: live)
        case .folder(let folder):
            return .reaching(folder: folder, among: live)
        case .tag(let tag):
            return .reaching(tag: tag, from: senderSummary?.id, among: live)
        }
    }
}

extension SessionMessageSender {
    /// The session id of a session sender, or `nil` for a user sender.
    fileprivate var sessionID: ULID? {
        guard case .session(let id) = self else { return nil }
        return id
    }
}
