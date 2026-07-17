import Foundation
import FoundationModels
import os

/// The logger ``RecordingLanguageModelState`` reports a defensively-clamped
/// transcript shrink to (see ``RecordingLanguageModelState/diffAndRecord(current:)``)
/// — mirrors ``RoutedSessionActor``'s own `sessionRecordingLogger` in
/// Session/RoutedSession.swift, kept as a separate constant since that one is
/// `private` to its own file.
private let recordingLanguageModelLogger = makeModuleLogger(category: "Recording")

/// A `FoundationModels.LanguageModel` conformer any caller can build a
/// `LanguageModelSession(model:tools:instructions:)` over directly and get
/// recording, serial gating, and tool-calling support with zero session
/// plumbing.
///
/// Vended only by ``RoutedModel/makeLanguageModel()`` — there is no public
/// initializer — each call mints a fresh handle carrying its own per-handle
/// state (``RecordingLanguageModelState``): a session ULID, a recording
/// directory nested the same way ``RoutedModel/makeSession(instructions:workingDirectory:)``'s
/// is, and a last-seen ``FoundationModels/Transcript`` snapshot. Two live
/// handles never interleave events or share a directory.
///
/// Generation passes straight through to the wrapped model's own executor —
/// `Wrapped.Executor(configuration: wrapped.executorConfiguration).respond(to:model:streamingInto:)`,
/// called with the OUTER channel unmodified — so streaming, reasoning, and
/// tool-calling events flow untouched; this handle never delegates through a
/// nested `LanguageModelSession` (which would execute tool calls itself and
/// break tool-using turns) and never reads the channel back (`Event` is
/// write-only). On every call it diffs the request's transcript against
/// last-seen (via ``TranscriptDiffer``, the same diff implementation
/// ``RoutedSessionActor`` uses) and records whatever is new.
///
/// The turn-final response is not observable at the executor boundary (only
/// the request's *input* transcript is visible on any one call), so
/// ``sync(_:)`` closes that gap: call it with `session.transcript` at turn
/// end to record the final response. Any later `respond` call on the same
/// session back-fills automatically via the diff, so mid-turn records are
/// complete even without `sync`; `sync` matters for the last turn before
/// idle/exit, and is idempotent — a transcript already fully reflected in the
/// last diff produces an empty diff and records nothing.
public struct RecordingLanguageModel: LanguageModel, Sendable {
    /// This handle's per-call mutable state and identity.
    let state: RecordingLanguageModelState

    /// Creates a handle over `state`. Internal: the only way to obtain one is
    /// ``RoutedModel/makeLanguageModel()``.
    init(state: RecordingLanguageModelState) {
        self.state = state
    }

    /// Passed through unchanged from the wrapped model.
    public var capabilities: LanguageModelCapabilities { state.wrapped.capabilities }

