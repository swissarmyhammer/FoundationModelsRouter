import Foundation
import FoundationModelsExtras

/// One recorded session, as the YAML frontmatter of the `index.md` in its
/// session folder holds it (``SessionIndexFile``).
///
/// The record replaces the write-once `session.json` and the mutable
/// `facts.json` of earlier recordings, and the `sessions.jsonl` listing. It
/// holds three kinds of fields:
///
/// - **The facts** (ROUTER-1): ``facts``, written flat at the top level of
///   the frontmatter: `agentID`, `agentName`, `origin`, `startedBy`, `tags`,
///   `title` and `archivedAt`.
/// - **The listing data**: ``sessionId`` (the name of the folder),
///   ``workingDirectory`` (the key `cwd`, a path), ``updatedAt``,
///   ``additionalDirectories``, the fork parent and its cut
///   (``forkParentId``, ``forkedAtEntryCount``, ``forkedAtHistoryOrdinal``)
///   and ``firstActivityAt``. A host lists the sessions of a recording root
///   from these with ``RouterSessionDirectory/recordedSessions(in:)``.
/// - **The restore data**: the model and the profile, the instructions, the
///   grammar, the spawn, the router id, the configuration envelope, the
///   recording level and the compaction count.
///
/// Each date is ISO 8601 text in UTC with milliseconds, the text of the
/// Extras `DateTime`, as every other date Router writes to disk. A date in
/// memory is rounded to the millisecond before it is stored, so a record
/// reads back equal to the one that was saved.
public struct SessionRecord: Codable, Sendable, Equatable {
    /// The concrete models that won each slot on the run that created this
    /// session. Recorded on root sessions only.
    package struct ResolvedProfile: Codable, Sendable, Equatable {
        /// The name of the ``ProfileDefinition`` this was resolved from.
        let definitionName: String
        /// The concrete model chosen for the `.standard` slot.
        let standard: ModelRef
        /// The concrete model chosen for the `.flash` slot.
        let flash: ModelRef
        /// The concrete model chosen for the `.embedding` slot.
        let embedding: ModelRef
        /// The working context, in tokens, shared by every slot.
        let context: Int

        /// Creates a resolved-profile record.
        init(
            definitionName: String,
            standard: ModelRef,
            flash: ModelRef,
            embedding: ModelRef,
            context: Int
        ) {
            self.definitionName = definitionName
            self.standard = standard
            self.flash = flash
            self.embedding = embedding
            self.context = context
        }
    }

    /// The parent session and the tool call that spawned this session.
    public struct AgentSpawn: Codable, Sendable, Equatable {
        /// The id of the session whose submission spawned this session.
        public let parentSessionId: ULID
        /// The tool-call id, in the submission of the parent, that spawned this session.
        public let parentToolCallId: String

        /// Creates an agent-spawn record.
        public init(parentSessionId: ULID, parentToolCallId: String) {
            self.parentSessionId = parentSessionId
            self.parentToolCallId = parentToolCallId
        }
    }

    // MARK: - Listing data

    /// The id of the session: the name of its session folder.
    public internal(set) var sessionId: ULID

    /// The working folder of the session. The frontmatter holds its path
    /// under the key `cwd`.
    public internal(set) var workingDirectory: URL

    /// The instant of the last activity of the session: its creation, then
    /// the start of each submission.
    public internal(set) var updatedAt: Date

    /// The instant the first submission of the session started, or `nil`
    /// while the session has had no prompt. A listing for a client can leave
    /// out the sessions where it is `nil`.
    public internal(set) var firstActivityAt: Date?

    /// The folders a host added to the working folder of the session, in
    /// the order it gave them.
    public internal(set) var additionalDirectories: [URL]

    /// The session this session was forked from, or `nil` for a root.
    public internal(set) var forkParentId: ULID?

    /// The number of entries the parent's backend transcript held at fork
    /// time, or `nil` for a root session. Readers use it as the fork cut only
    /// when ``forkedAtHistoryOrdinal`` is `nil`.
    public internal(set) var forkedAtEntryCount: Int?

    /// The fork's cut point in the parent's recorded history, in append-only
    /// coordinates, or `nil` for a root session.
    public internal(set) var forkedAtHistoryOrdinal: Int?

    // MARK: - Facts

    /// The facts of the session that change after it starts (ROUTER-1).
    public internal(set) var facts: SessionFacts

    // MARK: - Restore data

