import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The pure resolver that turns the address of a send into a decision
/// (ROUTER-4): the live
/// targets, a recorded session that gets a file in its inbox, an agent to start, a refusal
/// with its reason and target, or the `unknownSession` error of the
/// FoundationModelsExtras send contract for an unknown sender or target.
///
/// Each test builds the summaries by hand: no session runs.
@Suite("SessionAddressResolution: the address rules")
struct SessionAddressResolutionTests {
    /// The decision of the resolver, or the error that it throws.
    typealias Outcome = Result<SessionAddressResolution, SessionDirectoryError>

    /// One row of the addressing table: a sender, an address, and the
    /// decision that the resolver must give for them.
    struct Row: Sendable, CustomTestStringConvertible {
        /// What the row checks, as the test report shows it.
        let name: String

        /// The sender of the message.
        let sender: SessionMessageSender

        /// The address of the message.
        let address: SessionAddress

        /// The decision that the resolver must give, or the error that it
        /// must throw.
        let expected: Outcome

        /// The name of the row.
        var testDescription: String { name }
    }

    /// The start second of each hand-built session. The order of the starts
    /// is the order of the ids, so a later case is a newer session.
    enum Start: Int {
        case olderCoder = 1
        case newerCoder
        case elsewhereCoder
        case reviewer
        case subagent
        case fork
        case helperSubagent
        case helperFork
        case recorded
        case archived
        case unknown
    }

    // MARK: - Folders

    /// The folder where most hand-built sessions work.
    static let project = URL(fileURLWithPath: "/work/project", isDirectory: true)

    /// A second folder, where one root session of the coder works.
    static let other = URL(fileURLWithPath: "/work/other", isDirectory: true)

    /// A folder where only a subagent and a fork work: no root session.
    static let nested = URL(fileURLWithPath: "/work/nested", isDirectory: true)

    /// A folder where no session works.
    static let empty = URL(fileURLWithPath: "/work/empty", isDirectory: true)

    // MARK: - Agents and tags

    /// The agent with root sessions in two folders.
    static let coder = "coder"

    /// The agent of the reviewer session.
    static let reviewerAgent = "reviewer"

    /// The agent of the subagent and the fork in ``nested``: it has no root
    /// session.
    static let helper = "helper"

    /// An agent with no session at all.
    static let absentAgent = "tester"

    /// The tag of several live sessions, the reviewer among them.
    static let team = "team"

    /// The tag that only the reviewer has.
    static let lead = "lead"

    /// A tag that no session has.
    static let absentTag = "nobody"

    // MARK: - Sessions

    /// The older live root session of the coder in ``project``, with ``team``.
    static let olderCoder = summary(starting: .olderCoder, agentID: coder, in: project, tags: [team])

    /// The newer live root session of the coder in ``project``.
    static let newerCoder = summary(starting: .newerCoder, agentID: coder, in: project)

    /// The live root session of the coder in ``other``: the newest root
    /// session of the coder in any folder.
    static let elsewhereCoder = summary(starting: .elsewhereCoder, agentID: coder, in: other)

    /// The live root session of the reviewer in ``project``: the newest root
    /// session in that folder. It sends most of the messages of the table.
    static let reviewer = summary(starting: .reviewer, agentID: reviewerAgent, in: project, tags: [team, lead])

    /// A live subagent of the coder in ``project``, newer than each root
    /// session there, with ``team``.
    static let subagent = summary(starting: .subagent, agentID: coder, in: project, tags: [team], kind: .subagent)

    /// A live fork of the coder in ``project``, newer than each root session
    /// there.
    static let fork = summary(starting: .fork, agentID: coder, in: project, kind: .fork)

    /// A live subagent of the helper in ``nested``.
    static let helperSubagent = summary(starting: .helperSubagent, agentID: helper, in: nested, kind: .subagent)

    /// A live fork of the helper in ``nested``.
    static let helperFork = summary(starting: .helperFork, agentID: helper, in: nested, kind: .fork)

    /// A recorded session of the coder that is not live. It is the newest
    /// root session in ``project``.
    static let recorded = summary(starting: .recorded, agentID: coder, in: project, isLive: false)

