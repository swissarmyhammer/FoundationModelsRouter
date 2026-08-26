import Foundation
import os

/// The logger that reports a dropped sidecar.
private let sessionSidecarLogger = makeModuleLogger(category: "SessionSidecar")

/// The sidecar's filename in a session's own recording directory.
let sessionSidecarFileName = "session.json"

/// One session's write-once sidecar: the primary facts about that session.
/// It is written into the session's recording directory at creation.
/// The directory nesting states the lineage. The session ULID states the
/// creation time.
public struct SessionSidecar: Codable, Sendable, Equatable {
    /// The concrete models that won each slot on the run that created this
    /// session. Recorded on root sessions only.
    public struct ResolvedProfile: Codable, Sendable, Equatable {
        /// The name of the ``ProfileDefinition`` this was resolved from.
        public let definitionName: String
        /// The concrete model chosen for the `.standard` slot.
        public let standard: ModelRef
        /// The concrete model chosen for the `.flash` slot.
        public let flash: ModelRef
        /// The concrete model chosen for the `.embedding` slot.
        public let embedding: ModelRef
        /// The working context, in tokens, shared by every slot.
        public let context: Int

        /// Creates a resolved-profile record.
        public init(
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
        /// The id of the session whose turn spawned this session.
        public let parentSessionId: ULID
        /// The tool-call id, in the parent's turn, that spawned this session.
        public let parentToolCallId: String

        /// Creates an agent-spawn record.
        public init(parentSessionId: ULID, parentToolCallId: String) {
            self.parentSessionId = parentSessionId
            self.parentToolCallId = parentToolCallId
        }
    }

    /// The model slot this session runs against.
    public let slot: ModelSlot
    /// The concrete model reference this session runs against.
    public let model: ModelRef
    /// The working context, in tokens, ``model`` was resolved at for ``slot``.
    public let context: Int
    /// This session's system instructions, or `nil`.
    public let instructions: String?
    /// This session's guided-generation grammar source, or `nil`.
    public let grammar: String?
    /// How much of this session's activity is recorded.
    public let recordingLevel: RecordingLevel
    /// The number of entries the parent's backend transcript held at fork
    /// time, or `nil` for a root session. Readers use it as the fork cut only
    /// when ``forkedAtHistoryOrdinal`` is `nil`.
    public let forkedAtEntryCount: Int?

    /// The fork's cut point in the parent's recorded history, in append-only
    /// coordinates. `nil` for a root session, and for a fork recorded before
    /// this field existed.
    public let forkedAtHistoryOrdinal: Int?
    /// The resolved profile of the run that created this session, or `nil`
    /// for a fork.
    public let profile: ResolvedProfile?
    /// The number of ``CompactionSegment`` checkpoints in this session's own
    /// recorded transcript, or `nil`. It is never written to disk.
    public let compactionCount: Int?

    /// This session's own working directory. When a recording has no
    /// `workingDirectory` key, `init(from:)` uses the recording directory.
    public let workingDirectory: URL

    /// The parent session and tool call that spawned this session, or `nil`.
    /// A fork's is always `nil`.
    public let agentSpawn: AgentSpawn?

    /// The recording root id of the router that created this session, or
    /// `nil` for a recording made before this field existed.
    public let routerId: ULID?

    /// The recording schema version. A recording with no `schemaVersion` key
    /// decodes as ``RecordingSchemaVersion/implicit``.
    public let schemaVersion: Int

    /// The configuration envelope this session was vended with, or `nil` for
    /// a recording made before the envelope existed.
    public let configuration: SessionConfiguration.Persistable?

    /// Creates a session sidecar.
    public init(
        slot: ModelSlot,
        model: ModelRef,
        context: Int,
        instructions: String?,
        grammar: String?,
        recordingLevel: RecordingLevel,
        forkedAtEntryCount: Int?,
        forkedAtHistoryOrdinal: Int? = nil,
        profile: ResolvedProfile?,
        workingDirectory: URL,
        agentSpawn: AgentSpawn? = nil,
        compactionCount: Int? = nil,
        routerId: ULID? = nil,
        schemaVersion: Int = RecordingSchemaVersion.current,
        configuration: SessionConfiguration.Persistable? = nil
    ) {
        self.slot = slot
        self.model = model
        self.context = context
        self.instructions = instructions
        self.grammar = grammar
        self.recordingLevel = recordingLevel
        self.forkedAtEntryCount = forkedAtEntryCount
        self.forkedAtHistoryOrdinal = forkedAtHistoryOrdinal
        self.profile = profile
        self.workingDirectory = workingDirectory
        self.agentSpawn = agentSpawn
        self.compactionCount = compactionCount
        self.routerId = routerId
        self.schemaVersion = schemaVersion
        self.configuration = configuration
    }