    /// Builds the ``Executor/Configuration`` cache key from this handle's own
    /// state, identity-compared so the SDK's executor cache treats each
    /// handle distinctly while reusing one executor across every turn on the
    /// same handle.
    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(state: state)
    }

    /// Diffs `transcript` against last-seen and records anything new,
    /// closing the gap the executor boundary cannot: the turn-final
    /// response, only ever visible once a turn's driving `LanguageModelSession`
    /// has returned. Idempotent — a `transcript` already fully reflected in
    /// the last diff produces an empty diff and records nothing.
    ///
    /// - Parameter transcript: The transcript to sync against last-seen —
    ///   typically `session.transcript` at turn end.
    public func sync(_ transcript: Transcript) async {
        await state.sync(transcript)
    }

    /// The executor conformance every ``FoundationModels/LanguageModelSession``
    /// built over a ``RecordingLanguageModel`` drives.
    ///
    /// Non-generic by design: the wrapped model's concrete type is erased at
    /// ``RecordingLanguageModelState``'s construction (``RoutedModel/makeLanguageModel()``
    /// obtains it from `LoadedLLMContainer.languageModel`, an `any LanguageModel`
    /// existential), and `Wrapped.Executor(configuration:)` is built exactly
    /// once — inside ``init(configuration:)`` — by opening that existential
    /// through ``RecordingLanguageModelState/makePassthrough(wrapped:)``. The
    /// SDK caches executors keyed by ``Configuration`` equality (this
    /// handle's own identity), so as long as repeated calls on one handle
    /// keep producing an equal `Configuration`, this `init` runs once per
    /// handle and the wrapped model's own executor is reused for every turn,
    /// never rebuilt per call.
    public struct Executor: LanguageModelExecutor {
        /// Cache key the SDK uses to create and reuse this handle's executor:
        /// identity-compared on ``RecordingLanguageModelState``, a reference
        /// type with no structural equality of its own, so two distinct
        /// handles — even ones wrapping otherwise-identical models — never
        /// collide in the SDK's executor cache, while repeated calls on the
        /// *same* handle keep reusing the same cached executor.
        public struct Configuration: Sendable, Hashable {
            let state: RecordingLanguageModelState

            /// Identity-based equality: two configurations are equal exactly
            /// when they wrap the same ``RecordingLanguageModelState``
            /// instance — the SDK's executor cache key for this handle, so
            /// repeated calls on one handle hit the same cache entry while
            /// distinct handles never collide.
            public static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.state === rhs.state
            }

            /// Hashes by the wrapped state's `ObjectIdentifier`, matching
            /// this type's identity-based `==`.
            public func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(state))
            }
        }

        /// The ``RecordingLanguageModel`` type wrapped by this executor, as
        /// required by `LanguageModelExecutor`.
        public typealias Model = RecordingLanguageModel

        /// This handle's shared per-call state, driving the diff-and-record
        /// chokepoint every ``respond(to:model:streamingInto:)`` call runs
        /// through.
        private let state: RecordingLanguageModelState

        /// The wrapped model's own executor, built exactly once here (see
        /// the type-level doc comment above) and reused for every turn.
        private let innerRespond: @Sendable (
            LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
        ) async throws -> Void

        /// Stores the cache-key configuration the SDK constructed this
        /// executor with, and builds the wrapped model's own executor once.
        public init(configuration: Configuration) throws {
            self.state = configuration.state
            self.innerRespond = try RecordingLanguageModelState.makePassthrough(
                wrapped: configuration.state.wrapped)
        }

        /// Runs this handle's diff-and-record chokepoint, then passes the
        /// request straight through to the wrapped model's own (cached)
        /// executor over the SAME outer `channel` — streaming, reasoning, and
        /// tool-calling events flow untouched.
        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: RecordingLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try await state.generate(request: request, channel: channel, innerRespond: innerRespond)
        }
    }
}