    /// An archived session of the coder.
    static let archived = summary(starting: .archived, agentID: coder, in: project, state: .archived, isLive: false)

    /// An id that no session has.
    static let unknownID = ULID(timestamp: startDate(of: .unknown))

    /// The live sessions, in no order of time: the resolver orders them.
    static let live = [newerCoder, helperFork, reviewer, olderCoder, fork, elsewhereCoder, subagent, helperSubagent]

    /// The recorded sessions that are not live, by id.
    static let recordedByID = [recorded.id: recorded, archived.id: archived]

    /// The reviewer as the sender.
    static let fromReviewer = SessionMessageSender.session(reviewer.id)

    /// A user through a UI as the sender.
    static let fromUser = SessionMessageSender.user(clientID: "ui")

    /// A session sender that no live or recorded session is.
    static let fromUnknownSession = SessionMessageSender.session(unknownID)

    // MARK: - The table

    /// One row for each rule of the addressing table.
    static let rows: [Row] = sessionRows + agentRows + tagRows + unknownSenderRows

    /// The rows of a session id address.
    static let sessionRows: [Row] = [
        Row(
            name: "a live session id gives that session",
            sender: fromUser, address: .session(newerCoder.id), expected: .success(.deliver([newerCoder.id]))),
        Row(
            name: "a recorded session id that is not live gets the message in its inbox, with no restore",
            sender: fromUser, address: .session(recorded.id), expected: .success(.sendToRecorded(recorded.id))),
        Row(
            name: "an archived session id gets the message in its inbox, as a recorded one, with no restore",
            sender: fromReviewer, address: .session(archived.id), expected: .success(.sendToRecorded(archived.id))),
        Row(
            name: "an unknown session id throws unknownSession with the id",
            sender: fromReviewer, address: .session(unknownID), expected: .failure(.unknownSession(unknownID))),
    ]

    /// The rows of an agent address. An agent address always starts a new
    /// root session of the agent (D199 (e)). It never delivers to a live
    /// session of the agent, because the client resolves the slug of a
    /// session before it sends to an agent.
    static let agentRows: [Row] = [
        Row(
            name: "an agent with a folder is started there, also when it has a live root session there",
            sender: fromUser, address: .agent(id: coder, folder: project),
            expected: .success(.startAgent(agentID: coder, folder: project))),
        Row(
            name: "an agent with a folder where no session works is started there",
            sender: fromReviewer, address: .agent(id: coder, folder: empty),
            expected: .success(.startAgent(agentID: coder, folder: empty))),
        Row(
            name: "an agent with no folder from a session is started in the folder of the sender, also when it has a live root session there",
            sender: fromReviewer, address: .agent(id: coder, folder: nil),
            expected: .success(.startAgent(agentID: coder, folder: project))),
        Row(
            name: "an agent with no folder from a user is started with no folder, also when it has live root sessions",
            sender: fromUser, address: .agent(id: coder, folder: nil),
            expected: .success(.startAgent(agentID: coder, folder: nil))),
        Row(
            name: "an agent with no live session and no folder from a user is started with no folder",
            sender: fromUser, address: .agent(id: absentAgent, folder: nil),
            expected: .success(.startAgent(agentID: absentAgent, folder: nil))),
    ]

    /// The rows of a tag address.
    static let tagRows: [Row] = [
        Row(
            name: "a tag gives each live session with the tag but the sender, the oldest first",
            sender: fromReviewer, address: .tag(team), expected: .success(.deliver([olderCoder.id, subagent.id]))),
        Row(
            name: "a tag from a user gives each live session with the tag",
            sender: fromUser, address: .tag(team),
            expected: .success(.deliver([olderCoder.id, reviewer.id, subagent.id]))),
        Row(
            name: "a tag that no session has is refused once, with no target",
            sender: fromUser, address: .tag(absentTag),
            expected: .success(.refused(reason: "No live session has the tag.", target: nil))),
        Row(
            name: "a tag that only the sender has is refused once, with no target",
            sender: fromReviewer, address: .tag(lead),
            expected: .success(.refused(reason: "No live session has the tag.", target: nil))),
    ]