    /// The model slot this session runs against.
    public internal(set) var slot: ModelSlot

    /// The concrete model reference this session runs against.
    public internal(set) var model: ModelRef

    /// The working context, in tokens, ``model`` was resolved at for ``slot``.
    public internal(set) var context: Int

    /// The system instructions of the session, or `nil`.
    public internal(set) var instructions: String?

    /// The source of the guided-generation grammar of the session, or `nil`.
    public internal(set) var grammar: String?

    /// How much of the activity of the session is recorded.
    public internal(set) var recordingLevel: RecordingLevel

    /// The parent session and tool call that spawned this session, or `nil`.
    /// A fork's is always `nil`.
    public internal(set) var agentSpawn: AgentSpawn?

    /// The recording root id of the router that created this session.
    public internal(set) var routerId: ULID

    /// The number of ``CompactionSegment`` checkpoints in this session's own
    /// recorded transcript.
    public internal(set) var compactionCount: Int

    /// The resolved profile of the run that created this session, or `nil`
    /// for a fork.
    var profile: ResolvedProfile?

    /// The configuration envelope this session was vended with, or `nil`.
    var configuration: SessionConfiguration.Persistable?

    /// The recording schema version of the session's transcript.
    var schemaVersion: Int

    /// Creates a record. Each date is stored rounded to the millisecond, the
    /// precision of the frontmatter.
    ///
    /// - Parameters:
    ///   - sessionId: The id of the session.
    ///   - workingDirectory: The working folder of the session.
    ///   - updatedAt: The instant of the last activity.
    ///   - slot: The model slot.
    ///   - model: The concrete model.
    ///   - context: The working context, in tokens.
    ///   - recordingLevel: How much is recorded.
    ///   - routerId: The recording root id of the creating router.
    ///   - facts: The facts. The default is empty facts.
    ///   - firstActivityAt: The start of the first submission, or `nil`.
    ///   - additionalDirectories: The added folders. The default is none.
    ///   - forkParentId: The fork parent, or `nil`.
    ///   - forkedAtEntryCount: The fork cut in backend entries, or `nil`.
    ///   - forkedAtHistoryOrdinal: The fork cut in recorded history, or `nil`.
    ///   - instructions: The system instructions, or `nil`.
    ///   - grammar: The grammar source, or `nil`.
    ///   - profile: The resolved profile, or `nil`.
    ///   - agentSpawn: The spawn context, or `nil`.
    ///   - configuration: The configuration envelope, or `nil`.
    ///   - compactionCount: The compactions. The default is none.
    ///   - schemaVersion: The recording schema version. The default is
    ///     ``RecordingSchemaVersion/current``.
    init(
        sessionId: ULID,
        workingDirectory: URL,
        updatedAt: Date,
        slot: ModelSlot,
        model: ModelRef,
        context: Int,
        recordingLevel: RecordingLevel,
        routerId: ULID,
        facts: SessionFacts = SessionFacts(),
        firstActivityAt: Date? = nil,
        additionalDirectories: [URL] = [],
        forkParentId: ULID? = nil,
        forkedAtEntryCount: Int? = nil,
        forkedAtHistoryOrdinal: Int? = nil,
        instructions: String? = nil,
        grammar: String? = nil,
        profile: ResolvedProfile? = nil,
        agentSpawn: AgentSpawn? = nil,
        configuration: SessionConfiguration.Persistable? = nil,
        compactionCount: Int = 0,
        schemaVersion: Int = RecordingSchemaVersion.current
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.updatedAt = MillisecondDate.rounded(updatedAt)
        self.firstActivityAt = firstActivityAt.map(MillisecondDate.rounded)
        self.additionalDirectories = additionalDirectories
        self.forkParentId = forkParentId
        self.forkedAtEntryCount = forkedAtEntryCount
        self.forkedAtHistoryOrdinal = forkedAtHistoryOrdinal
        self.facts = facts
        self.slot = slot
        self.model = model
        self.context = context
        self.instructions = instructions
        self.grammar = grammar
        self.recordingLevel = recordingLevel
        self.agentSpawn = agentSpawn
        self.routerId = routerId
        self.compactionCount = compactionCount
        self.profile = profile
        self.configuration = configuration
        self.schemaVersion = schemaVersion
    }

