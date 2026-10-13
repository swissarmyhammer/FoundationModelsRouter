import Foundation
import FoundationModels
import Logging

/// The recording path of ``RoutedSessionActor``: the usage delta of each
/// submission, the transcript diff that becomes recorded events, the re-queue
/// of unattached events, and the session meta event.
extension RoutedSessionActor {
    /// Computes the usage delta of the attempt, records the transcript diff,
    /// and ends the running submission: it sends
    /// ``SessionEvent/submissionEnded(_:)``, with the usage when the backend
    /// reports it.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force.
    ///   - since: The start instant of the submission, used to stamp `ms`.
    ///   - usageBefore: The token-usage snapshot taken before the submission ran.
    ///   - responseTokenCeiling: The token ceiling the submission gave its backend,
    ///     or `nil` when it gave none.
    ///   - deliveredMail: The mail this submission delivered, in take order.
    ///   - entryIdsBeforeAttempt: The ids of the backend entries from before
    ///     the attempt. The records of `deliveredMail` go only on a `.prompt`
    ///     entry that is not one of them.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    ///   - stopReason: The reason of a stop that the session made itself, or
    ///     `nil` to read the reason from the entries of the attempt.
    ///   - replacedBackend: What a watch stop or a compaction yield measured
    ///     before it replaced ``backend``, or `nil` for any other end of an
    ///     attempt.
    /// - Returns: Whether the diff included a `.response` entry, the usage
    ///   delta of the submission (`nil` when unknown), whether the records of
    ///   `deliveredMail` were attached to a persisted `.prompt` entry, and why
    ///   the attempt stopped.
    private func finishSubmission(
        grammar: Grammar?,
        since: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        deliveredMail: [Mail],
        entryIdsBeforeAttempt: Set<String>,
        onEvent: ((SessionEvent) -> Void)? = nil,
        stopReason: FinishReason? = nil,
        replacedBackend: ReplacedBackendMeasure? = nil
    ) async -> (
        diffIncludedResponse: Bool, usage: (input: Int, output: Int)?, deliveredMailAttached: Bool,
        finishReason: FinishReason
    ) {
        let usage = Self.usageDelta(before: usageBefore, after: backend.usageTokenCounts())
        // Read before the diff below, which moves the baseline past this
        // attempt's entries.
        let submissionEntries = unrecordedTranscriptEntries()
        let finishReason =
            stopReason
            ?? FinishReason(
                submissionEntries: submissionEntries, outputTokens: usage?.output,
                lastCallOutputTokens: backend.lastGenerationCallOutputTokenCount(),
                responseTokenCeiling: responseTokenCeiling)
        // The last generation call of the attempt. Taken before the diff for
        // the same reason, and reported after it, so its journal event
        // follows the entries the call left. A watch stop (task ^3anq1yz) and
        // a compaction yield (task ^8szxhab) took their stopped call before
        // they replaced `backend`, because the replaced backend starts a
        // usage count of its own.
        let lastGenerationCall =
            replacedBackend == nil
            ? takeGenerationCall(leaving: GenerationCallEntryKind(leftBy: submissionEntries))
            : replacedBackend?.stoppedCall
        // The newest call of the attempt is the size of the render. Read it
        // before the ledger closes. An open ledger with no ended call gives
        // the delta of the attempt, which is then zero. After a watch stop,
        // the next pass receives the render without the cut part, so the
        // counted size of that render comes first.
        let renderedContext =
            replacedBackend?.renderTokens.map { (input: $0, output: 0) } ?? generationCallLedger?.newestCall ?? usage
        closeGenerationCallLedger()
        // Each mail record that came before this diff is on disk first, so a
        // restore reads the records of one mail in the order they came.
        await flushMailRecords()
        let (diffIncludedResponse, deliveredMailAttached) = await recordTranscriptDelta(
            grammar: grammar, since: since, usage: usage, deliveredMail: deliveredMail,
            entryIdsBeforeAttempt: entryIdsBeforeAttempt, onEvent: onEvent)
        // The submission ended, with success or failure, and its entries are
        // recorded: a settled point (`generation-queue.md`, section 5.8).
        settleTranscript()
        if let lastGenerationCall {
            await report(generationCall: lastGenerationCall)
        }
        // The counter is the size of the render that the session sends to
        // the model: the instructions, the latest compaction snapshot, and
        // the messages since that snapshot (task ^tpsc0nf). Each generation
        // call receives the whole render, so the fed and generated tokens of
        // the newest call are that size. The delta of the attempt is not: a
        // tool loop sends the whole render again at each call, and the delta
        // adds each of them. A compaction restarts the counter when it
        // applies its snapshot (the compaction handler
        // ``performCompaction(_:_:)``, in `RoutedSessionActorCompaction.swift`).
        //
        // Only a submission whose diff included a `.response`-kind entry
        // measured the render. A submission rejected before it touched
        // `backend` (for example, a guided submission whose grammar validation
        // throws pre-flight) keeps the last known counter, and does not set it
        // to a meaningless zero. See ``usageState``. A watch stop that counted
        // the render after it measured the render too, whatever its diff
        // holds: a pass that only reasoned leaves no `.response` entry.
        let measuredRender = diffIncludedResponse || replacedBackend?.renderTokens != nil
        if measuredRender {
            usageState = renderedContext.map { .measured(input: $0.input, output: $0.output) } ?? .unknown
        }
        // Ends the submission that the session opened for this attempt. The
        // session sends ``SessionEvent/submissionEnded(_:)`` for every
        // submission it opened, also when the backend reports no usage: the
        // usage of the end is then `nil`. An attempt that the session refused
        // before it touched `backend` still measures a true (zero) delta
        // between two real snapshots, so its end carries that usage. The
        // usage reads `contextFill` after the `usageState` update above, so
        // the end of this attempt carries the fill it just measured, or the
        // prior value when this attempt did not touch `backend`
        // (task g2hcm36).
        endSubmission(
            usage: usage.map {
                TokenUsage(
                    tokensIn: $0.input, tokensOut: $0.output, contextFill: contextFill, finishReason: finishReason)
            },
            finishReason: finishReason,
            measuredRender: measuredRender ? renderedContext : nil,
            onEvent: onEvent)
        return (diffIncludedResponse, usage, deliveredMailAttached, finishReason)
    }

