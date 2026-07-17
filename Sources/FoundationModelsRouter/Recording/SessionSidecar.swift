import Foundation
import os

/// The logger ``SessionSidecarWriter`` reports a dropped sidecar to, mirroring
/// ``JSONLRecorder``'s log-and-drop failure policy (see
/// Sources/FoundationModelsRouter/Recording/Sinks.swift).
private let sessionSidecarLogger = makeModuleLogger(category: "SessionSidecar")

/// The sidecar's filename within a session's own recording directory
/// (`recordings/<routerId>/<sessionId>/session.json`), shared by the write and
/// read paths so the name is kept in exactly one place.
let sessionSidecarFileName = "session.json"

/// One session's write-once sidecar: the primary facts about that session,
/// written into its own recording directory at the moment it is created and
/// never rewritten.
///
/// This is the whole of a router's non-transcript on-disk state. Everything
/// recorded is either write-once (this) or append-only (`transcript.jsonl`), so
/// a checked-in recording tree only ever grows — no file is edited in place, no
/// shared file collects records from every session (see plan.md's "Transcript
/// fidelity" section).
///
/// **Only primary facts.** A session's lineage is stated by the directory
/// nesting — a root lives at `<routerId>/<rootId>/`, its fork at
/// `.../<rootId>/<forkId>/`, a grandfork one level deeper — and its creation
/// time by its ULID's own timestamp (see `Core/ULID.swift`). Neither is
/// restated here: a fact recorded twice is a fact that can disagree with
/// itself.
///
/// ``instructions``/``grammar`` are recorded (not merely implied by transcript
/// content) so ``RoutedModel/restoreSessionTree(root:registry:)`` can rehydrate
/// a restored session's actor state without replaying its transcript: `grammar`
/// in particular changes the behavior of every future `respond` and exists
/// nowhere else on disk.
public struct SessionSidecar: Codable, Sendable, Equatable {
    /// Which concrete models won each slot for *this* machine on the run that
    /// created this session — recorded on root sessions only.
    ///
    /// A run's resolution is a property of the run, not of each session in it,
    /// so it is stated once per recorded tree (on the tree's root) rather than
    /// repeated into every fork's sidecar.
    public struct ResolvedProfile: Codable, Sendable, Equatable {
        /// The name of the ``ProfileDefinition`` this was resolved from.
        public let definitionName: String
        /// The concrete model chosen for the `.standard` generation slot.
        public let standard: ModelRef
        /// The concrete model chosen for the `.flash` generation slot.
        public let flash: ModelRef
        /// The concrete model chosen for the `.embedding` slot.
        public let embedding: ModelRef
        /// The working context, in tokens, this profile's slots were resolved
        /// at — the authored ``ProfileDefinition/context`` verbatim when
        /// explicit, or the rung ``JointFit``'s context ladder settled on when
        /// it was `nil`. Every slot shares this one figure (context is one
        /// profile-wide parameter), so it is recorded once here rather than
        /// per slot.
        public let context: Int

        /// Creates a resolved-profile record.
        ///
        /// - Parameters:
        ///   - definitionName: The authored profile's name.
        ///   - standard: The chosen `.standard` model.
        ///   - flash: The chosen `.flash` model.
        ///   - embedding: The chosen `.embedding` model.
        ///   - context: The working context, in tokens, resolved for this run.
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

    /// The model slot this session runs against.
    public let slot: ModelSlot
    /// The concrete model reference this session runs against.
    public let model: ModelRef
    /// The working context, in tokens, ``model`` was resolved at for ``slot``.
    public let context: Int
    /// This session's system instructions, or `nil`.
    public let instructions: String?
    /// This session's guided-generation grammar source, or `nil` for an
    /// unconstrained session.
    public let grammar: String?
    /// How much of this session's activity is recorded.
    public let recordingLevel: RecordingLevel
    /// How many entries the parent's transcript held at fork time — the
    /// parent's ``LanguageModelSessionBackend/transcriptEntries()`` count at
    /// the moment this session was forked from it, which is also the fork's own
    /// transcript-diff baseline (see ``RoutedSessionActor/persistedEntryCount``),
    /// so the lineage cut point and the diff baseline are one fact, not two.
    ///
    /// `nil` for a root session: a session with no parent has nothing to cut.
    public let forkedAtEntryCount: Int?
    /// Which concrete models won each slot on the run that created this
    /// session, or `nil` for a fork (see ``ResolvedProfile``).
    public let profile: ResolvedProfile?

