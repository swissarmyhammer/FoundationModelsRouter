import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The pure resolver that turns the address of a send into a decision
/// (ROUTER-4, the addressing table of session.md section 9): the live
/// targets, a recorded session to restore, an agent to start, or a refusal
/// with its reason.
///
/// Each test builds the summaries by hand: no session runs. Only the link
/// test makes a real folder, because a symbolic link must exist on disk to
/// resolve.
@Suite("SessionAddressResolution: the address rules of session.md section 9")
struct SessionAddressResolutionTests {
    /// One row of the addressing table: a sender, an address, and the
    /// decision that the resolver must give for them.
    struct Row: Sendable, CustomTestStringConvertible {
        /// What the row checks, as the test report shows it.
        let name: String

        /// The sender of the message.
        let sender: SessionMessageSender

        /// The address of the message.
        let address: SessionAddress

        /// The decision that the resolver must give.
        let expected: SessionAddressResolution

        /// The name of the row.
        var testDescription: String { name }
    }

    /// A real folder and a symbolic link to it, in a fresh temp directory
    /// that the test removes with ``remove()``, usually in a `defer`.
    struct LinkedFolder {
        /// The temp directory that holds the folder and the link.
        let scratch = RouterTestFixtures.makeTempDir(prefix: "SessionAddressResolutionTests")

        /// The real folder.
        let folder: URL

        /// The symbolic link to ``folder``.
        let link: URL

        /// Makes the folder and the link.
        ///
        /// - Throws: The error of the file manager when it cannot make them.
        init() throws {
            folder = scratch.appendingPathComponent("real", isDirectory: true)
            link = scratch.appendingPathComponent("link", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        }

        /// Removes the temp directory and all that it holds.
        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }
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
    /// session of the coder, and still no agent address may pick it.
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

    // MARK: - The table

    /// One row for each rule of the addressing table.
    static let rows: [Row] = sessionRows + agentRows + folderRows + tagRows

    /// The rows of a session id address.
    static let sessionRows: [Row] = [
        Row(
            name: "a live session id gives that session",
            sender: fromUser, address: .session(newerCoder.id), expected: .deliver([newerCoder.id])),
        Row(
            name: "a recorded session id that is not live is restored, then delivered",
            sender: fromUser, address: .session(recorded.id), expected: .restoreThenDeliver(recorded.id)),
        Row(
            name: "an archived session id is refused as archived",
            sender: fromReviewer, address: .session(archived.id), expected: .refused(reason: "archived")),
        Row(
            name: "an unknown session id is refused as unknown",
            sender: fromReviewer, address: .session(unknownID), expected: .refused(reason: "unknown session")),
    ]

    /// The rows of an agent address.
    static let agentRows: [Row] = [
        Row(
            name: "an agent with a folder gives its newest live root session in that folder",
            sender: fromUser, address: .agent(id: coder, folder: project), expected: .deliver([newerCoder.id])),
        Row(
            name: "an agent with another folder gives its root session in that folder",
            sender: fromReviewer, address: .agent(id: coder, folder: other), expected: .deliver([elsewhereCoder.id])),
        Row(
            name: "an agent with no folder from a session looks in the folder of the sender",
            sender: fromReviewer, address: .agent(id: coder, folder: nil), expected: .deliver([newerCoder.id])),
        Row(
            name: "an agent with no folder from a user gives its newest live root session in any folder",
            sender: fromUser, address: .agent(id: coder, folder: nil), expected: .deliver([elsewhereCoder.id])),
        Row(
            name: "an agent with no live root session in the folder is started there",
            sender: fromReviewer, address: .agent(id: coder, folder: empty),
            expected: .startAgent(agentID: coder, folder: empty)),
        Row(
            name: "an agent with no live session and no folder from a session is started in the folder of the sender",
            sender: fromReviewer, address: .agent(id: absentAgent, folder: nil),
            expected: .startAgent(agentID: absentAgent, folder: project)),
        Row(
            name: "an agent with no live session and no folder from a user is started with no folder",
            sender: fromUser, address: .agent(id: absentAgent, folder: nil),
            expected: .startAgent(agentID: absentAgent, folder: nil)),
        Row(
            name: "an agent with only a subagent and a fork has no root session and is started",
            sender: fromUser, address: .agent(id: helper, folder: nil),
            expected: .startAgent(agentID: helper, folder: nil)),
    ]

