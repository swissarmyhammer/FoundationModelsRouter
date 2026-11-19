import Foundation
import FoundationModelsExtras

/// The facts of one session that change after it starts: its agent, its
/// tags, its title, who started it, how it started and when it was archived
/// (ROUTER-1), its last summary and its recap (D206), and where an imported
/// session came from (D209 (h)).
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

    /// The instant the host that owns the run marked the session as ended,
    /// or `nil` for a session that is not ended. It is not an archive: an
    /// ended session stays visible as history (``SessionEndedMarker``).
    public var endedAt: Date?

    /// Why the host marked the session as ended, or `nil` for a session that
    /// is not ended.
    public var endReason: SessionEndReason?

    /// The last final reply of the session, cut to
    /// ``SessionStateTracking/lastSummaryLength`` characters (ROUTER-9,
    /// D206), or `nil` before the first answer. The directory writes it at
    /// the end of each turn that changed it, so a recorded session gives it
    /// after a restart.
    public var lastSummary: String?

    /// The recap of the session (D206): one sentence that tells what the
    /// session did and where it stands, or `nil` when the session has no
    /// recap.
    public var recap: String?

    /// The instant the directory made ``recap``, or `nil` when the session
    /// has no recap.
    public var recapAt: Date?

    /// Where an imported session came from (D209 (h)): the agent, the
    /// source session and the time of the import, or `nil` for a session
    /// that was not imported. The record writes it under the flat key
    /// `importedFrom`, and a record with no such key reads it as `nil`.
    ///
    /// The facts hold each date of the provenance rounded to the nearest
    /// millisecond, the precision of the record, as the directory rounds
    /// ``archivedAt``, ``endedAt`` and ``recapAt``. The initializer and each
    /// set round the dates (``RecordedImportProvenance/rounded(_:)``), so a
    /// live session gives the same provenance as its record after a
    /// restart.
    public var importedFrom: SessionImportProvenance? {
        didSet { importedFrom = importedFrom.map(RecordedImportProvenance.rounded) }
    }

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
    ///   - endedAt: The instant of the ended marker. The default is `nil`.
    ///   - endReason: The reason of the ended marker. The default is `nil`.
    ///   - lastSummary: The last summary. The default is `nil`.
    ///   - recap: The recap. The default is `nil`.
    ///   - recapAt: The instant of the recap. The default is `nil`.
    ///   - importedFrom: Where an imported session came from, with its
    ///     dates rounded to the nearest millisecond. The default is `nil`.
    public init(
        agentID: String? = nil,
        agentName: String? = nil,
        tags: Set<String> = [],
        title: String? = nil,
        startedBy: ULID? = nil,
        origin: FoundationModelsExtras.SessionDirectoryOrigin? = nil,
        archivedAt: Date? = nil,
        endedAt: Date? = nil,
        endReason: SessionEndReason? = nil,
        lastSummary: String? = nil,
        recap: String? = nil,
        recapAt: Date? = nil,
        importedFrom: SessionImportProvenance? = nil
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.tags = tags
        self.title = title
        self.startedBy = startedBy
        self.origin = origin
        self.archivedAt = archivedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.lastSummary = lastSummary
        self.recap = recap
        self.recapAt = recapAt
        self.importedFrom = importedFrom.map(RecordedImportProvenance.rounded)
    }

    /// The first facts of a fork of a session with these facts (D205): the
    /// agent id and the agent name of the source, and the origin
    /// ``FoundationModelsExtras/SessionDirectoryOrigin/fork``. A fork gets no
    /// tags, no `startedBy`, no archive date and no provenance of an import
    /// of its source, as the fork of the Extras in-memory directory does. A fork also gets no last summary
    /// and no recap of its source (D206): its own turns make them. Its title
    /// is the fork name that
    /// the directory gives it when it registers
    /// (``RouterSessionDirectory/fork(_:)``).
    var forFork: SessionFacts {
        SessionFacts(agentID: agentID, agentName: agentName, origin: .fork)
    }
}