    /// Creates a session sidecar.
    ///
    /// - Parameters:
    ///   - slot: The model slot this session runs against.
    ///   - model: The concrete model reference.
    ///   - context: The working context, in tokens, `model` was resolved at.
    ///   - instructions: This session's system instructions, or `nil`.
    ///   - grammar: This session's guided-generation grammar source, or `nil`.
    ///   - recordingLevel: How much of this session's activity is recorded.
    ///   - forkedAtEntryCount: The parent's transcript entry count at fork
    ///     time, or `nil` for a root session.
    ///   - profile: The run's resolved-profile facts for a root session, or
    ///     `nil` for a fork.
    public init(
        slot: ModelSlot,
        model: ModelRef,
        context: Int,
        instructions: String?,
        grammar: String?,
        recordingLevel: RecordingLevel,
        forkedAtEntryCount: Int?,
        profile: ResolvedProfile?
    ) {
        self.slot = slot
        self.model = model
        self.context = context
        self.instructions = instructions
        self.grammar = grammar
        self.recordingLevel = recordingLevel
        self.forkedAtEntryCount = forkedAtEntryCount
        self.profile = profile
    }

    /// Creates `directory` and writes `sidecar` into it as `session.json`,
    /// exactly once.
    ///
    /// Write-once is enforced by the filesystem rather than by a check-then-write
    /// (which two concurrent forks could both pass): the create is exclusive, so
    /// a second write to a directory that already has a sidecar throws and the
    /// original bytes stand.
    ///
    /// - Parameters:
    ///   - sidecar: The facts to record.
    ///   - directory: The session's own recording directory, created here along
    ///     with the sidecar — this is the call that brings a session's directory
    ///     into existence, before any transcript event can land in it.
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
    /// - Returns: The decoded sidecar, or `nil` when `directory` holds no
    ///   `session.json` at all — the caller decides whether an absent sidecar is
    ///   benign (a directory that is not a session's) or an error (a session
    ///   directory whose sidecar was deleted).
    /// - Throws: If a `session.json` exists but cannot be read or decoded.
    public static func read(in directory: URL) throws -> SessionSidecar? {
        let fileURL = directory.appendingPathComponent(sessionSidecarFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(SessionSidecar.self, from: try Data(contentsOf: fileURL))
    }
}

/// Where a model handle's sessions record durably, and the writer their
/// `session.json` sidecars go through — one value, because neither half is
/// usable without the other.
///
/// A durable transcripts root paired with a missing sidecar writer records a
/// tree ``TranscriptTree/load(under:)`` refuses to read: a transcript with no
/// sidecar beside it carries no facts to interpret it by. Two independent
/// optionals on ``RoutedModel`` made that state not just possible but the
/// default — it was what a caller got by passing a root and mentioning nothing
/// else. Pairing them makes it unspeakable: hold a root, and you hold the writer
/// that keeps it loadable.
///
/// ``RecordingLevel/off`` is not this type's concern. A run recording nothing
/// still has a root to nest its sessions' working directories under, and it is
/// the writer that declines to write at that level (see ``SessionSidecarWriter``).
public struct DurableRecording: Sendable {
    /// The router's durable transcripts root. A session's own recording
    /// directory nests under it by router id and session id.
    public let root: URL

    /// The writer every session under ``root`` records its `session.json`
    /// through.
    public let sidecarWriter: SessionSidecarWriter