/// Per-handle mutable recording state backing one ``RecordingLanguageModel``:
/// its session identity, recording directory, and the last-seen transcript
/// every ``RecordingLanguageModel/Executor/respond(to:model:streamingInto:)``
/// call diffs against — plus the wrapped model this handle passes generation
/// straight through to.
///
/// An actor — not a plain lock-guarded class — because
/// ``RecordingLanguageModel/Executor/respond(to:model:streamingInto:)`` is not
/// itself isolated (`LanguageModelExecutor`'s protocol requirement is
/// `nonisolated(nonsending)`) and ``RecordingLanguageModel/sync(_:)`` is called
/// directly by a turn owner, potentially from any isolation domain. Both entry
/// points additionally acquire the shared ``RoutedModel/serialGate`` around
/// their whole diff-and-record (and, for `generate`, the inner passthrough)
/// work — the same gate ``RoutedSessionActor``'s own chokepoint acquires — so
/// a `generate` and a `sync` on the same handle can never interleave and
/// corrupt ``lastSeen``, and generation on this handle serializes with
/// generation on any ``RoutedSession`` over the same model.
actor RecordingLanguageModelState {
    /// The recording root id.
    nonisolated let routerId: ULID
    /// This handle's own session span id.
    nonisolated let sessionId: ULID
    /// This handle's recording directory.
    nonisolated let recordingDirectory: URL
    /// The model slot this handle runs against, stamped onto every event.
    nonisolated let slot: ModelSlot
    /// The concrete model reference, stamped onto every event.
    nonisolated let model: ModelRef
    /// The non-optional recorder every diffed event is appended through.
    nonisolated let recorder: any TranscriptRecorder
    /// The owning model's shared serial generation gate — the same one
    /// ``RoutedSessionActor`` acquires, so generation on this handle and on
    /// any ``RoutedSession`` over the same model serialize together.
    nonisolated let serialGate: AsyncSemaphore
    /// The sidecar writer this handle's own `session.json` is written
    /// through, or `nil`.
    nonisolated let sessionSidecarWriter: SessionSidecarWriter?
    /// The raw model this handle passes generation straight through to.
    nonisolated let wrapped: any LanguageModel
    /// The owning profile, retained strongly so the resident models this
    /// handle drives stay alive for its whole lifetime — mirrors
    /// ``RoutedSessionActor``'s own retention of its owning ``LanguageModelProfile``.
    nonisolated let profile: LanguageModelProfile
    /// The span id of the session this handle resumed from, or `nil` for a
    /// fresh (non-resuming) handle — stamped onto every event this handle
    /// records, mirroring ``RoutedSessionActor``'s own `parentId`. It is not
    /// written into the sidecar: the handle's directory nests under the
    /// resumed session's, which is what states the lineage on disk.
    nonisolated let parentId: ULID?
    /// How many of ``parentId``'s effective entry-kind events belong to this
    /// handle's own effective transcript — `nil` for a fresh handle, which
    /// inherits nothing, or the resumed session's reconstructed transcript
    /// entry count for one born via
    /// ``RoutedModel/makeLanguageModel(resuming:registry:)``. Recorded
    /// verbatim as this handle's ``SessionSidecar/forkedAtEntryCount``.
    nonisolated let forkedAtEntryCount: Int?

    /// The last-seen transcript snapshot every diff runs against; updated
    /// after each successful diff (see ``diffAndRecord(current:)``). Primed
    /// to the resumed session's own reconstructed transcript for a handle
    /// born via ``RoutedModel/makeLanguageModel(resuming:registry:)``, so its
    /// first diff records only genuinely new entries — never the whole
    /// restored history into a fresh directory.
    private var lastSeen: Transcript
    /// Whether this handle's first-line `session` meta event has been
    /// recorded yet — mirrors ``RoutedSessionActor``'s own
    /// `didRecordSessionMeta`.
    private var didRecordSessionMeta = false
    /// Whether this handle's own sidecar has been written yet — lazily, on
    /// first use, unlike ``RoutedSession``'s eager write at creation, since
    /// minting a handle via ``RoutedModel/makeLanguageModel()`` does no I/O
    /// until it is actually driven.
    private var didWriteSidecar = false

    /// Creates a handle's per-call state.
    ///
    /// - Parameters:
    ///   - routerId: The recording root id.
    ///   - sessionId: This handle's own session span id.
    ///   - recordingDirectory: This handle's recording directory.
    ///   - slot: The model slot this handle runs against.
    ///   - model: The concrete model reference.
    ///   - recorder: The recorder every diffed event is appended through.
    ///   - serialGate: The owning model's shared serial generation gate.
    ///   - sessionSidecarWriter: The sidecar writer this handle's own
    ///     `session.json` is written through, or `nil`.
    ///   - wrapped: The raw model this handle passes generation straight
    ///     through to.
    ///   - profile: The owning profile, retained strongly for this handle's
    ///     whole lifetime.
    ///   - parentId: The span id of the session this handle resumed from, or
    ///     `nil` for a fresh (non-resuming) handle.
    ///   - forkedAtEntryCount: How many of `parentId`'s effective entry-kind
    ///     events belong to this handle's own effective transcript — `nil`
    ///     for a fresh handle.
    ///   - initialTranscript: The transcript to prime ``lastSeen`` with —
    ///     the resumed session's own reconstructed transcript for a handle
    ///     born via ``RoutedModel/makeLanguageModel(resuming:registry:)``, or
    ///     empty for a fresh handle.
    init(
        routerId: ULID,
        sessionId: ULID,
        recordingDirectory: URL,
        slot: ModelSlot,
        model: ModelRef,
        recorder: any TranscriptRecorder,
        serialGate: AsyncSemaphore,
        sessionSidecarWriter: SessionSidecarWriter?,
        wrapped: any LanguageModel,
        profile: LanguageModelProfile,
        parentId: ULID? = nil,
        forkedAtEntryCount: Int? = nil,
        initialTranscript: Transcript = Transcript(entries: [])
    ) {
        self.routerId = routerId
        self.sessionId = sessionId
        self.recordingDirectory = recordingDirectory
        self.slot = slot
        self.model = model
        self.recorder = recorder
        self.serialGate = serialGate
        self.sessionSidecarWriter = sessionSidecarWriter
        self.wrapped = wrapped
        self.profile = profile
        self.parentId = parentId
        self.forkedAtEntryCount = forkedAtEntryCount
        self.lastSeen = initialTranscript
    }

    /// The chokepoint every ``RecordingLanguageModel/Executor/respond(to:model:streamingInto:)``
    /// call runs through: diffs and gates on `request.transcript` (see
    /// ``enterGateAndDiff(_:)``), then passes the request straight through
    /// to the wrapped model's own (cached) executor over the SAME outer
    /// `channel` — still inside the gate, so generation itself, not just the
    /// diff, stays serialized — before releasing it.
    ///
    /// - Parameters:
    ///   - request: The generation request, carrying the full transcript for
    ///     this call.
    ///   - channel: The outer channel to stream the wrapped model's response
    ///     into, passed straight through unmodified.
    ///   - innerRespond: The wrapped model's own (cached) executor call.
    /// - Throws: Whatever `innerRespond` throws.
    func generate(
        request: LanguageModelExecutorGenerationRequest,
        channel: LanguageModelExecutorGenerationChannel,
        innerRespond: @Sendable (
            LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
        ) async throws -> Void
    ) async throws {
        await enterGateAndDiff(request.transcript)
        defer { serialGate.signal() }
        try await innerRespond(request, channel)
    }

    /// Diffs `transcript` against last-seen and records anything new (see
    /// ``enterGateAndDiff(_:)``), closing the gap
    /// ``generate(request:channel:innerRespond:)`` cannot: the turn-final
    /// response, only ever visible once a turn's driving
    /// `LanguageModelSession` has returned. Idempotent — a `transcript`
    /// already fully reflected in the last diff produces an empty diff.
    ///
    /// - Parameter transcript: The transcript to sync against last-seen.
    func sync(_ transcript: Transcript) async {
        await enterGateAndDiff(transcript)
        serialGate.signal()
    }

    /// Writes this handle's sidecar on first use, then
    /// acquires the shared serial gate — without releasing it — and records
    /// the session meta event lazily and diffs `transcript` against
    /// last-seen, appending whatever is new. The shared chokepoint behind
    /// both ``generate(request:channel:innerRespond:)`` and ``sync(_:)``,
    /// which differ only in what (if anything) they run inside the gate
    /// after this returns; callers MUST release the gate themselves once
    /// that additional work completes — `generate` defers the signal around
    /// its passthrough call, while `sync` (nothing left to run) signals
    /// immediately.
    ///
    /// - Parameter transcript: The transcript to register/diff against
    ///   last-seen.
    private func enterGateAndDiff(_ transcript: Transcript) async {
        writeSidecarIfNeeded(transcript: transcript)
        await serialGate.wait()
        await recordSessionMetaIfNeeded()
        await diffAndRecord(current: transcript)
    }

    /// Snapshot-diffs `current` against ``lastSeen`` via ``TranscriptDiffer``
    /// and persists exactly what is new, then updates ``lastSeen``.
    ///
    /// Defensively resets the baseline (recording nothing for this call, like
    /// ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:)``'s
    /// own guard) rather than trapping when `current` is shorter than
    /// ``lastSeen`` — nothing guarantees the SDK's transcript stays
    /// strictly append-only forever.
    ///
    /// - Parameter current: The transcript's current state.
    private func diffAndRecord(current: Transcript) async {
        guard current.count >= lastSeen.count else {
            recordingLanguageModelLogger.warning(
                """
                transcript shrank from \(self.lastSeen.count, privacy: .public) to \
                \(current.count, privacy: .public) entries for handle \
                \(self.sessionId.description, privacy: .public); recording no entries for this call and \
                resetting the baseline
                """
            )
            lastSeen = current
            return
        }
        let diffPartials = TranscriptDiffer.diff(
            lastSeen: lastSeen,
            current: current,
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard !diffPartials.isEmpty else { return }
        for partial in diffPartials {
            await recorder.append(partial, to: recordingDirectory)
        }
        lastSeen = current
    }

    /// Records this handle's first-line `session` meta event the first time
    /// it records anything, so a driven handle's transcript always opens with
    /// a `session` line while one that is never driven writes no file at all.
    private func recordSessionMetaIfNeeded() async {
        guard !didRecordSessionMeta else { return }
        didRecordSessionMeta = true
        await recorder.append(
            TranscriptEvent.Partial(
                routerId: routerId, sessionId: sessionId, parentId: parentId, slot: slot, model: model,
                kind: .session
            ),
            to: recordingDirectory
        )
    }

    /// Writes this handle's own ``SessionSidecar`` into its recording
    /// directory the first time this handle is used — lazily, unlike
    /// ``RoutedSession``'s eager write at creation (see ``didWriteSidecar``),
    /// and always before the first event is recorded, so the directory a
    /// transcript lands in already states what produced it.
    ///
    /// - Parameter transcript: The transcript observed at first use, mined
    ///   for a leading `.instructions` entry to populate the sidecar's
    ///   `instructions` field the same way ``RoutedSession`` populates it.
    private func writeSidecarIfNeeded(transcript: Transcript) {
        guard !didWriteSidecar else { return }
        didWriteSidecar = true
        sessionSidecarWriter?.write(
            instructions: TranscriptDiffer.leadingInstructionsText(of: transcript),
            // A handle built over `container.languageModel` never constrains
            // generation itself — the caller drives its own
            // `LanguageModelSession` — so there is no grammar to record.
            grammar: nil,
            forkedAtEntryCount: forkedAtEntryCount,
            to: recordingDirectory
        )
    }

    /// Builds the wrapped model's own executor exactly once and returns a
    /// closure that re-invokes it — the confirmed passthrough mechanism:
    /// `Wrapped.Executor(configuration: wrapped.executorConfiguration)
    /// .respond(to:model:streamingInto:)`, called through the OUTER channel
    /// unmodified. Called only from ``RecordingLanguageModel/Executor/init(configuration:)``,
    /// which the SDK calls once per distinct ``RecordingLanguageModel/Executor/Configuration``
    /// (this handle's own identity) and caches thereafter, so the wrapped
    /// model's own executor is built once per handle and reused for every
    /// turn, never rebuilt per call.
    ///
    /// - Parameter wrapped: The raw model to wrap, type-erased.
    /// - Returns: A closure re-invoking the wrapped model's own (already
    ///   constructed) executor.
    /// - Throws: Whatever `Wrapped.Executor.init(configuration:)` throws.
    static func makePassthrough(
        wrapped: any LanguageModel
    ) throws -> @Sendable (
        LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
    ) async throws -> Void {
        try makePassthroughGeneric(wrapped)
    }

    /// Opens `wrapped`'s existential so `Wrapped.Executor` — an associated
    /// type unreachable from `any LanguageModel` directly — is nameable here,
    /// constructs it once, then closes back over that concretely-typed,
    /// already-built executor and model so the returned closure stays
    /// non-generic.
    ///
    /// - Parameter wrapped: The raw model to wrap.
    /// - Returns: A closure re-invoking `wrapped`'s own (already constructed)
    ///   executor.
    /// - Throws: Whatever `Wrapped.Executor.init(configuration:)` throws.
    private static func makePassthroughGeneric<Wrapped: LanguageModel>(
        _ wrapped: Wrapped
    ) throws -> @Sendable (
        LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
    ) async throws -> Void {
        let executor = try Wrapped.Executor(configuration: wrapped.executorConfiguration)
        return { request, channel in
            try await executor.respond(to: request, model: wrapped, streamingInto: channel)
        }
    }
}