    /// The `JSONDecoder.userInfo` key that ``read(in:)`` sets to the session's
    /// recording directory, the fallback for an absent ``workingDirectory``.
    static let sidecarDirectoryUserInfoKey: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "SessionSidecar.sidecarDirectory") else {
            preconditionFailure("CodingUserInfoKey(rawValue:) cannot fail for a fixed, nonempty literal")
        }
        return key
    }()

    private enum CodingKeys: String, CodingKey {
        case slot, model, context, instructions, grammar, recordingLevel, forkedAtEntryCount,
            forkedAtHistoryOrdinal, profile, compactionCount, workingDirectory, agentSpawn,
            routerId, schemaVersion, configuration
    }

    /// Decodes a sidecar. An absent ``workingDirectory`` key defaults to the
    /// directory under ``sidecarDirectoryUserInfoKey`` in `decoder.userInfo`.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError.keyNotFound` when `workingDirectory` is
    ///   absent and no fallback directory is supplied.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slot = try container.decode(ModelSlot.self, forKey: .slot)
        model = try container.decode(ModelRef.self, forKey: .model)
        context = try container.decode(Int.self, forKey: .context)
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        grammar = try container.decodeIfPresent(String.self, forKey: .grammar)
        recordingLevel = try container.decode(RecordingLevel.self, forKey: .recordingLevel)
        forkedAtEntryCount = try container.decodeIfPresent(Int.self, forKey: .forkedAtEntryCount)
        forkedAtHistoryOrdinal = try container.decodeIfPresent(Int.self, forKey: .forkedAtHistoryOrdinal)
        profile = try container.decodeIfPresent(ResolvedProfile.self, forKey: .profile)
        compactionCount = try container.decodeIfPresent(Int.self, forKey: .compactionCount)
        agentSpawn = try container.decodeIfPresent(AgentSpawn.self, forKey: .agentSpawn)
        routerId = try container.decodeIfPresent(ULID.self, forKey: .routerId)
        configuration = try container.decodeIfPresent(
            SessionConfiguration.Persistable.self, forKey: .configuration)
        schemaVersion =
            try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? RecordingSchemaVersion.implicit
        if let recorded = try container.decodeIfPresent(URL.self, forKey: .workingDirectory) {
            workingDirectory = recorded
        } else if let fallback = decoder.userInfo[Self.sidecarDirectoryUserInfoKey] as? URL {
            workingDirectory = fallback
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.workingDirectory,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "workingDirectory is missing and no fallback directory was supplied via decoder.userInfo[SessionSidecar.sidecarDirectoryUserInfoKey]"
                )
            )
        }
    }

    /// Returns a copy with ``compactionCount`` replaced by `count`. The file
    /// on disk is not rewritten.
    func withCompactionCount(_ count: Int) -> SessionSidecar {
        SessionSidecar(
            slot: slot,
            model: model,
            context: context,
            instructions: instructions,
            grammar: grammar,
            recordingLevel: recordingLevel,
            forkedAtEntryCount: forkedAtEntryCount,
            forkedAtHistoryOrdinal: forkedAtHistoryOrdinal,
            profile: profile,
            workingDirectory: workingDirectory,
            agentSpawn: agentSpawn,
            compactionCount: count,
            routerId: routerId,
            schemaVersion: schemaVersion,
            configuration: configuration
        )
    }

    /// Creates `directory` and writes `sidecar` into it as `session.json`,
    /// exactly once. A second write to the same directory throws.
    ///
    /// - Parameters:
    ///   - sidecar: The facts to record.
    ///   - directory: The session's own recording directory.
    /// - Throws: If `directory` cannot be created, `sidecar` cannot be encoded,
    ///   or a `session.json` already exists there.
    public static func write(_ sidecar: SessionSidecar, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileURL = directory.appendingPathComponent(sessionSidecarFileName, isDirectory: false)
        // `.withoutOverwriting` is the exclusive create; it is deliberately not
        // paired with `.atomic`, which Foundation documents as incompatible
        // with it (an atomic write renames over whatever is already there,
        // which is exactly what must never happen to a write-once file).
        try encoder.encode(sidecar).write(to: fileURL, options: .withoutOverwriting)
    }

    /// Decodes the sidecar in a session's own recording directory.
    ///
    /// - Parameter directory: The session's recording directory.
    /// - Returns: The decoded sidecar, or `nil` when there is no `session.json`.
    /// - Throws: ``RecordingSchemaVersionError`` when ``schemaVersion`` is
    ///   newer than ``RecordingSchemaVersion/current``; otherwise a read or
    ///   decode error.
    public static func read(in directory: URL) throws -> SessionSidecar? {
        let fileURL = directory.appendingPathComponent(sessionSidecarFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.userInfo[sidecarDirectoryUserInfoKey] = directory
        let sidecar = try decoder.decode(SessionSidecar.self, from: try Data(contentsOf: fileURL))
        guard sidecar.schemaVersion <= RecordingSchemaVersion.current else {
            throw RecordingSchemaVersionError.recordingFromNewerRouter(
                directory: directory,
                version: sidecar.schemaVersion,
                supported: RecordingSchemaVersion.current
            )
        }
        return sidecar
    }
}