    /// Pairs a durable transcripts root with the sidecar writer that keeps what
    /// lands under it loadable.
    ///
    /// - Parameters:
    ///   - root: The router's durable transcripts root.
    ///   - sidecarWriter: The writer sessions under `root` record through.
    public init(root: URL, sidecarWriter: SessionSidecarWriter) {
        self.root = root
        self.sidecarWriter = sidecarWriter
    }
}

/// Writes each session's ``SessionSidecar`` as that session is created, from a
/// resolved model handle's own facts.
///
/// One writer is born per ``RoutedModel`` (see ``Router``), carrying everything
/// about the session that comes from the *handle* — its slot, its concrete
/// model, the context that model was resolved at, the run's recording level,
/// and the run's resolved-profile facts. Each creation site supplies only what
/// is about the *session*: its instructions, its grammar, its fork cut point,
/// and its directory. A vended session and every fork taken from it share one
/// writer, so those handle-level facts cannot drift between them.
///
/// A writer exists wherever there is a durable transcripts root to write into —
/// it travels with that root as one ``DurableRecording`` value, so a root can
/// never be paired with a missing writer. ``RecordingLevel/off`` is the writer's
/// own business rather than its builder's: an `.off` writer writes nothing, the
/// same way the router's ``GatingRecorder`` drops every event at that level. The
/// two must agree — ``TranscriptTree/load(under:)`` refuses a transcript with no
/// sidecar beside it — and they agree because both read the one level.
///
/// Unlike ``TranscriptRecorder``, it needs no ``GatingRecorder``-style wrapping
/// at ``RecordingLevel/metadataOnly``, since a sidecar carries no turn content to
/// trim (see plan.md's "Transcript fidelity" section).
///
/// Writing is best-effort, mirroring ``JSONLRecorder``: any failure is logged
/// and the sidecar dropped, so a full disk can never fail a `makeSession` or a
/// `fork`.
public struct SessionSidecarWriter: Sendable {
    /// The slot every session written through this writer runs against.
    let slot: ModelSlot
    /// The concrete model every session written through this writer runs
    /// against.
    let model: ModelRef
    /// The working context, in tokens, ``model`` was resolved at for ``slot``.
    let context: Int
    /// How much of each session's activity is recorded.
    let recordingLevel: RecordingLevel
    /// The run's resolved-profile facts, recorded onto root sessions only.
    let profile: SessionSidecar.ResolvedProfile?

    /// Creates a sidecar writer for one resolved model handle.
    ///
    /// - Parameters:
    ///   - slot: The slot sessions vended from that handle run against.
    ///   - model: The concrete model they run against.
    ///   - context: The working context, in tokens, `model` was resolved at.
    ///   - recordingLevel: How much of each session's activity is recorded.
    ///   - profile: The run's resolved-profile facts, recorded onto roots.
    public init(
        slot: ModelSlot,
        model: ModelRef,
        context: Int,
        recordingLevel: RecordingLevel,
        profile: SessionSidecar.ResolvedProfile?
    ) {
        self.slot = slot
        self.model = model
        self.context = context
        self.recordingLevel = recordingLevel
        self.profile = profile
    }

