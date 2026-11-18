import Foundation
import FoundationModelsExtras

/// What a send does with the address of a message (ROUTER-4): the live sessions that get the
/// message, a recorded or archived session that gets the message as a file in
/// its inbox, a new session of an agent to start, or the reason and target of a refusal.
///
/// ``FoundationModelsExtras/SessionAddress/resolution(from:among:recordedSummary:)``
/// gives the decision. It is pure: it reads only the summaries it is given,
/// and it starts, writes and delivers nothing. The send acts on it: it
/// delivers, writes the inbox file of a recorded session (ROUTER-5), or
/// starts a root session with origin `message` through the launcher
/// (ROUTER-8). A send never restores a session.
///
/// An unknown session is not a decision: as the FoundationModelsExtras send
/// contract says, the resolver throws `SessionDirectoryError.unknownSession`
/// for a session sender or a session id target that no live or recorded
/// session has, and the send lets that error out.
enum SessionAddressResolution: Sendable, Equatable {
    /// Deliver the message to each of these live sessions, in this order.
    case deliver([ULID])

    /// Write the message as a file in the `inbox/` folder of this recorded
    /// session that is not live, or of this archived session, live or not,
    /// and restore nothing. The scan of the inbox delivers the file when a
    /// host opens the session, and for an archived session only after its
    /// unarchive (D204).
    case sendToRecorded(ULID)

    /// Start a new root session of the agent, with the message as its first
    /// message. The folder is the folder of the address, else the folder of
    /// the sender session, else `nil` for a user sender with no folder.
    case startAgent(agentID: String, folder: URL?)

    /// Refuse the send with this reason, the text of
    /// `SessionSendReceipt.reason`, for this target, the
    /// `SessionSendReceipt.target`: the session that matched the address, or
    /// `nil` when no session matched it.
    case refused(reason: String, target: ULID?)

    /// The reason for a folder with no live root session: a folder alone does
    /// not name an agent (D61).
    static let noRootSessionInTheFolderReason = "Name an agent: @agent:/path."

    /// The reason for a tag that no live session other than the sender has.
    static let noSessionHasTheTagReason = "No live session has the tag."

    /// The decision for a session id address.
    ///
    /// - Parameter target: The summary of the session with the id, live or
    ///   recorded.
    /// - Returns: An inbox file for an archived session, live or not, as for
    ///   a recorded one (D204), a delivery to a live session, or an inbox
    ///   file for a recorded one.
    fileprivate static func reaching(session target: SessionSummary) -> Self {
        guard target.isLive, target.state != .archived else { return .sendToRecorded(target.id) }
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
        guard let target = newestRoot(among: live, in: folder) else {
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

    /// The newest live root session of any agent in the folder. A subagent
    /// or a fork never matches. Newest is ULID order, as in
    /// `RouterSessionDirectory.sessions(matching:)`.
    ///
    /// - Parameters:
    ///   - live: The live sessions.
    ///   - folder: The folder. It compares by
    ///     ``RouterSessionDirectory/comparablePath(of:)``.
    /// - Returns: The summary, or `nil` when none matches.
    private static func newestRoot(among live: [SessionSummary], in folder: URL) -> SessionSummary? {
        let path = RouterSessionDirectory.comparablePath(of: folder)
        return live
            .filter { $0.kind == .root && RouterSessionDirectory.comparablePath(of: $0.workingDirectory) == path }
            .max { $0.id < $1.id }
    }
}

extension SessionAddress {
    /// The decision of a send to this address.
    ///
    /// - A session sender must be a live or recorded session, for each
    ///   address: an unknown one throws, and is never read as a user.
    /// - A session id gives that session when it is live, an inbox file when
    ///   it is recorded or archived (D204), and throws when no session has it
    ///   (section 9: the session must exist). An archived session that a
    ///   client opened is live, and it still gets an inbox file, so the
    ///   message starts no turn.
    /// - An agent always gives a start of a new root session of the agent
    ///   (D199 (e)), also when a session of the agent is live. The client
    ///   resolves the slug of a session before it sends to an agent, so the
    ///   directory does not look for a live session of the agent. The folder
    ///   of the start is the folder of the address, else the working folder
    ///   of a session sender, else `nil` for a user sender.
    /// - A folder gives its newest live root session of any agent, else a
    ///   refusal with the hint "Name an agent: @agent:/path.".
    /// - A tag gives each live session with the tag but the sender, else one
    ///   refusal.
    ///
    /// A folder address compares folders with symbolic links resolved and no
    /// trailing `/`.
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
            return .startAgent(agentID: agentID, folder: folder ?? senderSummary?.workingDirectory)
        case .folder(let folder):
            return .reaching(folder: folder, among: live)
        case .tag(let tag):
            return .reaching(tag: tag, from: senderSummary?.id, among: live)
        }
    }
}

extension SessionMessageSender {
    /// The session id of a session sender, or `nil` for a user sender.
    var sessionID: ULID? {
        guard case .session(let id) = self else { return nil }
        return id
    }
}
