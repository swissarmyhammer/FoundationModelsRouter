import Foundation
import FoundationModels
import os

/// The logger that reports a transcript shrink or a non-append divergence.
private let recordingLanguageModelLogger = makeModuleLogger(category: "Recording")

/// A `FoundationModels.LanguageModel` that records, gates, and supports tool
/// calls. A caller builds a `LanguageModelSession(model:tools:instructions:)`
/// over it directly.
///
/// Only ``RoutedModel/makeLanguageModel()`` creates a handle. Each handle has
/// its own session ULID, recording directory, and last-seen transcript.
/// Two handles never share a directory or interleave events.
///
/// Generation passes through to the wrapped model's own executor over the
/// outer channel. On every call the handle diffs the request transcript
/// against the last-seen transcript and records what is new. The turn-final
/// response is not visible at the executor boundary. Call ``sync(_:usage:)``
/// with `session.transcript` at turn end to record it.
struct RecordingLanguageModel: LanguageModel, Sendable {
    /// This handle's per-call mutable state and identity.
    let state: RecordingLanguageModelState

    /// Creates a handle over `state`.
    init(state: RecordingLanguageModelState) {
        self.state = state
    }

    /// Passed through unchanged from the wrapped model.
    var capabilities: LanguageModelCapabilities { state.wrapped.capabilities }

    /// The executor cache key for this handle. It compares by the identity
    /// of this handle's state.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(state: state)
    }

    /// Diffs `transcript` against the last-seen transcript and records what
    /// is new. Call it with `session.transcript` at turn end to record the
    /// turn-final response. The call is idempotent.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to sync against the last-seen one.
    ///   - usage: This turn's `(input, output)` token usage, stamped onto the
    ///     diff's turn-final `.response` event, or `nil` to leave it unset.
    func sync(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil) async {
        await state.sync(transcript, usage: usage)
    }

    /// Folds this handle's recording forward across a compaction. It appends
    /// the entries of `compacted` that are not yet recorded, identified by
    /// `Transcript.Entry.id`, and resets the diff baseline to `compacted`.
    /// The call is idempotent.
    ///
    /// After this call, rebuild the `LanguageModelSession` over this handle
    /// with `transcript: compacted`. For a deterministic-only fold, use
    /// ``noteCompaction(_:result:)`` so the checkpoint reaches disk.
    ///
    /// - Parameter compacted: The transcript compaction produced.
    func noteCompaction(_ compacted: Transcript) async {
        _ = await state.noteCompaction(compacted)
    }

    /// Folds this handle's recording forward across a compaction, like
    /// ``noteCompaction(_:)``. When `result` reports a deterministic-only
    /// fold (no summary entry, at least one stage applied), one boundary
    /// entry is synthesized and recorded so the ``CompactionSegment``
    /// checkpoint reaches disk.
    ///
    /// After this call, rebuild the `LanguageModelSession` over this handle
    /// with the returned transcript, not with `compacted`.
    ///
    /// - Parameters:
    ///   - compacted: The transcript compaction produced.
    ///   - result: The report of what the fold did.
    /// - Returns: The transcript to seed the rebuilt session with.
    func noteCompaction(_ compacted: Transcript, result: CompactionResult) async -> Transcript {
        await state.noteCompaction(compacted, result: result)
    }

    /// The executor every `LanguageModelSession` built over a
    /// ``RecordingLanguageModel`` drives. The SDK caches one executor per
    /// distinct ``Configuration``, so the wrapped executor is built once per
    /// handle.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares by the identity of the
        /// wrapped ``RecordingLanguageModelState``.
        struct Configuration: Sendable, Hashable {
            let state: RecordingLanguageModelState

            /// Identity equality on the wrapped state.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.state === rhs.state
            }

            /// Hashes by the wrapped state's `ObjectIdentifier`.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(state))
            }
        }

        /// The model type this executor serves.
        typealias Model = RecordingLanguageModel

        /// This handle's shared per-call state.
        private let state: RecordingLanguageModelState

        /// The wrapped model's own executor, built once and reused.
        private let innerRespond: @Sendable (
            LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
        ) async throws -> Void

        /// Stores `configuration` and builds the wrapped model's executor once.
        init(configuration: Configuration) throws {
            self.state = configuration.state
            self.innerRespond = try RecordingLanguageModelState.makePassthrough(
                wrapped: configuration.state.wrapped)
        }

        /// Diffs and records, then passes the request through to the wrapped
        /// executor over the same outer `channel`.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: RecordingLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try await state.generate(request: request, channel: channel, innerRespond: innerRespond)
        }
    }
}

