import Foundation
import FoundationModelsExtras

/// The facts of one session that change after it starts: its agent, its
/// tags, its title, who started it, how it started and when it was archived
/// (ROUTER-1).
///
/// A durable session keeps them in the frontmatter of the `index.md` in its
/// session folder, as part of its ``SessionRecord``, and rewrites that file
/// on each change.
public struct SessionFacts: Sendable, Equatable {
    /// The resolved id of the session's agent (D71): a catalog id (`default`
    /// for the root agent) or `folder:` plus the absolute path of a folder
    /// agent. Router stores it as given and never resolves it. `nil` when no
    /// agent was recorded.
    public var agentID: String?

    /// The display name of the agent, from the `name` key of its `AGENT.md`,
    /// or `nil`.
    public var agentName: String?

    /// The tags of the session.
    public var tags: Set<String>

    /// The title a user or a session gave the session, or `nil`.
    public var title: String?

    /// The session that started this root session (a tool, a message or a
    /// trigger), or `nil`. It is not a parent: the session is not a subagent.
    public var startedBy: ULID?

    /// How the root session started, or `nil` when it was not recorded.
    public var origin: FoundationModelsExtras.SessionDirectoryOrigin?

    /// The instant the session was archived (D68), or `nil` for a session
    /// that is not archived.
    public var archivedAt: Date?

    /// Makes the facts of a session. Every field defaults to its absent
    /// value.
    ///
    /// - Parameters:
    ///   - agentID: The resolved agent id. The default is `nil`.
    ///   - agentName: The display name of the agent. The default is `nil`.
    ///   - tags: The tags. The default is none.
    ///   - title: The title. The default is `nil`.
    ///   - startedBy: The session that started this one. The default is `nil`.
    ///   - origin: How the session started. The default is `nil`.
    ///   - archivedAt: The archive instant. The default is `nil`.
    public init(
        agentID: String? = nil,
        agentName: String? = nil,
        tags: Set<String> = [],
        title: String? = nil,
        startedBy: ULID? = nil,
        origin: FoundationModelsExtras.SessionDirectoryOrigin? = nil,
        archivedAt: Date? = nil
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.tags = tags
        self.title = title
        self.startedBy = startedBy
        self.origin = origin
        self.archivedAt = archivedAt
    }

    /// The first facts of a fork taken from a session with these facts: the
    /// agent id, the agent name and the tags of the source, origin
    /// ``FoundationModelsExtras/SessionDirectoryOrigin/fork``, and no title,
    /// no `startedBy` and no archive date.
    var forFork: SessionFacts {
        SessionFacts(agentID: agentID, agentName: agentName, tags: tags, origin: .fork)
    }
}