    /// Writes one session's sidecar into its own directory, creating that
    /// directory; logs and drops it on any failure.
    ///
    /// The run's ``profile`` facts are attached to root sessions only — a
    /// session with no cut point is a root — so the rule lives here rather than
    /// at each creation site. ``RecordingLevel/off`` is honored here for the
    /// same reason: one gate, rather than one per creation site or per builder.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The session's guided-generation grammar source, or `nil`.
    ///   - forkedAtEntryCount: The parent's transcript entry count at fork
    ///     time, or `nil` for a root session.
    ///   - directory: The session's own recording directory.
    func write(instructions: String?, grammar: String?, forkedAtEntryCount: Int?, to directory: URL) {
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
            profile: forkedAtEntryCount == nil ? profile : nil
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

/// Where a session's `session.json` comes from — the one thing a
/// ``RoutedSessionActor`` needs to know to keep its own directory loadable.
///
/// A session lands its own sidecar as it comes into existence, so whoever builds
/// one — ``RoutedModel/makeSession(grammar:instructions:workingDirectory:)``,
/// ``RoutedSessionActor/fork(workingDirectory:)``, or a harness assembling an
/// actor by hand because it needs the backend object itself — cannot record a
/// durable session directory holding a transcript and no sidecar beside it, the
/// tree ``TranscriptTree/load(under:)`` refuses to read. It was a bare
/// `SessionSidecarWriter?` and a separate hand-typed `write(...)` call that made
/// that state reachable by *forgetting*; naming the origin makes each builder
/// state which of the three cases it is in, and the actor do the rest.
///
/// A ``RecordingLevel/off`` run is not a case here: it is `.new` carrying a
/// writer that writes nothing (see ``SessionSidecarWriter``).
enum SessionSidecarOrigin: Sendable {
    /// The session is coming into existence now under a durable transcripts
    /// root — a vended root or a fork — and writes its own write-once sidecar
    /// through this writer as it is constructed, before it exists to record any
    /// transcript into its directory.
    case new(SessionSidecarWriter)

    /// The session is a reconstruction of one already on disk (see
    /// ``RoutedModel/restoreSessionTree(root:registry:)``): its sidecar was
    /// written when the tree was first created and is write-once, so it is read,
    /// never rewritten. The writer travels only for the restored session's own
    /// new forks.
    case restored(SessionSidecarWriter)

    /// Nothing is recorded durably: the router has no transcripts root, so there
    /// is no sidecar to write and none for a fork of this session to write
    /// either.
    case memoryOnly

    /// The origin of a session coming into existence now under
    /// `durableRecording`, or ``memoryOnly`` when the router records to
    /// memory/none.
    ///
    /// - Parameter durableRecording: The vending handle's durable recording, or
    ///   `nil` when it has none.
    /// - Returns: The new session's sidecar origin.
    static func new(under durableRecording: DurableRecording?) -> SessionSidecarOrigin {
        origin(under: durableRecording) { .new($0) }
    }

    /// The origin of a session reconstructed from disk under `durableRecording`,
    /// or ``memoryOnly`` when the router records to memory/none.
    ///
    /// The restored session's write-once sidecar is already on disk, so the
    /// writer travels only for the forks the restored session takes.
    ///
    /// - Parameter durableRecording: The vending handle's durable recording, or
    ///   `nil` when it has none.
    /// - Returns: The restored session's sidecar origin.
    static func restored(under durableRecording: DurableRecording?) -> SessionSidecarOrigin {
        origin(under: durableRecording) { .restored($0) }
    }

    /// The shared body behind ``new(under:)`` and ``restored(under:)``: maps a
    /// durable recording's write-once sidecar writer through `wrap` into the
    /// matching origin case, or yields ``memoryOnly`` when the router records to
    /// memory/none.
    ///
    /// The two named factories carry distinct semantics in their own doc
    /// comments but the same shape; this holds that shape in one place.
    ///
    /// - Parameters:
    ///   - durableRecording: The vending handle's durable recording, or `nil`
    ///     when it has none.
    ///   - wrap: Wraps the recording's sidecar writer in the origin case that
    ///     matches how the session came to be (``new(_:)`` vs ``restored(_:)``).
    /// - Returns: The wrapped origin, or ``memoryOnly`` when there is no
    ///   durable recording.
    private static func origin(
        under durableRecording: DurableRecording?,
        wrappedBy wrap: (SessionSidecarWriter) -> SessionSidecarOrigin
    ) -> SessionSidecarOrigin {
        durableRecording.map { wrap($0.sidecarWriter) } ?? .memoryOnly
    }

    /// The origin a session created *from* a session with this origin has.
    ///
    /// A fork is a brand-new session wherever its parent could record one, so it
    /// writes its own sidecar through the same writer — including a fork of a
    /// *restored* session, which is new even though its parent is not.
    var forFork: SessionSidecarOrigin {
        switch self {
        case .new(let writer), .restored(let writer):
            return .new(writer)
        case .memoryOnly:
            return .memoryOnly
        }
    }

    /// Writes the session's own sidecar when the session is new; does nothing for
    /// a restored session (whose write-once sidecar is already on disk) or a
    /// memory-only one (which records nothing).
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - grammar: The session's guided-generation grammar source, or `nil`.
    ///   - forkedAtEntryCount: The parent's transcript entry count at fork time,
    ///     or `nil` for a root session.
    ///   - directory: The session's own recording directory.
    func writeSidecarIfNew(
        instructions: String?,
        grammar: String?,
        forkedAtEntryCount: Int?,
        to directory: URL
    ) {
        guard case .new(let writer) = self else { return }
        writer.write(
            instructions: instructions,
            grammar: grammar,
            forkedAtEntryCount: forkedAtEntryCount,
            to: directory
        )
    }
}