/// The durable transcripts root of a model handle, paired with the writer
/// its sessions write their sidecars through.
public struct DurableRecording: Sendable {
    /// The router's durable transcripts root.
    public let root: URL

    /// The writer every session under ``root`` records its sidecar through.
    public let sidecarWriter: SessionSidecarWriter

    /// Pairs a durable transcripts root with its sidecar writer.
    public init(root: URL, sidecarWriter: SessionSidecarWriter) {
        self.root = root
        self.sidecarWriter = sidecarWriter
    }
}

/// Writes each session's ``SessionSidecar`` when that session is created.
/// One writer belongs to one ``RoutedModel`` and carries the handle-level
/// facts. An ``RecordingLevel/off`` writer writes nothing. A failure is
/// logged and the sidecar is dropped.
public struct SessionSidecarWriter: Sendable {
    /// The slot every session written through this writer runs against.
    let slot: ModelSlot
    /// The concrete model every session written through this writer runs against.
    let model: ModelRef
    /// The working context, in tokens, ``model`` was resolved at for ``slot``.
    let context: Int
    /// How much of each session's activity is recorded.
    let recordingLevel: RecordingLevel
    /// The run's resolved profile, recorded onto root sessions only.
    let profile: SessionSidecar.ResolvedProfile?
    /// The recording root id of the router this writer belongs to.
    let routerId: ULID

    /// Creates a sidecar writer for one resolved model handle.
    public init(
        slot: ModelSlot,
        model: ModelRef,
        context: Int,
        recordingLevel: RecordingLevel,
        profile: SessionSidecar.ResolvedProfile?,
        routerId: ULID
    ) {
        self.slot = slot
        self.model = model
        self.context = context
        self.recordingLevel = recordingLevel
        self.profile = profile
        self.routerId = routerId
    }