    /// Marks the start of a submission at `instant`: it moves ``updatedAt``
    /// to it, and sets ``firstActivityAt`` to it when the session had no
    /// submission yet.
    ///
    /// - Parameter instant: The start of the submission.
    mutating func recordActivity(at instant: Date) {
        let rounded = MillisecondDate.rounded(instant)
        updatedAt = rounded
        firstActivityAt = firstActivityAt ?? rounded
    }

    // MARK: - Coding

    /// The keys of the frontmatter. The facts are flat, beside the other
    /// keys, and the working folder is `cwd`.
    private enum CodingKeys: String, CodingKey {
        case sessionId
        case workingDirectory = "cwd"
        case updatedAt, firstActivityAt, additionalDirectories
        case forkParentId, forkedAtEntryCount, forkedAtHistoryOrdinal
        case agentID, agentName, origin, startedBy, tags, title, archivedAt
        case slot, model, context, instructions, grammar, recordingLevel, agentSpawn, routerId
        case compactionCount, profile, configuration, schemaVersion
    }

    /// Decodes a record from its frontmatter. An absent `tags`,
    /// `additionalDirectories` or `compactionCount` key is none; each other
    /// optional key that is absent is `nil`.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: A decoding error when a required key is absent, a key holds
    ///   the wrong type, or a date is not ISO 8601 text in UTC with
    ///   milliseconds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(ULID.self, forKey: .sessionId)
        workingDirectory = try container.decodePath(forKey: .workingDirectory)
        updatedAt = try container.decodeMillisecondDate(forKey: .updatedAt)
        firstActivityAt = try container.decodeMillisecondDateIfPresent(forKey: .firstActivityAt)
        additionalDirectories = try container.decodePathsIfPresent(forKey: .additionalDirectories)
        forkParentId = try container.decodeIfPresent(ULID.self, forKey: .forkParentId)
        forkedAtEntryCount = try container.decodeIfPresent(Int.self, forKey: .forkedAtEntryCount)
        forkedAtHistoryOrdinal = try container.decodeIfPresent(Int.self, forKey: .forkedAtHistoryOrdinal)
        facts = try Self.decodeFacts(from: container)
        slot = try container.decode(ModelSlot.self, forKey: .slot)
        model = try container.decode(ModelRef.self, forKey: .model)
        context = try container.decode(Int.self, forKey: .context)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        grammar = try container.decodeIfPresent(String.self, forKey: .grammar)
        recordingLevel = try container.decode(RecordingLevel.self, forKey: .recordingLevel)
        agentSpawn = try container.decodeIfPresent(AgentSpawn.self, forKey: .agentSpawn)
        routerId = try container.decode(ULID.self, forKey: .routerId)
        compactionCount = try container.decodeIfPresent(Int.self, forKey: .compactionCount) ?? 0
        profile = try container.decodeIfPresent(ResolvedProfile.self, forKey: .profile)
        configuration = try container.decodeIfPresent(SessionConfiguration.Persistable.self, forKey: .configuration)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    }

    /// Decodes the flat fact keys of the frontmatter.
    ///
    /// - Parameter container: The container of the frontmatter.
    /// - Returns: The facts.
    /// - Throws: A decoding error when a fact key holds the wrong type.
    private static func decodeFacts(from container: KeyedDecodingContainer<CodingKeys>) throws -> SessionFacts {
        SessionFacts(
            agentID: try container.decodeIfPresent(String.self, forKey: .agentID),
            agentName: try container.decodeIfPresent(String.self, forKey: .agentName),
            tags: try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? [],
            title: try container.decodeIfPresent(String.self, forKey: .title),
            startedBy: try container.decodeIfPresent(ULID.self, forKey: .startedBy),
            origin: try container.decodeIfPresent(
                FoundationModelsExtras.SessionDirectoryOrigin.self, forKey: .origin),
            archivedAt: try container.decodeMillisecondDateIfPresent(forKey: .archivedAt))
    }

    /// Encodes the record as its frontmatter: the facts flat, the folders as
    /// paths, the tags sorted, each date as text with milliseconds, and no
    /// key for an absent value.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: What the encoder throws.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(Self.path(of: workingDirectory), forKey: .workingDirectory)
        try container.encode(MillisecondDate.text(of: updatedAt), forKey: .updatedAt)
        try container.encodeIfPresent(firstActivityAt.map(MillisecondDate.text(of:)), forKey: .firstActivityAt)
        try container.encode(additionalDirectories.map(Self.path(of:)), forKey: .additionalDirectories)
        try container.encodeIfPresent(forkParentId, forKey: .forkParentId)
        try container.encodeIfPresent(forkedAtEntryCount, forKey: .forkedAtEntryCount)
        try container.encodeIfPresent(forkedAtHistoryOrdinal, forKey: .forkedAtHistoryOrdinal)
        try encodeFacts(into: &container)
        try container.encode(slot, forKey: .slot)
        try container.encode(model, forKey: .model)
        try container.encode(context, forKey: .context)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(grammar, forKey: .grammar)
        try container.encode(recordingLevel, forKey: .recordingLevel)
        try container.encodeIfPresent(agentSpawn, forKey: .agentSpawn)
        try container.encode(routerId, forKey: .routerId)
        try container.encode(compactionCount, forKey: .compactionCount)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }

    /// Encodes the facts as flat keys of the frontmatter.
    ///
    /// - Parameter container: The container of the frontmatter.
    /// - Throws: What the encoder throws.
    private func encodeFacts(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(facts.agentID, forKey: .agentID)
        try container.encodeIfPresent(facts.agentName, forKey: .agentName)
        try container.encodeIfPresent(facts.origin, forKey: .origin)
        try container.encodeIfPresent(facts.startedBy, forKey: .startedBy)
        try container.encode(facts.tags.sorted(), forKey: .tags)
        try container.encodeIfPresent(facts.title, forKey: .title)
        try container.encodeIfPresent(facts.archivedAt.map(MillisecondDate.text(of:)), forKey: .archivedAt)
    }

    /// The path a folder is written as: the path with no percent encoding,
    /// with its trailing `/` when the URL names a directory.
    ///
    /// - Parameter folder: A file URL.
    /// - Returns: The path.
    private static func path(of folder: URL) -> String {
        folder.path(percentEncoded: false)
    }

    /// The file URL of a path the frontmatter holds, the inverse of
    /// ``path(of:)``: a path that ends in `/` names a directory.
    ///
    /// - Parameter path: A path.
    /// - Returns: The file URL.
    fileprivate static func folder(atPath path: String) -> URL {
        URL(filePath: path, directoryHint: .inferFromPath)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a date from ISO 8601 text in UTC with milliseconds
    /// (``MillisecondDate``).
    ///
    /// - Parameter key: The key of the text.
    /// - Returns: The date.
    /// - Throws: `DecodingError.dataCorrupted` when the text is not that
    ///   form, or the error of the decode of the text.
    fileprivate func decodeMillisecondDate(forKey key: Key) throws -> Date {
        try millisecondDate(fromText: try decode(String.self, forKey: key), forKey: key)
    }

    /// Decodes a date as ``decodeMillisecondDate(forKey:)`` does, or `nil`
    /// when the key is absent.
    ///
    /// - Parameter key: The key of the text.
    /// - Returns: The date, or `nil`.
    /// - Throws: What ``decodeMillisecondDate(forKey:)`` throws.
    fileprivate func decodeMillisecondDateIfPresent(forKey key: Key) throws -> Date? {
        guard let text = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return try millisecondDate(fromText: text, forKey: key)
    }

    /// The date of `text`, read as ``MillisecondDate`` reads it.
    ///
    /// - Parameters:
    ///   - text: The text of the key.
    ///   - key: The key, for the error.
    /// - Returns: The date.
    /// - Throws: `DecodingError.dataCorrupted` when the text is not ISO 8601
    ///   in UTC with milliseconds.
    private func millisecondDate(fromText text: String, forKey key: Key) throws -> Date {
        guard let date = MillisecondDate.date(fromText: text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: MillisecondDate.notMillisecondTextDescription)
        }
        return date
    }

    /// Decodes a folder from its path.
    ///
    /// - Parameter key: The key of the path.
    /// - Returns: The file URL of the path.
    /// - Throws: The error of the decode of the path.
    fileprivate func decodePath(forKey key: Key) throws -> URL {
        SessionRecord.folder(atPath: try decode(String.self, forKey: key))
    }

    /// Decodes a list of folders from their paths, or none when the key is
    /// absent.
    ///
    /// - Parameter key: The key of the paths.
    /// - Returns: The file URLs of the paths.
    /// - Throws: The error of the decode of the paths.
    fileprivate func decodePathsIfPresent(forKey key: Key) throws -> [URL] {
        (try decodeIfPresent([String].self, forKey: key) ?? []).map(SessionRecord.folder(atPath:))
    }
}
