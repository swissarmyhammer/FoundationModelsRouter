import Foundation
import FoundationModels
import os

/// The logger for transcript shrink and divergence warnings.
private let sessionRecordingLogger = makeModuleLogger(category: "Recording")

/// The recording path of ``RoutedSessionActor``: the per-turn usage delta,
/// the transcript diff that becomes recorded events, the re-queue of
/// unattached events, and the session meta event.
extension RoutedSessionActor {
    /// Computes the turn's usage delta, records the transcript diff, and
    /// emits ``SessionEvent/turnEnded(_:)`` when usage is known.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force.
    ///   - since: The turn's start instant, used to stamp `ms`.
    ///   - usageBefore: The token-usage snapshot taken before the turn ran.
    ///   - pendingEvents: The events this turn drained from the outbox.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    /// - Returns: Whether the diff included a `.response` entry, the turn's
    ///   usage delta (`nil` when unknown), and whether `pendingEvents` were
    ///   attached to a persisted `.prompt` entry.
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

    /// Finishes the turn and re-queues `pendingEvents` when the diff had no
    /// `.prompt` partial to attach them to.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn.
    ///   - started: The turn's start time.
    ///   - usageBefore: The token-usage snapshot taken before the turn ran.
    ///   - pendingEvents: The events drained from ``outbox`` for this turn.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    /// - Returns: Whether the diff included a `.response` entry, and the
    ///   turn's usage delta.
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

    /// Re-posts `events` onto ``outbox`` through `SessionOutbox.requeue(event:)`.
    /// The events are not journaled a second time.
    ///
    /// - Parameter events: The events to re-queue, in outbox order.
    func requeueUnattachedPendingEvents(events: [OperationEvent]) async {
        for event in events {
            await outbox.requeue(event: event)
        }
    }

    /// The token usage delta between two ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots.
    ///
    /// - Parameters:
    ///   - before: The snapshot taken before the turn ran.
    ///   - after: The snapshot taken after the turn returned or threw.
    /// - Returns: The turn's `(input, output)` token counts, or `nil` when
    ///   either snapshot is `nil`.
    private static func usageDelta(
        before: (input: Int, output: Int)?,
        after: (input: Int, output: Int)?
    ) -> (input: Int, output: Int)? {
        guard let before, let after else { return nil }
        return (after.input - before.input, after.output - before.output)
    }