    /// The entries of the backend transcript that ``persistedBaseline`` does
    /// not hold: the entries the attempt in flight appended.
    ///
    /// Read by entry id, so a transcript that diverged from the baseline still
    /// gives only its new entries.
    ///
    /// - Returns: The unrecorded entries, in transcript order.
    func unrecordedTranscriptEntries() -> [Transcript.Entry] {
        let recordedIds = Set(persistedBaseline.entryIds)
        return backend.transcriptEntries().filter { !recordedIds.contains($0.id) }
    }

    /// Finishes the submission and re-queues the run mail of `deliveredMail`
    /// when the diff had no `.prompt` partial to attach its records to.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this submission.
    ///   - started: The start time of the submission.
    ///   - usageBefore: The token-usage snapshot taken before the submission ran.
    ///   - responseTokenCeiling: The token ceiling the submission gave its backend,
    ///     or `nil` when it gave none.
    ///   - deliveredMail: The mail this submission delivered, in take order.
    ///   - entryIdsBeforeAttempt: The ids of the backend entries from before
    ///     the attempt. The records of `deliveredMail` go only on a `.prompt`
    ///     entry that is not one of them.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    ///   - stopReason: The reason of a stop that the session made itself, or
    ///     `nil` to read the reason from the entries of the attempt.
    ///   - replacedBackend: What a watch stop or a compaction yield measured
    ///     before it replaced ``backend``, or `nil` for any other end of an
    ///     attempt.
    /// - Returns: Whether the diff included a `.response` entry, the usage
    ///   delta of the submission, and why the attempt stopped.
    func finishSubmissionAndRequeueIfUnattached(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        deliveredMail: [Mail],
        entryIdsBeforeAttempt: Set<String>,
        onEvent: ((SessionEvent) -> Void)? = nil,
        stopReason: FinishReason? = nil,
        replacedBackend: ReplacedBackendMeasure? = nil
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?, finishReason: FinishReason) {
        let (diffIncludedResponse, usage, deliveredMailAttached, finishReason) = await finishSubmission(
            grammar: grammar, since: started, usageBefore: usageBefore,
            responseTokenCeiling: responseTokenCeiling, deliveredMail: deliveredMail,
            entryIdsBeforeAttempt: entryIdsBeforeAttempt, onEvent: onEvent,
            stopReason: stopReason, replacedBackend: replacedBackend)
        // The pump already destructively took the run mail of `deliveredMail`
        // from the mail queue of `outbox` before `body()` ran. When this
        // submission's diff produced no `.prompt`-kind partial of the attempt
        // itself to attach its records to — every `.ebnf`-guided
        // submission, whose backend validates and throws before touching its
        // live session at all (see `MLXFoundationModelsSessionBackend.respond(to:
        // following:maxTokens:)`) — the
        // composed prompt was never actually delivered to the model and the
        // mail was never recorded either. Re-queue the run mail so a later
        // submission gets another chance, instead of the take silently
        // destroying state a failed submission never got to deliver. Only the
        // submission that delivers the mail at last records it, so the
        // context holds it one time.
        if !deliveredMailAttached {
            requeueUndeliveredRunMail(deliveredMail)
        }
        return (diffIncludedResponse, usage, finishReason)
    }

