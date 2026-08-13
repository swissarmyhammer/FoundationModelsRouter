import Foundation
import FoundationModels
import os

/// The logger ``RoutedSessionActor`` reports a defensively-clamped transcript
/// shrink or a detected non-append divergence to (see
/// ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``).
private let sessionRecordingLogger = makeModuleLogger(category: "Recording")

/// ``RoutedSessionActor``'s recording path: the per-turn usage delta, the
/// snapshot diff of the backend's own transcript that becomes recorded events,
/// the drained events re-queued when a turn produced nothing to attach them to,
/// and the session meta and streaming partials recorded alongside them.
extension RoutedSessionActor {
    /// Computes this turn's usage delta and records whatever the SDK's
    /// transcript diff contains — the one place both of
    /// ``generate(grammar:prompt:onEvent:_:)``'s success and throwing exits go
    /// through, so the usage-delta computation and the
    /// ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``
    /// call are made in exactly one place rather than duplicated per branch.
    /// Also where ``SessionEvent/turnEnded(_:)`` is emitted — once per turn,
    /// on both exits, right after the diff (and everything it implies) has
    /// already been recorded and reported.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force, forwarded to
    ///     ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``.
    ///   - since: The turn's start instant, forwarded to
    ///     ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``
    ///     to stamp `ms`.
    ///   - usageBefore: The pre-turn snapshot captured immediately before
    ///     `body()` ran.
    ///   - pendingEvents: The events this turn drained from the outbox,
    ///     forwarded to ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``
    ///     to attach as persisted segments on the turn's `.prompt` entry.
    ///   - onEvent: A sink for this turn's derived ``SessionEvent``s, forwarded
    ///     to ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``
    ///     and also given this turn's own ``SessionEvent/turnEnded(_:)`` once
    ///     usage is known, or `nil` to skip event derivation entirely.
    /// - Returns: Whether the diff included a `.response`-kind entry — the
    ///   throwing path uses this to decide whether a synthetic bodyless close
    ///   is still needed; the turn's own usage delta (`nil` if the backend
    ///   cannot report usage), which the throwing path stamps onto that
    ///   synthetic close; and whether `pendingEvents` were actually attached
    ///   to a persisted `.prompt` entry — ``generate(grammar:prompt:onEvent:_:)``
    ///   uses this to decide whether they must be re-queued instead of lost.
    private func finishTurn(
        grammar: Grammar?,
        since: Date,
        usageBefore: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?, pendingEventsAttached: Bool) {
        let usage = Self.usageDelta(before: usageBefore, after: backend.usageTokenCounts())
        let (diffIncludedResponse, pendingEventsAttached) = await recordTranscriptDelta(
            grammar: grammar, since: since, usage: usage, pendingEvents: pendingEvents, onEvent: onEvent)
        // Only a turn whose diff actually included a `.response`-kind entry
        // measured the whole transcript (generation is stateless, so that
        // turn's own delta *is* the whole transcript's size) — a turn
        // rejected before ever touching `backend` (e.g. a guided turn whose
        // grammar validation throws pre-flight) leaves the last known fill
        // untouched instead of resetting it to a meaningless zero delta. See
        // ``usageState``.
        if diffIncludedResponse {
            usageState = usage.map { .measured(input: $0.input, output: $0.output) } ?? .unknown
        }
        // Mirrors the `tokensIn`/`tokensOut` stamping gate everywhere else in
        // this chokepoint: emitted whenever the backend could report usage at
        // all, regardless of `diffIncludedResponse` — a turn rejected before
        // touching `backend` still measures a genuine (zero) delta between
        // two real snapshots, so it still closes with a `turnEnded`. Reads
        // `contextFill` *after* the `usageState` update above, so this
        // attempt's own event carries the fill it just measured (or the
        // still-unchanged prior value when this attempt never touched
        // `backend`) — live, per inner call, not only once the whole
        // (possibly retried) turn finishes (compaction_plan.md §1.7, task g2hcm36).
        if let usage {
            onEvent?(.turnEnded(TokenUsage(tokensIn: usage.input, tokensOut: usage.output, contextFill: contextFill)))
        }
        return (diffIncludedResponse, usage, pendingEventsAttached)
    }