/// Per-handle mutable recording state for one ``RecordingLanguageModel``:
/// its session identity, recording directory, last-seen transcript, and the
/// wrapped model.
///
/// Both entry points acquire the shared ``RoutedModel/generationGate`` around
/// their diff-and-record work, so a `generate` and a `sync` on the same handle
/// never interleave, and generation serializes with any ``RoutedSession``
/// over the same model.
actor RecordingLanguageModelState {
    /// The recording root id.
    nonisolated let routerId: ULID
    /// This handle's own session span id.
    nonisolated let sessionId: ULID
    /// This handle's recording directory.
    nonisolated let recordingDirectory: URL
    /// The model slot this handle runs against.
    nonisolated let slot: ModelSlot
    /// The concrete model reference.
    nonisolated let model: ModelRef
    /// The recorder every diffed event is appended through.
    nonisolated let recorder: any TranscriptRecorder
    /// The owning model's shared serial generation gate.
    nonisolated let generationGate: AsyncSemaphore
    /// The writer for this handle's own `session.json`, or `nil`.
    nonisolated let sessionSidecarWriter: SessionSidecarWriter?
    /// The raw model this handle passes generation through to.
    nonisolated let wrapped: any LanguageModel
    /// The owning profile, retained so its resident models stay alive.
    // Never read on purpose: holding the reference *is* the whole behavior, so
    // the index sees an assignment and no use. Deleting it would let the
    // profile — and the resident models under it — deallocate mid-handle.
    // periphery:ignore
    nonisolated let profile: LanguageModelProfile
    /// The span id of the session this handle resumed from, or `nil` for a
    /// fresh handle. It is stamped onto every recorded event.
    nonisolated let parentId: ULID?
    /// The number of ``parentId``'s effective entry-kind events in this
    /// handle's own effective transcript, or `nil` for a fresh handle.
    /// Recorded as ``SessionSidecar/forkedAtEntryCount``.
    nonisolated let forkedAtEntryCount: Int?
    /// This handle's cut point in ``parentId``'s recorded history, in
    /// append-only coordinates, or `nil` for a fresh handle. Recorded as
    /// ``SessionSidecar/forkedAtHistoryOrdinal``.
    nonisolated let forkedAtHistoryOrdinal: Int?

    /// The last-seen transcript every diff runs against. For a resumed
    /// handle it starts as the resumed session's reconstructed transcript.
    private var lastSeen: Transcript
    /// Whether the first-line `session` meta event is recorded yet.
    private var didRecordSessionMeta = false
    /// Whether this handle's sidecar is written yet. It is written on first use.
    private var didWriteSidecar = false

    /// Creates a handle's per-call state. `initialTranscript` primes
    /// ``lastSeen``.
    init(
        routerId: ULID,
        sessionId: ULID,
        recordingDirectory: URL,
        slot: ModelSlot,
        model: ModelRef,
        recorder: any TranscriptRecorder,
        generationGate: AsyncSemaphore,
        sessionSidecarWriter: SessionSidecarWriter?,
        wrapped: any LanguageModel,
        profile: LanguageModelProfile,
        parentId: ULID? = nil,
        forkedAtEntryCount: Int? = nil,
        forkedAtHistoryOrdinal: Int? = nil,
        initialTranscript: Transcript = Transcript(entries: [])
    ) {
        self.routerId = routerId
        self.sessionId = sessionId
        self.recordingDirectory = recordingDirectory
        self.slot = slot
        self.model = model
        self.recorder = recorder
        self.generationGate = generationGate
        self.sessionSidecarWriter = sessionSidecarWriter
        self.wrapped = wrapped
        self.profile = profile
        self.parentId = parentId
        self.forkedAtEntryCount = forkedAtEntryCount
        self.forkedAtHistoryOrdinal = forkedAtHistoryOrdinal
        self.lastSeen = initialTranscript
    }

    /// Diffs and records `request.transcript` inside the gate, then passes
    /// the request through to `innerRespond` over the same `channel`, and
    /// releases the gate.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - channel: The outer channel to stream the response into.
    ///   - innerRespond: The wrapped model's own executor call.
    /// - Throws: What `innerRespond` throws.
    func generate(
        request: LanguageModelExecutorGenerationRequest,
        channel: LanguageModelExecutorGenerationChannel,
        innerRespond: @Sendable (
            LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
        ) async throws -> Void
    ) async throws {
        await enterGateAndDiff(request.transcript)
        defer { generationGate.signal() }
        try await innerRespond(request, channel)
    }

    /// Diffs `transcript` against the last-seen transcript inside the gate,
    /// records what is new, and releases the gate. The call is idempotent.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to sync against the last-seen one.
    ///   - usage: This turn's `(input, output)` token usage, stamped onto the
    ///     diff's turn-final `.response` event, or `nil`.
    func sync(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil) async {
        await enterGateAndDiff(transcript, usage: usage)
        generationGate.signal()
    }

    /// Folds this handle's recording forward across a compaction. It records
    /// the fold's new entries by `Transcript.Entry.id` and resets
    /// ``lastSeen`` to what it recorded.
    ///
    /// - Parameters:
    ///   - compacted: The transcript compaction produced.
    ///   - result: The report of what the fold did, or `nil` to record
    ///     `compacted` as-is with no boundary synthesis.
    /// - Returns: The transcript recorded and set as the new ``lastSeen``.
    ///   The caller seeds the rebuilt session with it.
    func noteCompaction(_ compacted: Transcript, result: CompactionResult? = nil) async -> Transcript {
        await enterGateAndRecordMeta(compacted)
        let applied = appliedTranscript(for: compacted, result: result)
        await diffAndRecordCompaction(compacted: applied)
        generationGate.signal()
        return applied
    }

    /// Returns `compacted` plus one synthesized deterministic boundary entry
    /// when `result` reports an applied fold with no summary entry, or
    /// `compacted` unchanged otherwise. Must run inside the generation gate
    /// because it reads ``lastSeen``.
    ///
    /// - Parameters:
    ///   - compacted: The transcript compaction produced.
    ///   - result: The report of what the fold did, or `nil`.
    /// - Returns: The transcript to record and reset ``lastSeen`` to.
    private func appliedTranscript(for compacted: Transcript, result: CompactionResult?) -> Transcript {
        guard let result, result.summaryEntryId == nil, !result.stagesApplied.isEmpty else {
            return compacted
        }
        return CompactionSegment.appendingDeterministicBoundary(
            to: compacted,
            preFoldEntryIds: lastSeen.map(\.id),
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            stagesApplied: result.stagesApplied,
            pendingRuns: nil
        )
    }

    /// Writes the sidecar on first use, acquires the generation gate, and
    /// records the session meta event on first use. It does not release the
    /// gate. The caller signals the gate when its own work completes.
    ///
    /// - Parameter transcript: The transcript the first-use sidecar is
    ///   written from.
    private func enterGateAndRecordMeta(_ transcript: Transcript) async {
        writeSidecarIfNeeded(transcript: transcript)
        await generationGate.wait()
        await recordSessionMetaIfNeeded()
    }

    /// Acquires the generation gate and diffs `transcript` against
    /// ``lastSeen``. It does not release the gate.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to diff against ``lastSeen``.
    ///   - usage: This turn's `(input, output)` token usage, or `nil`.
    private func enterGateAndDiff(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil) async {
        await enterGateAndRecordMeta(transcript)
        await diffAndRecord(current: transcript, usage: usage)
    }

    /// Diffs `current` against ``lastSeen``, records what is new, and sets
    /// ``lastSeen`` to `current`. A shrink resets the baseline and records
    /// nothing. A non-append divergence records one
    /// ``TranscriptEvent/Kind/divergence`` marker and resets the baseline.
    /// A non-nil `usage` is stamped onto the last `.response` partial only.
    ///
    /// - Parameters:
    ///   - current: The transcript's current state.
    ///   - usage: This turn's `(input, output)` token usage, or `nil`.
    private func diffAndRecord(current: Transcript, usage: (input: Int, output: Int)? = nil) async {
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
        if let divergence = TranscriptDiffer.divergence(lastSeen: lastSeen, current: current) {
            recordingLanguageModelLogger.warning(
                """
                \(divergence.description, privacy: .public) for handle \
                \(self.sessionId.description, privacy: .public); recording a divergence marker instead \
                of a wrong diff and resetting the baseline
                """
            )
            await recorder.append(
                TranscriptEvent.Partial(
                    routerId: routerId, sessionId: sessionId, parentId: parentId, slot: slot, model: model,
                    kind: .divergence, text: divergence.description
                ),
                to: recordingDirectory
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
        let lastResponseIndex = usage != nil ? diffPartials.lastIndex { $0.kind == .response } : nil
        for (index, partial) in diffPartials.enumerated() {
            let toRecord = (usage != nil && index == lastResponseIndex)
                ? partial.stampingUsage(tokensIn: usage?.input, tokensOut: usage?.output)
                : partial
            await recorder.append(toRecord, to: recordingDirectory)
        }
        lastSeen = current
    }

    /// Appends the entries of `compacted` that are not yet recorded,
    /// identified by `Transcript.Entry.id`, and sets ``lastSeen`` to
    /// `compacted`. A shorter `compacted` is expected, not a shrink.
    ///
    /// - Parameter compacted: The transcript compaction produced.
    private func diffAndRecordCompaction(compacted: Transcript) async {
        let diffPartials = TranscriptDiffer.diffByEntryId(
            lastSeen: lastSeen,
            current: compacted,
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model
        )
        for partial in diffPartials {
            await recorder.append(partial, to: recordingDirectory)
        }
        lastSeen = compacted
    }

    /// Records the first-line `session` meta event the first time this
    /// handle records anything.
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

    /// Writes this handle's ``SessionSidecar`` into its recording directory
    /// the first time this handle is used, before the first event is recorded.
    ///
    /// - Parameter transcript: The transcript observed at first use. Its
    ///   leading `.instructions` entry populates the sidecar's `instructions`.
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
            // The resume cut in the recorded history's own append-only
            // coordinates, computed by
            // ``RoutedModel/makeLanguageModel(resuming:)`` at resume
            // time — `nil` for a fresh handle, which has no parent to cut.
            // Without it, a reader falls back to `forkedAtEntryCount`, which
            // a compacted resume makes smaller than the raw event count, and
            // the cut selects the oldest pre-fold span (task ^bw2gts3; the
            // actor fork path fixed the same defect in task ^6z1msg1).
            forkedAtHistoryOrdinal: forkedAtHistoryOrdinal,
            // This handle never exposes a working-directory override — the
            // caller drives its own `LanguageModelSession` and any tools it
            // hands it directly, with no Router-managed working directory of
            // its own — so its recording directory doubles as its working
            // directory, exactly as ``RoutedSession/workingDirectory``
            // defaults to the recording directory when no override is given.
            workingDirectory: recordingDirectory,
            to: recordingDirectory
        )
    }

    /// Builds the wrapped model's own executor once and returns a closure
    /// that calls it over the outer channel unmodified.
    ///
    /// - Parameter wrapped: The raw model to wrap, type-erased.
    /// - Returns: A closure that calls the wrapped model's executor.
    /// - Throws: What `Wrapped.Executor.init(configuration:)` throws.
    static func makePassthrough(
        wrapped: any LanguageModel
    ) throws -> @Sendable (
        LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
    ) async throws -> Void {
        try makePassthroughGeneric(wrapped: wrapped)
    }

    /// Opens the existential of `wrapped` so `Wrapped.Executor` can be
    /// built once, then closes over that executor and model.
    ///
    /// - Parameter wrapped: The raw model to wrap.
    /// - Returns: A closure that calls the executor of `wrapped`.
    /// - Throws: What `Wrapped.Executor.init(configuration:)` throws.
    private static func makePassthroughGeneric<Wrapped: LanguageModel>(
        wrapped: Wrapped
    ) throws -> @Sendable (
        LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
    ) async throws -> Void {
        let executor = try Wrapped.Executor(configuration: wrapped.executorConfiguration)
        return { request, channel in
            try await executor.respond(to: request, model: wrapped, streamingInto: channel)
        }
    }
}