    /// Diffs the backend transcript against ``persistedEntryCount`` and
    /// records each entry the SDK appended since the last diff.
    ///
    /// A transcript shrink logs a warning, records nothing, and resets the
    /// count and baseline. A divergence from ``persistedBaseline`` logs a
    /// warning, records one ``TranscriptEvent/Kind/divergence`` marker, and
    /// resets the count and baseline. Otherwise `ms` and `usage` are stamped
    /// on the last `.response` partial only.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force.
    ///   - since: The turn's start instant used to stamp `ms`, or `nil`.
    ///   - usage: The turn's `(input, output)` token delta, or `nil`.
    ///   - pendingEvents: The events this turn drained from the outbox.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    /// - Returns: Whether the diff included a `.response` entry, and whether
    ///   `pendingEvents` were attached to a `.prompt` partial (`true` when
    ///   `pendingEvents` is empty).
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
        // diff as ``SessionEvent/toolStatus(id:status:summary:output:)`` `.failed`.
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
            onEvent?(.toolStatus(id: id, status: .failed, summary: nil, output: nil))
        }
        persistedEntryCount = entries.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: current)
        return (lastResponseIndex != nil, pendingEventsAttached)
    }

    /// Appends one ``OperationEventSegment`` per event onto the last
    /// `.prompt` partial in `diffPartials`.
    ///
    /// - Parameters:
    ///   - events: The events to attach, in outbox order.
    ///   - diffPartials: The turn's diff, in transcript order.
    /// - Returns: The partials to record, and whether the segments were
    ///   attached. `attached` is `true` when `events` is empty and `false`
    ///   when no `.prompt` partial with an entry exists.
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
            TranscriptEntryMapper.segmentPayload(OperationEventSegment(content: event).transcriptSegment)
        }
        var partials = diffPartials
        partials[promptIndex] = partials[promptIndex].mapBody { text, _ in
            (text, entry.appendingSegments(segments))
        }
        return (partials, true)
    }

    /// Emits the ``SessionEvent``s that one recorded diff partial implies.
    /// Recording-level gating does not apply to these live events.
    ///
    /// A `.toolCalls` partial emits a `toolCall` and a running `toolStatus`
    /// per call, then an `entryRecorded`. A `.toolOutput` partial emits a
    /// completed `toolStatus` with an id from
    /// ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``.
    /// A `.reasoning` partial emits a `reasoningDelta` and an `entryRecorded`.
    /// A `.response` partial emits one `entryRecorded`. Other kinds emit nothing.
    ///
    /// - Parameters:
    ///   - partial: The diff partial just recorded.
    ///   - dispatchedToolCallIds: Tool-call ids announced in this diff; appended to.
    ///   - completedToolCallIds: Tool-call ids resolved in this diff; inserted into.
    ///   - onEvent: The sink for derived events, or `nil` to do nothing.
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
                onEvent(.toolStatus(id: call.id, status: .running, summary: nil, output: nil))
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
            onEvent(.toolStatus(id: callId, status: .completed, summary: partial.text, output: entry.segments))
        case .reasoning:
            onEvent(.reasoningDelta(partial.text ?? ""))
            onEvent(.entryRecorded(id: entry.entryId, kind: .reasoning))
        case .response:
            onEvent(.entryRecorded(id: entry.entryId, kind: .response))
        case .session, .instructions, .prompt, .embedding, .divergence, .toolCall, .unknown:
            break
        }
    }

    /// Records the `session` meta event once, before the first recorded entry.
    /// The event carries this session's ``agentSpawn``, so a live sink sees
    /// the spawn fact without a read of `session.json`.
    func recordSessionMetaIfNeeded() async {
        guard !didRecordSessionMeta else { return }
        didRecordSessionMeta = true
        await append(partial: makePartialEvent(kind: .session, grammar: grammar, agentSpawn: agentSpawn))
    }

    /// Appends a partial event through the recorder into this session's
    /// transcript directory. Advances ``historyOrdinal`` for each entry-kind
    /// partial.
    ///
    /// - Parameter partial: The event to record, without `seq` and `ts`.
    func append(partial: TranscriptEvent.Partial) async {
        if partial.kind.isEntryKind {
            historyOrdinal += 1
        }
        await recorder.append(partial, to: recordingDirectory)
    }

    /// The number of milliseconds in one second, the scale of ``TranscriptEvent/ms``.
    private static let millisecondsPerSecond: Double = 1_000

    /// Builds an event of the given kind stamped with this session's provenance.
    ///
    /// - Parameters:
    ///   - kind: The event kind.
    ///   - grammar: The guided-generation grammar in force, or `nil`.
    ///   - text: The event's flattened body text, or `nil`.
    ///   - since: The turn's start instant used to stamp `ms`, or `nil`.
    ///   - entry: The structural payload that mirrors `Transcript.Entry`, or `nil`.
    ///   - tokensIn: The turn's input token delta, or `nil`.
    ///   - tokensOut: The turn's output token delta, or `nil`.
    ///   - agentSpawn: The spawn context to stamp, or `nil`. Only the
    ///     `.session` kind carries one.
    /// - Returns: The partial event for the recorder to stamp and append.
    func makePartialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil,
        text: String? = nil,
        since: Date? = nil,
        entry: TranscriptEntryPayload? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        agentSpawn: SessionSidecar.AgentSpawn? = nil
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
            entry: entry,
            agentSpawn: agentSpawn
        )
    }
}