    /// Runs ``finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)``
    /// and, on either of its exits, re-queues `pendingEvents` whenever the
    /// turn's diff produced no `.prompt`-kind partial to attach them to — the
    /// single attach-or-requeue check ``generate(grammar:prompt:onEvent:_:)``'s
    /// success and throwing paths both need, so the two exits can't drift out
    /// of sync.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn.
    ///   - started: The turn's start time, forwarded to `finishTurn`.
    ///   - usageBefore: The token-usage snapshot taken before the turn ran.
    ///   - pendingEvents: The events drained from ``outbox`` for this turn.
    ///   - onEvent: A sink for this turn's derived ``SessionEvent``s, forwarded
    ///     to `finishTurn`, or `nil` to skip event derivation entirely.
    /// - Returns: `finishTurn`'s `diffIncludedResponse` and `usage`, for the
    ///   caller's own post-processing; `pendingEventsAttached` is consumed
    ///   here and not returned, since both callers handle it identically.
    func finishTurnAndRequeueIfUnattached(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?) {
        let (diffIncludedResponse, usage, pendingEventsAttached) = await finishTurn(
            grammar: grammar, since: started, usageBefore: usageBefore, pendingEvents: pendingEvents,
            onEvent: onEvent)
        // `drainForDispatch()` already destructively removed `pendingEvents`
        // from `outbox` before `body()` ran. When this turn's diff produced no
        // `.prompt`-kind partial to attach them to — every `.ebnf`-guided
        // turn, whose backend validates and throws before touching its live
        // session at all (see `MLXFoundationModelsSessionBackend.respond(to:
        // following:maxTokens:)`), or a transcript-shrink guard — the
        // composed preamble was never actually delivered to the model and the
        // events were never persisted either. Re-queue them so a future turn
        // gets another chance, instead of the drain silently destroying state
        // a failed turn never got to deliver.
        if !pendingEventsAttached {
            await requeueUnattachedPendingEvents(events: pendingEvents)
        }
        return (diffIncludedResponse, usage)
    }

    /// Re-posts `events` back onto ``outbox`` when a turn's diff produced no
    /// `.prompt`-kind partial to attach them to.
    ///
    /// A no-op when `events` is empty, so an empty outbox never touches
    /// ``outbox`` here — preserving byte-identical behavior for the common
    /// case. Re-queued events go back through ``SessionOutbox/requeue(event:)``,
    /// which applies the same coalescing policy ``SessionOutbox/post(_:)``
    /// does and assigns fresh ``SessionOutbox/ItemID``s (the drain that
    /// removed them was already the commit point for their original ids), but
    /// deliberately does *not* journal them a second time: the run reported
    /// once, and the transcript already recorded that one report at the moment
    /// it happened. What matters here is that no event this method is reached
    /// with is ever silently destroyed.
    ///
    /// - Parameter events: The events to re-queue, in outbox order.
    func requeueUnattachedPendingEvents(events: [OperationEvent]) async {
        for event in events {
            await outbox.requeue(event: event)
        }
    }

    /// The per-turn token usage delta between two ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots taken immediately before and after a turn's `body()` ran.
    ///
    /// `nil` when either snapshot is `nil` — a backend that cannot report
    /// usage at all, or one that stopped being able to mid-turn — rather than
    /// synthesizing a delta from a partial reading.
    ///
    /// - Parameters:
    ///   - before: The snapshot taken immediately before `body()` ran.
    ///   - after: The snapshot taken immediately after `body()` returned or
    ///     threw.
    /// - Returns: The turn's own `(input, output)` token counts, or `nil`.
    private static func usageDelta(
        before: (input: Int, output: Int)?,
        after: (input: Int, output: Int)?
    ) -> (input: Int, output: Int)? {
        guard let before, let after else { return nil }
        return (after.input - before.input, after.output - before.output)
    }