    /// The rows of a folder address.
    static let folderRows: [Row] = [
        Row(
            name: "a folder gives its newest live root session of any agent, not a newer subagent or fork",
            sender: fromUser, address: .folder(project), expected: .deliver([reviewer.id])),
        Row(
            name: "another folder gives its one live root session",
            sender: fromReviewer, address: .folder(other), expected: .deliver([elsewhereCoder.id])),
        Row(
            name: "a folder with no session is refused with the hint to name an agent",
            sender: fromReviewer, address: .folder(empty),
            expected: .refused(reason: "Name an agent: @agent:/path.")),
        Row(
            name: "a folder with only a subagent and a fork is refused with the hint to name an agent",
            sender: fromUser, address: .folder(nested),
            expected: .refused(reason: "Name an agent: @agent:/path.")),
    ]

    /// The rows of a tag address.
    static let tagRows: [Row] = [
        Row(
            name: "a tag gives each live session with the tag but the sender, the oldest first",
            sender: fromReviewer, address: .tag(team), expected: .deliver([olderCoder.id, subagent.id])),
        Row(
            name: "a tag from a user gives each live session with the tag",
            sender: fromUser, address: .tag(team), expected: .deliver([olderCoder.id, reviewer.id, subagent.id])),
        Row(
            name: "a tag that no session has is refused once",
            sender: fromUser, address: .tag(absentTag),
            expected: .refused(reason: "No live session has the tag.")),
        Row(
            name: "a tag that only the sender has is refused once",
            sender: fromReviewer, address: .tag(lead),
            expected: .refused(reason: "No live session has the tag.")),
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
    /// - Returns: The decision of the resolver.
    static func resolve(
        _ address: SessionAddress,
        from sender: SessionMessageSender,
        among live: [SessionSummary] = live
    ) -> SessionAddressResolution {
        address.resolution(from: sender, among: live) { recordedByID[$0] }
    }

    // MARK: - Tests

    /// Each row of the addressing table gives its decision and reason text.
    @Test(arguments: rows)
    func eachRowOfTheAddressingTableGivesItsDecision(_ row: Row) {
        #expect(Self.resolve(row.address, from: row.sender) == row.expected)
    }

    /// A folder address and an agent address match the session through a
    /// symbolic link to its folder, and with a trailing `/`.
    @Test func aLinkAndATrailingSlashMatchTheSameFolder() throws {
        let linked = try LinkedFolder()
        defer { linked.remove() }
        let withSlash = URL(fileURLWithPath: linked.folder.path + "/")
        let session = Self.summary(starting: .olderCoder, agentID: Self.coder, in: linked.folder)

        let addresses: [SessionAddress] = [
            .folder(linked.link), .folder(withSlash), .agent(id: Self.coder, folder: linked.link),
            .agent(id: Self.coder, folder: withSlash),
        ]
        let decisions = addresses.map { Self.resolve($0, from: Self.fromUser, among: [session]) }

        #expect(decisions == Array(repeating: .deliver([session.id]), count: addresses.count))
    }

    /// An agent address with no folder from a session sender looks in the
    /// folder of the sender through a link to it.
    @Test func theFolderOfTheSenderMatchesThroughALink() throws {
        let linked = try LinkedFolder()
        defer { linked.remove() }
        let target = Self.summary(starting: .olderCoder, agentID: Self.coder, in: linked.folder)
        let sender = Self.summary(starting: .reviewer, agentID: Self.reviewerAgent, in: linked.link)

        let decision = Self.resolve(
            .agent(id: Self.coder, folder: nil), from: .session(sender.id), among: [target, sender])

        #expect(decision == .deliver([target.id]))
    }
}