    /// Puts the run mail of `mail` back in the queue with the same ids
    /// (``SessionOutbox/requeue(_:)``), held. The events are not journaled a
    /// second time, and a submission that could not take them is not started
    /// again at once. User-type mail does not go back: the answer that
    /// delivered it ends it.
    ///
    /// Each run mail is matched by id to the run mail of the open answer
    /// (``openAnswerRunMail``). That mail leaves the open answer, so the
    /// terminal event of the answer does not end it: a later answer that
    /// delivers it ends it. Mail that the closed queue refuses gets its
    /// terminal event ``SessionEvent/cancelled(_:)``. When ``cancelAll()``
    /// stopped the answer, nothing goes back to the queue: the answer already
    /// sent the terminal event of that mail.
    ///
    /// - Parameter mail: The mail the submission delivered, in take order.
    func requeueUndeliveredRunMail(_ mail: [Mail]) {
        let runMailIds = Set(mail.filter(\.isRunMail).map(\.id))
        let given = openAnswerRunMail.filter { runMailIds.contains($0.id) }
        openAnswerRunMail.removeAll { runMailIds.contains($0.id) }
        guard !given.isEmpty else { return }
        // The answer that ``cancelAll()`` stopped already sent the terminal
        // event of this mail, so it does not go back to the queue.
        guard !openAnswerMail.isSilenced else {
            outbox.forget(given.map(\.id))
            return
        }
        openAnswerMail.remove(given.map(\.id))
        settleCancelledMail(outbox.requeue(given).map(\.id))
    }

    /// The token usage delta between two ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots.
    ///
    /// - Parameters:
    ///   - before: The snapshot taken before the submission ran.
    ///   - after: The snapshot taken after the submission returned or threw.
    /// - Returns: The `(input, output)` token counts of the submission, or
    ///   `nil` when either snapshot is `nil`.
    static func usageDelta(
        before: (input: Int, output: Int)?,
        after: (input: Int, output: Int)?
    ) -> (input: Int, output: Int)? {
        guard let before, let after else { return nil }
        return (after.input - before.input, after.output - before.output)
    }

