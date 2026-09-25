import Foundation
import FoundationModels
import os

/// The logger that reports a non-append divergence of a synced transcript.
private let recordingLanguageModelLogger = makeModuleLogger(category: "Recording")

/// A `FoundationModels.LanguageModel` that records and supports tool calls.
/// A caller builds a `LanguageModelSession(model:tools:instructions:)` over it
/// directly. The wrapped model (the ``LoadedLLMContainer/languageModel`` of
/// the container) takes the generation queue for each pass.
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

    /// Carries this handle's recording forward across a compaction. It appends
    /// the entries of `compacted` that are not yet recorded, identified by
    /// `Transcript.Entry.id`, and resets the diff baseline to `compacted`.
    /// The call is idempotent.
    ///
    /// After this call, rebuild the `LanguageModelSession` over this handle
    /// with `transcript: compacted`. The summary entry of `compacted` carries
    /// the ``CompactionSegment`` checkpoint to disk.
    ///
    /// - Parameter compacted: The transcript compaction produced.
    func noteCompaction(_ compacted: Transcript) async {
        await state.noteCompaction(compacted)
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
        private let innerRespond: ExecutorPassthrough.Respond

        /// Stores `configuration` and builds the wrapped model's executor once.
        init(configuration: Configuration) throws {
            self.state = configuration.state
            self.innerRespond = try ExecutorPassthrough.make(wrapping: configuration.state.wrapped)
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
/// Every entry point acquires this handle's own ``recordingLock`` around its
/// diff-and-record work, so a `generate`, a `sync`, and a `noteCompaction` on
/// the same handle never interleave. The lock does not cover the call of the
/// wrapped executor: the GPU queue of the model is the job of the
/// ``SessionLanguageModel`` that the container gives as
/// ``LoadedLLMContainer/languageModel``, whose each pass is one item of the
/// queue of the model (`generation-queue.md`, section 5.3).
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
    /// This handle's own lock around its diff-and-record work: a fair FIFO
    /// ``AsyncSemaphore`` at value `1`. The actor alone does not serialize
    /// that work, because each recorder append suspends it.
    nonisolated let recordingLock = AsyncSemaphore(value: 1)
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
        self.sessionSidecarWriter = sessionSidecarWriter
        self.wrapped = wrapped
        self.profile = profile
        self.parentId = parentId
        self.forkedAtEntryCount = forkedAtEntryCount
        self.forkedAtHistoryOrdinal = forkedAtHistoryOrdinal
        self.lastSeen = initialTranscript
    }

    /// Diffs and records `request.transcript` inside this handle's
    /// ``recordingLock``, releases the lock, and then passes the request
    /// through to `innerRespond` over the same `channel`.
    ///
    /// The lock does not cover `innerRespond`, so a long pass never holds it.
    /// The queue of the model is the job of the wrapped model.
    ///
    /// - Parameters:
    ///   - request: The generation request.
    ///   - channel: The outer channel to stream the response into.
    ///   - innerRespond: The wrapped model's own executor call.
    /// - Throws: What `innerRespond` throws.
    func generate(
        request: LanguageModelExecutorGenerationRequest,
        channel: LanguageModelExecutorGenerationChannel,
        innerRespond: ExecutorPassthrough.Respond
    ) async throws {
        await diffAndRecordUnderLock(request.transcript)
        try await innerRespond(request, channel)
    }

    /// Diffs `transcript` against the last-seen transcript inside this
    /// handle's ``recordingLock``, and records what is new. The call is
    /// idempotent.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to sync against the last-seen one.
    ///   - usage: This turn's `(input, output)` token usage, stamped onto the
    ///     diff's turn-final `.response` event, or `nil`.
    func sync(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil) async {
        await diffAndRecordUnderLock(transcript, usage: usage)
    }

    /// Carries this handle's recording forward across a compaction, inside
    /// this handle's ``recordingLock``. It records the compaction's new
    /// entries by `Transcript.Entry.id` and resets ``lastSeen`` to
    /// `compacted`.
    ///
    /// - Parameter compacted: The transcript compaction produced.
    func noteCompaction(_ compacted: Transcript) async {
        await enterLockAndRecordMeta(compacted)
        await diffAndRecordCompaction(compacted: compacted)
        recordingLock.signal()
    }

    /// Writes the sidecar on first use, acquires ``recordingLock``, and
    /// records the session meta event on first use. It does not release the
    /// lock. The caller signals the lock when its own work completes.
    ///
    /// - Parameter transcript: The transcript the first-use sidecar is
    ///   written from.
    private func enterLockAndRecordMeta(_ transcript: Transcript) async {
        writeSidecarIfNeeded(transcript: transcript)
        await recordingLock.wait()
        await recordSessionMetaIfNeeded()
    }

    /// Acquires ``recordingLock``, diffs `transcript` against ``lastSeen``,
    /// records what is new, and releases the lock.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to diff against ``lastSeen``.
    ///   - usage: This turn's `(input, output)` token usage, or `nil`.
    private func diffAndRecordUnderLock(_ transcript: Transcript, usage: (input: Int, output: Int)? = nil) async {
        await enterLockAndRecordMeta(transcript)
        await diffAndRecord(current: transcript, usage: usage)
        recordingLock.signal()
    }

    /// Diffs `current` against ``lastSeen``, records what is new, and sets
    /// ``lastSeen`` to `current`. A transcript only appends: no branch here
    /// drops an entry. A `current` that extends ``lastSeen`` is diffed by
    /// position. A `current` that diverged from it
    /// (``TranscriptDiffer/divergence(from:in:)``: an entry id moved, the
    /// boundary entry was rewritten in place, or the transcript shrank) is
    /// diffed by entry id, so every entry the record has never seen is
    /// appended, in transcript order, and then one
    /// ``TranscriptEvent/Kind/divergence`` marker is appended beside them.
    /// An entry rewritten under a recorded id is not appended a second time;
    /// the marker names it. A non-nil `usage` is stamped onto the last
    /// `.response` partial only.
    ///
    /// - Parameters:
    ///   - current: The transcript's current state.
    ///   - usage: This turn's `(input, output)` token usage, or `nil`.
    private func diffAndRecord(current: Transcript, usage: (input: Int, output: Int)? = nil) async {
        let baseline = TranscriptDiffer.Baseline(transcript: lastSeen)
        let divergence = TranscriptDiffer.divergence(from: baseline, in: current)
        let diffPartials = TranscriptDiffer.partials(
            baseline: baseline,
            current: current,
            divergence: divergence,
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard divergence != nil || !diffPartials.isEmpty else { return }
        let lastResponseIndex = usage != nil ? diffPartials.lastIndex { $0.kind == .response } : nil
        for (index, partial) in diffPartials.enumerated() {
            let toRecord = (usage != nil && index == lastResponseIndex)
                ? partial.stampingUsage(tokensIn: usage?.input, tokensOut: usage?.output)
                : partial
            await recorder.append(toRecord, to: recordingDirectory)
        }
        if let divergence {
            await appendDivergenceMarker(divergence)
        }
        lastSeen = current
    }

    /// Logs `divergence` and appends its ``TranscriptEvent/Kind/divergence``
    /// marker, after the entries the diverged sync recorded.
    ///
    /// - Parameter divergence: The non-append change the sync found.
    private func appendDivergenceMarker(_ divergence: TranscriptDiffer.Divergence) async {
        recordingLanguageModelLogger.warning(
            """
            \(divergence.description, privacy: .public) for handle \
            \(self.sessionId.description, privacy: .public); the unseen entries are recorded and a \
            divergence marker follows them
            """
        )
        await recorder.append(
            TranscriptEvent.Partial(
                routerId: routerId, sessionId: sessionId, parentId: parentId, slot: slot, model: model,
                kind: .divergence, text: divergence.description
            ),
            to: recordingDirectory
        )
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
            // the cut selects the oldest pre-compaction span (task ^bw2gts3; the
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

}