    /// The rows of a session sender that no live or recorded session is:
    /// each address throws `unknownSession` with the id of the sender, as
    /// the FoundationModelsExtras send does, and never reads it as a user.
    static let unknownSenderRows: [Row] = [
        Row(
            name: "an unknown session sender to a live session id throws unknownSession with the sender id",
            sender: fromUnknownSession, address: .session(newerCoder.id),
            expected: .failure(.unknownSession(unknownID))),
        Row(
            name: "an unknown session sender to an agent with no folder throws unknownSession with the sender id",
            sender: fromUnknownSession, address: .agent(id: coder, folder: nil),
            expected: .failure(.unknownSession(unknownID))),
        Row(
            name: "an unknown session sender to a tag throws unknownSession with the sender id",
            sender: fromUnknownSession, address: .tag(team),
            expected: .failure(.unknownSession(unknownID))),
    ]

    // MARK: - Builders

    /// The start time of a hand-built session.
    ///
    /// - Parameter start: The start of the session.
    /// - Returns: The time, ``Start/rawValue`` seconds after 1970.
    static func startDate(of start: Start) -> Date {
        Date(timeIntervalSince1970: TimeInterval(start.rawValue))
    }

    /// A hand-built summary.
    ///
    /// - Parameters:
    ///   - start: The start of the session, which orders its id.
    ///   - agentID: The agent of the session.
    ///   - folder: The working folder.
    ///   - tags: The tags. The default is none.
    ///   - kind: The kind. The default is a root session.
    ///   - state: The work state. The default is idle.
    ///   - isLive: True for a session in memory. The default is true.
    /// - Returns: The summary.
    static func summary(
        starting start: Start,
        agentID: String,
        in folder: URL,
        tags: Set<String> = [],
        kind: SessionKind = .root,
        state: SessionState = .idle,
        isLive: Bool = true
    ) -> SessionSummary {
        let startedAt = startDate(of: start)
        return SessionSummary(
            id: ULID(timestamp: startedAt),
            agentID: agentID,
            workingDirectory: folder,
            tags: tags,
            kind: kind,
            state: state,
            origin: .client,
            createdAt: startedAt,
            updatedAt: startedAt,
            isLive: isLive)
    }

    /// Resolves an address against the hand-built sessions.
    ///
    /// - Parameters:
    ///   - address: The address.
    ///   - sender: The sender.
    ///   - live: The live sessions. The default is ``live``.
    /// - Returns: The decision of the resolver, or the error that it threw.
    static func resolve(
        _ address: SessionAddress,
        from sender: SessionMessageSender,
        among live: [SessionSummary] = live
    ) -> Outcome {
        Result { () throws(SessionDirectoryError) in
            try address.resolution(from: sender, among: live) { recordedByID[$0] }
        }
    }

    // MARK: - Tests

    /// Each row of the addressing table gives its decision and reason text,
    /// or throws its error.
    @Test(arguments: rows)
    func eachRowOfTheAddressingTableGivesItsDecision(_ row: Row) {
        #expect(Self.resolve(row.address, from: row.sender) == row.expected)
    }

    /// The production change that makes this test fail: a resolver that
    /// delivers to a live session whose record holds `archivedAt`, so the
    /// message starts a turn of an archived session.
    @Test func aLiveArchivedSessionIDGetsTheMessageInItsInbox() {
        let liveArchived = Self.summary(starting: .archived, agentID: Self.coder, in: Self.project, state: .archived)

        let decision = Self.resolve(.session(liveArchived.id), from: Self.fromUser, among: [liveArchived])

        #expect(decision == .success(.sendToRecorded(liveArchived.id)))
    }

    /// The production change that makes this test fail: a resolver that
    /// sends an agent address to a live archived session of the agent (D199
    /// (e)).
    @Test func anAgentWhoseOnlySessionIsArchivedIsStarted() {
        let liveArchived = Self.summary(starting: .archived, agentID: Self.coder, in: Self.project, state: .archived)

        let decision = Self.resolve(
            .agent(id: Self.coder, folder: Self.project), from: Self.fromUser, among: [liveArchived])

        #expect(decision == .success(.startAgent(agentID: Self.coder, folder: Self.project)))
    }

}