    /// Diffs the backend transcript against ``persistedBaseline`` and records
    /// each entry the SDK appended since the last diff. A transcript only
    /// appends: no branch here drops an entry.
    ///
    /// A transcript that still extends the recorded prefix is diffed by
    /// position from ``persistedEntryCount``. A transcript that diverged from
    /// the baseline (``TranscriptDiffer/divergence(from:in:)``: an entry id
    /// moved, the boundary entry was rewritten in place, or the transcript
    /// shrank) is diffed by entry id instead, so every entry the record has
    /// never seen is appended, in transcript order, and then one
    /// ``TranscriptEvent/Kind/divergence`` marker is appended beside them.
    /// An entry rewritten under a recorded id is not appended a second time;
    /// the marker names it. After any recorded diff the whole current
    /// transcript becomes the baseline and ``persistedEntryCount`` its
    /// count: every entry of it is then in the record, either from before or
    /// from this diff, so the reset loses nothing. `ms` and `usage` are
    /// stamped on the last `.response` partial only. Each recorded partial
    /// emits its ``SessionEvent``s on a diverged submission exactly as on a
    /// plain one.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force.
    ///   - since: The start instant of the submission used to stamp `ms`, or `nil`.
    ///   - usage: The `(input, output)` token delta of the submission, or `nil`.
    ///   - deliveredMail: The mail this submission delivered, in take order.
    ///   - entryIdsBeforeAttempt: The ids of the backend entries from before
    ///     the attempt.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    /// - Returns: Whether the diff included a `.response` entry, and whether
    ///   the records of `deliveredMail` were attached to a `.prompt` partial
    ///   of the attempt (`true` when `deliveredMail` is empty).
    private func recordTranscriptDelta(
        grammar: Grammar?,
        since: Date?,
        usage: (input: Int, output: Int)?,
        deliveredMail: [Mail],
        entryIdsBeforeAttempt: Set<String>,
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async -> (diffIncludedResponse: Bool, deliveredMailAttached: Bool) {
        let current = Transcript(entries: backend.transcriptEntries())
        let divergence = TranscriptDiffer.divergence(from: persistedBaseline, in: current)
        let diffPartials = TranscriptDiffer.partials(
            baseline: persistedBaseline,
            current: current,
            divergence: divergence,
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard divergence != nil || !diffPartials.isEmpty else { return (false, deliveredMail.isEmpty) }

        let lastResponseIndex = diffPartials.lastIndex { $0.kind == .response }
        let (recordedPartials, deliveredMailAttached) = Self.attachingDeliveredMailRecords(
            deliveredMail, to: diffPartials, excluding: entryIdsBeforeAttempt)

        // Tool-call ids this diff has announced (`.toolCalls`) versus resolved
        // (`.toolOutput`), in request order — consulted once the loop finishes
        // to report any call whose output never arrived within this same
        // diff as ``SessionEvent/toolStatus(id:status:summary:output:)`` `.failed`.
        // Stay empty (and cost nothing further) when `onEvent` is `nil`, which
        // the own sink of no answer is.
        var dispatchedToolCallIds: [String] = []
        var completedToolCallIds: Set<String> = []

        for (index, recordedPartial) in recordedPartials.enumerated() {
            let isSubmissionClose = index == lastResponseIndex
            let stampSince = (since != nil && isSubmissionClose) ? since : nil
            let stampUsage = (usage != nil && isSubmissionClose) ? usage : nil
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
        if let divergence {
            await appendDivergenceMarker(divergence, grammar: grammar)
        }
        persistedEntryCount = current.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: current)
        return (lastResponseIndex != nil, deliveredMailAttached)
    }

    /// Logs `divergence` and appends its ``TranscriptEvent/Kind/divergence``
    /// marker, after the entries the diverged submission recorded.
    ///
    /// - Parameters:
    ///   - divergence: The non-append change the diff of the submission found.
    ///   - grammar: The guided-generation grammar in force.
    private func appendDivergenceMarker(_ divergence: TranscriptDiffer.Divergence, grammar: Grammar?) async {
        sessionLogger(.recording).warning(
            """
            the transcript diverges from the recorded entries; the unseen entries of the submission \
            are recorded and a divergence marker follows them
            """,
            metadata: [
                RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)",
                RouterTelemetry.LogMetadataKey.divergence: "\(divergence.description)",
            ])
        await append(partial: makePartialEvent(kind: .divergence, grammar: grammar, text: divergence.description))
    }

    /// Appends one ``MailRecord/mailDelivered(_:)`` record
    /// (``MailRecordSegment``) per mail onto the `.prompt` partial of the
    /// attempt itself, in take order: the delivery of each mail in the
    /// transcript, before the model output of the submission.
    ///
    /// The prompt of the attempt is the last `.prompt` partial whose entry
    /// was not in the backend before the attempt. The diff can also hold
    /// older `.prompt` entries that the session did not record yet (for
    /// example the entries that seed a backend). The records never go on one
    /// of those, because the model did not read the mail there.
    ///
    /// - Parameters:
    ///   - mail: The mail to attach, in take order.
    ///   - diffPartials: The diff of the submission, in transcript order.
    ///   - entryIdsBeforeAttempt: The ids of the backend entries from before
    ///     the attempt.
    /// - Returns: The partials to record, and whether the records were
    ///   attached. `attached` is `true` when `mail` is empty and `false`
    ///   when the diff holds no `.prompt` partial of the attempt.
    static func attachingDeliveredMailRecords(
        _ mail: [Mail],
        to diffPartials: [TranscriptEvent.Partial],
        excluding entryIdsBeforeAttempt: Set<String>
    ) -> (partials: [TranscriptEvent.Partial], attached: Bool) {
        guard !mail.isEmpty else { return (diffPartials, true) }
        guard
            let promptIndex = diffPartials.lastIndex(where: { partial in
                guard partial.kind == .prompt, let entry = partial.entry else { return false }
                return !entryIdsBeforeAttempt.contains(entry.entryId)
            }),
            let entry = diffPartials[promptIndex].entry
        else {
            return (diffPartials, false)
        }
        let segments = mail.map { delivered in
            TranscriptEntryMapper.segmentPayload(MailRecordSegment(content: .mailDelivered(delivered)))
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
        case .session, .instructions, .prompt, .embedding, .divergence, .generationCall, .repeatedPartRemoval,
            .watchStop, .mail, .toolCall, .unknown:
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
    /// transcript directory. It first writes and closes the open merged
    /// progress row (``closeOpenProgressRow()``), because a different event
    /// closes that row and the row comes first in post order.
    ///
    /// - Parameter partial: The event to record, without `seq` and `ts`.
    func append(partial: TranscriptEvent.Partial) async {
        await closeOpenProgressRow()
        await appendToRecorder(partial)
    }

    /// Appends a partial event through the recorder into this session's
    /// transcript directory, and leaves ``openProgressRow`` as it is.
    /// Advances ``historyOrdinal`` for each entry-kind partial. Each write
    /// other than the write of the merged progress row goes through
    /// ``append(partial:)``.
    ///
    /// - Parameter partial: The event to record, without `seq` and `ts`.
    func appendToRecorder(_ partial: TranscriptEvent.Partial) async {
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
    ///   - since: The start instant of the submission used to stamp `ms`, or `nil`.
    ///   - entry: The structural payload that mirrors `Transcript.Entry`, or `nil`.
    ///   - tokensIn: The input token delta of the submission, or `nil`.
    ///   - tokensOut: The output token delta of the submission, or `nil`.
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