    /// Writes one session's sidecar into its own directory and creates that
    /// directory. Logs and drops the sidecar on a failure. Writes nothing
    /// at ``RecordingLevel/off``. ``profile`` and `agentSpawn` are recorded
    /// only when `forkedAtEntryCount` is `nil` (a root session).
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The session's guided-generation grammar source, or `nil`.
    ///   - forkedAtEntryCount: The parent's backend transcript entry count at
    ///     fork time, or `nil` for a root session.
    ///   - forkedAtHistoryOrdinal: The fork's cut point in the parent's
    ///     recorded history, or `nil` for a root session.
    ///   - workingDirectory: The session's own working directory.
    ///   - agentSpawn: The spawn context, or `nil`.
    ///   - configuration: The configuration envelope, or `nil`.
    ///   - directory: The session's own recording directory.
    func write(
        instructions: String?,
        grammar: String?,
        forkedAtEntryCount: Int?,
        forkedAtHistoryOrdinal: Int?,
        workingDirectory: URL,
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        configuration: SessionConfiguration.Persistable? = nil,
        to directory: URL
    ) {
        // Nothing durable is recorded at `.off` — not a sidecar, and not a
        // transcript either, since the router's `GatingRecorder` drops every
        // event at this level. Returning before `SessionSidecar.write` is what
        // keeps that true: it is the sidecar write that would otherwise bring
        // the session's directory into existence.
        guard recordingLevel != .off else { return }

        let sidecar = SessionSidecar(
            slot: slot,
            model: model,
            context: context,
            instructions: instructions,
            grammar: grammar,
            recordingLevel: recordingLevel,
            forkedAtEntryCount: forkedAtEntryCount,
            forkedAtHistoryOrdinal: forkedAtHistoryOrdinal,
            profile: forkedAtEntryCount == nil ? profile : nil,
            workingDirectory: workingDirectory,
            agentSpawn: forkedAtEntryCount == nil ? agentSpawn : nil,
            routerId: routerId,
            configuration: configuration
        )
        do {
            try SessionSidecar.write(sidecar, to: directory)
        } catch {
            sessionSidecarLogger.error(
                "dropping session sidecar for \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Where a session's `session.json` comes from. Each builder of a
/// ``RoutedSessionActor`` states which case applies, and the actor writes
/// the sidecar or not. A ``RecordingLevel/off`` run is `.new` with a writer
/// that writes nothing.
enum SessionSidecarOrigin: Sendable {
    /// The session is new under a durable transcripts root. It writes its
    /// own sidecar through this writer when it is constructed.
    case new(SessionSidecarWriter)

    /// The session is a reconstruction of one already on disk. Its sidecar
    /// is read, never rewritten. The writer serves only the restored
    /// session's new forks.
    case restored(SessionSidecarWriter)

    /// Nothing is recorded durably. There is no sidecar to write.
    case memoryOnly

    /// The origin of a new session under `durableRecording`, or
    /// ``memoryOnly`` when `durableRecording` is `nil`.
    ///
    /// - Parameter durableRecording: The vending handle's durable recording, or
    ///   `nil` when it has none.
    /// - Returns: The new session's sidecar origin.
    static func new(under durableRecording: DurableRecording?) -> SessionSidecarOrigin {
        origin(under: durableRecording) { .new($0) }
    }

    /// The origin of a session restored from disk under `durableRecording`,
    /// or ``memoryOnly`` when `durableRecording` is `nil`.
    ///
    /// - Parameter durableRecording: The vending handle's durable recording, or
    ///   `nil` when it has none.
    /// - Returns: The restored session's sidecar origin.
    static func restored(under durableRecording: DurableRecording?) -> SessionSidecarOrigin {
        origin(under: durableRecording) { .restored($0) }
    }

    /// Maps a durable recording's sidecar writer through `wrap`, or yields
    /// ``memoryOnly`` when there is no durable recording.
    ///
    /// - Parameters:
    ///   - durableRecording: The vending handle's durable recording, or `nil`.
    ///   - wrap: Wraps the sidecar writer in the matching origin case.
    /// - Returns: The wrapped origin, or ``memoryOnly``.
    private static func origin(
        under durableRecording: DurableRecording?,
        wrappedBy wrap: (SessionSidecarWriter) -> SessionSidecarOrigin
    ) -> SessionSidecarOrigin {
        durableRecording.map { wrap($0.sidecarWriter) } ?? .memoryOnly
    }

    /// The origin of a fork taken from a session with this origin. A fork
    /// is always a new session, also when its parent is restored.
    var forFork: SessionSidecarOrigin {
        switch self {
        case .new(let writer), .restored(let writer):
            return .new(writer)
        case .memoryOnly:
            return .memoryOnly
        }
    }

    /// Writes the session's own sidecar when the origin is ``new(_:)``.
    /// Does nothing for a restored or memory-only session.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The session's guided-generation grammar source, or `nil`.
    ///   - forkedAtEntryCount: The parent's backend transcript entry count at
    ///     fork time, or `nil` for a root session.
    ///   - forkedAtHistoryOrdinal: The fork's cut point in the parent's
    ///     recorded history, or `nil` for a root session.
    ///   - workingDirectory: The session's own working directory.
    ///   - agentSpawn: The spawn context, or `nil`.
    ///   - configuration: The configuration envelope, or `nil`.
    ///   - directory: The session's own recording directory.
    func writeSidecarIfNew(
        instructions: String?,
        grammar: String?,
        forkedAtEntryCount: Int?,
        forkedAtHistoryOrdinal: Int?,
        workingDirectory: URL,
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        configuration: SessionConfiguration.Persistable? = nil,
        to directory: URL
    ) {
        guard case .new(let writer) = self else { return }
        writer.write(
            instructions: instructions,
            grammar: grammar,
            forkedAtEntryCount: forkedAtEntryCount,
            forkedAtHistoryOrdinal: forkedAtHistoryOrdinal,
            workingDirectory: workingDirectory,
            agentSpawn: agentSpawn,
            configuration: configuration,
            to: directory
        )
    }
}