    /// Snapshot-diffs ``backend``'s real transcript against ``persistedEntryCount``
    /// and persists exactly what the SDK appended since the last diff — the core
    /// of the "persist the SDK's own `Transcript`, not a paraphrase" design (see
    /// plan.md's "Transcript fidelity" section).
    ///
    /// Reads `backend.transcriptEntries()` once. If a shrink is detected
    /// (`entries.count < persistedEntryCount` — nothing guarantees the SDK
    /// transcript stays strictly append-only forever; a future
    /// `TranscriptErrorHandlingPolicy` opt-in could condense or rewrite it),
    /// this logs a warning, records nothing for this turn's diff, and resets
    /// ``persistedEntryCount`` to the smaller count so the next turn diffs from
    /// reality instead of tripping the same guard again.
    ///
    /// A non-append change that is not a shrink — a mid-transcript insertion,
    /// or a rewrite of an already-recorded entry — is detected next, by
    /// ``TranscriptDiffer/divergence(from:in:)`` against ``persistedBaseline``
    /// (when one is established), and answered with the documented loud
    /// signal (see ``TranscriptDiffer/Divergence``): a warning log plus one
    /// recorded ``TranscriptEvent/Kind/divergence`` marker event, nothing
    /// recorded for this turn's diff, and both the count and the baseline
    /// reset to the current transcript.
    ///
    /// Otherwise the
    /// last-seen (the first ``persistedEntryCount`` entries) and current (all
    /// of `entries`) states are diffed via ``TranscriptDiffer/diff(lastSeen:current:routerId:sessionId:parentId:slot:model:)``
    /// — the one diff implementation this session shares with the upcoming
    /// recording handle — which maps every new entry through
    /// ``TranscriptEntryMapper/event(from:)`` and stamps this session's
    /// identity onto each produced partial.
    ///
    /// Each produced partial is then re-stamped with this turn's `grammar`
    /// and appended as its own event. When `since` is non-nil, the turn's
    /// measured `ms` is stamped only on the *last* `.response`-kind event the
    /// diff produced — not on every appended event — on the success path and
    /// the throwing path alike, so an SDK-appended `.response` entry from a
    /// turn that failed *after* generating still gets the turn's `ms`.
    /// `usage` (the turn's own `tokensIn`/`tokensOut` delta, or `nil` when the
    /// backend cannot report usage) is stamped the same way, on that same
    /// last `.response`-kind event — mirroring `ms`, since both are per-turn
    /// totals that only make sense attributed to the turn's one closing
    /// event, not every entry it appended.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force, stamped onto every
    ///     appended event.
    ///   - since: The turn's start instant to stamp `ms` with on the diff's last
    ///     `.response`-kind event, or `nil` to leave `ms` unset on every
    ///     appended event.
    ///   - usage: The turn's own `(input, output)` token usage delta to stamp
    ///     as `tokensIn`/`tokensOut` on the diff's last `.response`-kind
    ///     event, or `nil` to leave both unset on every appended event.
    ///   - pendingEvents: The events this turn drained from the outbox, in
    ///     outbox order. When non-empty, one ``OperationEventSegment`` per
    ///     event is appended (via ``attachingPendingEventSegments(events:to:)``)
    ///     onto the turn's own `.prompt`-kind diff partial — the *last* one,
    ///     since a discovery-priming seed's synthetic `.prompt` precedes the
    ///     turn's own prompt in the same diff (see that helper for the full
    ///     rule) — before it is persisted; the SDK's own live transcript is
    ///     never touched. Empty means no augmentation at all, so this
    ///     method's output is byte-identical to before this feature existed.
    ///   - onEvent: A sink this diff's derived ``SessionEvent``s (tool
    ///     calls/status, reasoning) are emitted to as each diff partial is
    ///     recorded, or `nil` to skip derivation entirely. Every turn now
    ///     supplies one — ``RoutedSessionActor/turnEventSink(_:)`` composes the
    ///     turn's own stream with the session-scoped fan-out and is never
    ///     `nil` — so the `nil` branch in
    ///     ``emitSessionEvents(for:dispatchedToolCallIds:completedToolCallIds:onEvent:)``
    ///     is reached only by a caller of this method that supplies none.
    /// - Returns: Whether this diff included a `.response`-kind entry — the
    ///   throwing path in ``generate(grammar:prompt:onEvent:_:)`` uses this to
    ///   decide whether a synthetic bodyless close is still needed, so a turn
    ///   whose SDK transcript already gained a real `.response` entry before
    ///   failing never gets two `.response` events — and whether
    ///   `pendingEvents` (when non-empty) were actually attached to a
    ///   `.prompt`-kind partial. The latter is `true` whenever `pendingEvents`
    ///   is empty (nothing to attach, so nothing was missed) and `false`
    ///   whenever it is non-empty but the attachment did not happen — no
    ///   `.prompt`-kind partial existed (e.g. the shrink guard below, or a
    ///   backend like an `.ebnf`-guided one that throws before appending
    ///   anything at all), or the selected partial carried no entry payload
    ///   (see ``attachingPendingEventSegments(events:to:)``) — so the caller
    ///   knows to re-queue them rather than let the drain silently destroy
    ///   them.
    private func recordTranscriptDelta(
        grammar: Grammar?,
        since: Date?,
        usage: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async -> (diffIncludedResponse: Bool, pendingEventsAttached: Bool) {
        let entries = backend.transcriptEntries()
        guard entries.count >= persistedEntryCount else {
            sessionRecordingLogger.warning(
                """
                transcript shrank from \(self.persistedEntryCount, privacy: .public) to \
                \(entries.count, privacy: .public) entries for session \
                \(self.id.description, privacy: .public); recording no entries for this turn and \
                resetting the baseline
                """
            )
            persistedEntryCount = entries.count
            // The count now names entries this session never recorded, so no
            // verifiable identity exists until the next successful diff
            // re-establishes one — see ``persistedBaseline``.
            persistedBaseline = nil
            return (false, pendingEvents.isEmpty)
        }

        let current = Transcript(entries: entries)
        if let baseline = persistedBaseline,
            let divergence = TranscriptDiffer.divergence(from: baseline, in: current)
        {
            sessionRecordingLogger.warning(
                """
                \(divergence.description, privacy: .public) for session \
                \(self.id.description, privacy: .public); recording a divergence marker instead of a \
                wrong diff and resetting the baseline
                """
            )
            await append(partial: makePartialEvent(kind: .divergence, grammar: grammar, text: divergence.description))
            persistedEntryCount = entries.count
            persistedBaseline = TranscriptDiffer.Baseline(transcript: current)
            return (false, pendingEvents.isEmpty)
        }

        let diffPartials = TranscriptDiffer.diff(
            lastSeen: Transcript(entries: entries.prefix(persistedEntryCount)),
            current: current,
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard !diffPartials.isEmpty else { return (false, pendingEvents.isEmpty) }

        let lastResponseIndex = diffPartials.lastIndex { $0.kind == .response }
        let (recordedPartials, pendingEventsAttached) = Self.attachingPendingEventSegments(
            events: pendingEvents, to: diffPartials)

        // Tool-call ids this diff has announced (`.toolCalls`) versus resolved
        // (`.toolOutput`), in request order — consulted once the loop finishes
        // to report any call whose output never arrived within this same
        // diff as ``SessionEvent/toolStatus(id:status:summary:)`` `.failed`.
        // Stay empty (and cost nothing further) when `onEvent` is `nil`, which
        // no turn's own sink is.
        var dispatchedToolCallIds: [String] = []
        var completedToolCallIds: Set<String> = []

        for (index, recordedPartial) in recordedPartials.enumerated() {
            let isTurnClose = index == lastResponseIndex
            let stampSince = (since != nil && isTurnClose) ? since : nil
            let stampUsage = (usage != nil && isTurnClose) ? usage : nil
            await append(
                partial: makePartialEvent(
                    kind: recordedPartial.kind,
                    grammar: grammar,
                    text: recordedPartial.text,
                    since: stampSince,
                    entry: recordedPartial.entry,
                    tokensIn: stampUsage?.input,
                    tokensOut: stampUsage?.output
                )
            )
            Self.emitSessionEvents(
                for: recordedPartial,
                dispatchedToolCallIds: &dispatchedToolCallIds,
                completedToolCallIds: &completedToolCallIds,
                onEvent: onEvent
            )
        }
        for id in dispatchedToolCallIds where !completedToolCallIds.contains(id) {
            onEvent?(.toolStatus(id: id, status: .failed, summary: nil))
        }
        persistedEntryCount = entries.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: current)
        return (lastResponseIndex != nil, pendingEventsAttached)
    }

    /// Returns `diffPartials` with one ``OperationEventSegment`` per event in
    /// `events` appended, in outbox order, onto the turn's own `.prompt`-kind
    /// partial — the durable counterpart to
    /// ``composedPrompt(pendingEvents:prompt:)``'s text preamble, attached
    /// only to what gets persisted, never to the SDK's own live transcript —
    /// together with whether that attachment actually happened.
    ///
    /// The augmentation target is the **last** `.prompt`-kind partial: a turn
    /// submits exactly one prompt of its own, and every earlier `.prompt` in
    /// the same diff is a synthetic one seeded *before* it — discovery
    /// priming's `.prompt` → `.toolCalls` → `.toolOutput` triple (see
    /// ``primeDiscoveryIfConfigured(prompt:emit:)``). The last `.prompt` is
    /// therefore always the entry whose flattened text carries the composed
    /// preamble, and attaching there is what keeps the segment view and the
    /// text view of one drained event from drifting apart (the
    /// ``OperationEventSegment/description`` contract).
    ///
    /// - Parameters:
    ///   - events: The events to attach, in outbox order.
    ///   - diffPartials: The turn's diff, in transcript order.
    /// - Returns: The partials to record, and whether the segments were
    ///   actually attached. `diffPartials` unchanged with `attached` `true`
    ///   when `events` is empty (nothing to attach, so nothing was missed);
    ///   unchanged with `attached` `false` when no `.prompt`-kind partial
    ///   exists, or the selected one carries no
    ///   ``TranscriptEvent/Partial/entry`` to append segments to — either
    ///   way the caller re-queues the events rather than let the drain
    ///   silently destroy them.
    static func attachingPendingEventSegments(
        events: [OperationEvent],
        to diffPartials: [TranscriptEvent.Partial]
    ) -> (partials: [TranscriptEvent.Partial], attached: Bool) {
        guard !events.isEmpty else { return (diffPartials, true) }
        guard let promptIndex = diffPartials.lastIndex(where: { $0.kind == .prompt }),
            let entry = diffPartials[promptIndex].entry
        else {
            return (diffPartials, false)
        }
        let segments = events.map { event in
            TranscriptEntryMapper.segmentPayload(.custom(OperationEventSegment(content: event)))
        }
        var partials = diffPartials
        partials[promptIndex] = partials[promptIndex].mapBody { text, _ in
            (text, entry.appendingSegments(segments))
        }
        return (partials, true)
    }

    /// Derives and emits the ``SessionEvent``s one recorded diff partial
    /// implies — the translation ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)``'s
    /// diff loop applies once per partial, given the full (ungated) content
    /// that partial carries: recording-level gating/redaction only ever
    /// applies to what a ``TranscriptRecorder`` persists to disk, never to
    /// what a live caller of ``RoutedSession/streamEvents(to:maxTokens:)``
    /// observes — the same principle by which ``RoutedSession/respond(to:maxTokens:)``
    /// already returns its full response text regardless of recording level.
    ///
    /// A `.toolCalls` partial yields one ``SessionEvent/toolCall(id:name:argumentsJSON:)``
    /// plus a paired ``SessionEvent/toolStatus(id:status:summary:)`` of
    /// ``ToolCallStatus/running`` per requested call, recording each id into
    /// `dispatchedToolCallIds`, then closes itself with one
    /// ``SessionEvent/entryRecorded(id:kind:)`` carrying the `.toolCalls`
    /// entry's own id. A `.toolOutput` partial yields one
    /// ``SessionEvent/toolStatus(id:status:summary:)`` of
    /// ``ToolCallStatus/completed``, carrying the tool's flattened output as
    /// `summary`, and records its id into `completedToolCallIds`. That id is
    /// resolved through the shared
    /// ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``
    /// rather than taken from the entry, so the id a completion carries is
    /// always one this same diff already announced as a
    /// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` — see that helper for
    /// why the SDK's own invariant is not enough to rely on. A `.reasoning`
    /// partial yields one ``SessionEvent/reasoningDelta(_:)`` followed by its
    /// own ``SessionEvent/entryRecorded(id:kind:)``. A `.response` partial
    /// yields exactly one ``SessionEvent/entryRecorded(id:kind:)`` — its text
    /// is already covered by the live ``SessionEvent/textDelta(_:)``
    /// fragments ``streamEventsGenerating(prompt:maxTokens:into:)`` yields
    /// during generation, so the close delivers the durable entry id and
    /// nothing else. Every other kind (`.instructions`, `.prompt`,
    /// `.session`, `.embedding`, the legacy `.toolCall`) yields nothing here
    /// (see ``RecordedEntryKind`` for why those kinds carry no close).
    ///
    /// A no-op — including no mutation of either tracking array — whenever
    /// `onEvent` is `nil`. That is no longer the ``respond(to:maxTokens:)``/
    /// ``dispatchNextPrompt()`` case: those turns derive their events too now,
    /// through the composed sink ``RoutedSessionActor/turnEventSink(_:)`` builds,
    /// so a ``RoutedSession/streamSessionEvents()`` subscriber sees them
    /// whichever entry point ran the turn.
    ///
    /// - Parameters:
    ///   - partial: The diff partial just recorded.
    ///   - dispatchedToolCallIds: Every tool-call id seen from a `.toolCalls`
    ///     partial earlier in this same diff, in request order — appended to
    ///     here.
    ///   - completedToolCallIds: Every tool-call id a `.toolOutput` partial
    ///     has already resolved earlier in this same diff — inserted into
    ///     here.
    ///   - onEvent: The sink to emit derived events to, or `nil` to skip
    ///     entirely.
    private static func emitSessionEvents(
        for partial: TranscriptEvent.Partial,
        dispatchedToolCallIds: inout [String],
        completedToolCallIds: inout Set<String>,
        onEvent: ((SessionEvent) -> Void)?
    ) {
        guard let onEvent, let entry = partial.entry else { return }
        switch partial.kind {
        case .toolCalls:
            for call in entry.toolCalls ?? [] {
                onEvent(.toolCall(id: call.id, name: call.toolName, argumentsJSON: call.argumentsJSON))
                onEvent(.toolStatus(id: call.id, status: .running, summary: nil))
                dispatchedToolCallIds.append(call.id)
            }
            onEvent(.entryRecorded(id: entry.entryId, kind: .toolCalls))
        case .toolOutput:
            let callId = ToolCallOutputPairing.completedToolCallId(
                forOutputEntryId: entry.entryId,
                dispatched: dispatchedToolCallIds,
                completed: completedToolCallIds
            )
            completedToolCallIds.insert(callId)
            onEvent(.toolStatus(id: callId, status: .completed, summary: partial.text))
        case .reasoning:
            onEvent(.reasoningDelta(partial.text ?? ""))
            onEvent(.entryRecorded(id: entry.entryId, kind: .reasoning))
        case .response:
            onEvent(.entryRecorded(id: entry.entryId, kind: .response))
        case .session, .instructions, .prompt, .embedding, .divergence, .toolCall, .unknown:
            break
        }
    }

    /// Records the session's first-line `session` meta event the first time this
    /// session records anything, so a generating session's transcript always opens
    /// with a `session` line while a session that never generates writes no file.
    ///
    /// The flag is flipped before the append so a reentrant turn during the meta
    /// append's suspension cannot emit a second meta event.
    func recordSessionMetaIfNeeded() async {
        guard !didRecordSessionMeta else { return }
        didRecordSessionMeta = true
        await append(partial: makePartialEvent(kind: .session, grammar: grammar))
    }

    /// Appends a partial event through the recorder into this session's own
    /// transcript directory, so siblings write separate files and the on-disk tree
    /// mirrors the fork lineage.
    ///
    /// This is the one choke point every event this session records goes
    /// through — turn diffs, the fold's boundary diff, journaled run
    /// terminals, the session meta line, and the bodyless close alike — so it
    /// is also where ``historyOrdinal`` advances: one step per entry-kind
    /// partial (``TranscriptEvent/Kind/isEntryKind``), exactly the events
    /// ``TranscriptTree/effectiveEntryEvents(forSession:)`` counts. Counting
    /// anywhere else could drift from what actually lands in the file.
    ///
    /// - Parameter partial: The event to record, minus its recorder-owned `seq`
    ///   and `ts`.
    func append(partial: TranscriptEvent.Partial) async {
        if partial.kind.isEntryKind {
            historyOrdinal += 1
        }
        await recorder.append(partial, to: recordingDirectory)
    }

    /// The number of milliseconds in one second — the scale ``TranscriptEvent/ms``
    /// is stamped in, applied to the `TimeInterval` seconds
    /// `Date.timeIntervalSince(_:)` reports.
    private static let millisecondsPerSecond: Double = 1_000

    /// Builds an event of the given kind stamped with this session's provenance.
    ///
    /// The `session` meta event, every entry-derived event
    /// ``recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)`` appends, and the throwing
    /// path's bodyless close event all share this one helper; a close-carrying
    /// call passes `since` to record the turn's measured duration.
    ///
    /// - Parameters:
    ///   - kind: The event kind to stamp — `.session` for meta, or the mapped
    ///     ``TranscriptEntryMapper/event(from:)`` kind for an entry-derived event.
    ///   - grammar: The guided-generation grammar in force, recorded as its
    ///     source, or `nil` for an unconstrained turn.
    ///   - text: The event's flattened body text from the mapper, or `nil` for
    ///     the bodyless `session` meta event or a bodyless close. Recording-level
    ///     and redaction trimming happen later, in the recorder.
    ///   - since: The turn's start instant to stamp `ms` with, or `nil` to leave
    ///     `ms` unset.
    ///   - entry: The structural payload mirroring the SDK's own
    ///     `Transcript.Entry`, or `nil` for the `session` meta event and the
    ///     throwing path's bodyless close.
    ///   - tokensIn: The turn's input token usage delta to stamp, or `nil` to
    ///     leave it unset.
    ///   - tokensOut: The turn's output token usage delta to stamp, or `nil`
    ///     to leave it unset.
    /// - Returns: The partial event for the recorder to stamp and append.
    func makePartialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil,
        text: String? = nil,
        since: Date? = nil,
        entry: TranscriptEntryPayload? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: kind,
            grammar: grammar?.source,
            text: text,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            ms: since.map { Int(Date().timeIntervalSince($0) * Self.millisecondsPerSecond) },
            entry: entry
        )
    }
}
