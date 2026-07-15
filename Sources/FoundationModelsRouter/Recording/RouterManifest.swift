import Foundation

/// The recording root's manifest: the durable record of *this router run* that
/// sits beside the session transcripts at `recordings/<routerId>/manifest.json`.
///
/// While each session's `transcript.jsonl` records what happened within a span,
/// the manifest records the run that produced them — the router's configuration,
/// every profile it resolved, and the wall-clock span it covered. It is written
/// by the ``Router`` (never through a session recorder) whenever a profile
/// resolves, so it always reflects the run so far.
///
/// The type is `Codable` in both directions and encodes one self-contained JSON
/// object — the on-disk form the router writes to `manifest.json`.
public struct RouterManifest: Sendable, Codable, Equatable {
    /// The router configuration a run was carried out under.
    ///
    /// The knobs that shape a run's behavior and residency, captured so a
    /// transcript reader can see the settings the sessions ran against.
    public struct Config: Sendable, Codable, Equatable {
        /// Bytes held out of the RAM budget for OS/app headroom.
        public let headroomReserve: Int64
        /// The in-flight fork-session ceiling per resolved profile.
        public let maxConcurrentForks: Int
        /// How much of each session's activity is recorded.
        public let recordingLevel: RecordingLevel

        /// Creates a config record.
        ///
        /// - Parameters:
        ///   - headroomReserve: Bytes held out of the RAM budget.
        ///   - maxConcurrentForks: The in-flight fork-session ceiling per profile.
        ///   - recordingLevel: How much of each session's activity is recorded.
        public init(headroomReserve: Int64, maxConcurrentForks: Int, recordingLevel: RecordingLevel) {
            self.headroomReserve = headroomReserve
            self.maxConcurrentForks = maxConcurrentForks
            self.recordingLevel = recordingLevel
        }
    }

    /// A profile the router resolved during the run, recording which concrete
    /// models won each slot for *this* machine.
    public struct ResolvedProfile: Sendable, Codable, Equatable {
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
        /// per slot, letting a coding-harness frontend display what context
        /// this run actually resolved to.
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

    /// The recording root id — the router instance this manifest describes.
    public let routerId: ULID
    /// The configuration the run was carried out under.
    public let config: Config
    /// Every profile resolved during the run, in resolution order.
    public let profiles: [ResolvedProfile]
    /// When the router was constructed — the run's start.
    public let start: Date
    /// When the manifest was last written — the run's end so far.
    public let end: Date

    /// Creates a manifest.
    ///
    /// - Parameters:
    ///   - routerId: The recording root id.
    ///   - config: The configuration the run was carried out under.
    ///   - profiles: Every profile resolved during the run.
    ///   - start: The run's start instant.
    ///   - end: The run's end-so-far instant.
    public init(
        routerId: ULID,
        config: Config,
        profiles: [ResolvedProfile],
        start: Date,
        end: Date
    ) {
        self.routerId = routerId
        self.config = config
        self.profiles = profiles
        self.start = start
        self.end = end
    }
}
