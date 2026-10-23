import FoundationModels

/// The prefill and the decode time of one generation call
/// (``GenerationCallUsage/timeToFirstToken`` and
/// ``GenerationCallUsage/decodeTime``), and whether its output was buffered
/// (``GenerationCallUsage/outputBuffered``). Each time is `nil` when the
/// session saw no output token of the call.
struct GenerationCallTiming: Sendable, Equatable {
    /// The time from the start of the call to its first output token.
    let timeToFirstToken: Duration?

    /// The time from the first output token of the call to its end.
    let decodeTime: Duration?

    /// Whether the output of the call reached the session as exactly one
    /// output event, so its first token cannot be seen.
    let outputBuffered: Bool

    /// The timing of a call whose first output token the session did not see.
    static let unobserved = GenerationCallTiming(timeToFirstToken: nil, decodeTime: nil, outputBuffered: false)

    /// The timing of a call whose output reached the session as exactly one
    /// output event: its first token cannot be seen, by design.
    static let buffered = GenerationCallTiming(timeToFirstToken: nil, decodeTime: nil, outputBuffered: true)
}

extension GenerationCallUsage {
    /// The prefill and the decode time of the call, and whether its output
    /// was buffered.
    var timing: GenerationCallTiming {
        GenerationCallTiming(timeToFirstToken: timeToFirstToken, decodeTime: decodeTime, outputBuffered: outputBuffered)
    }
}

/// The generation calls of one generate attempt, as ``RoutedSessionActor``
/// reports them one by one through ``SessionEvent/generationCall(_:)``.
///
/// The backend reports one cumulative usage. The ledger holds the usage the
/// attempt started from and the usage the reports so far have accounted
/// for. The difference to the cumulative usage of the moment is the usage of
/// the call that ended since the last report.
struct GenerationCallLedger {
    /// The cumulative usage of the backend when the attempt started.
    let usageBefore: (input: Int, output: Int)

    /// The cumulative cached input count of the backend when the attempt
    /// started, or `nil` for a backend that reports no cache count
    /// (``LanguageModelSessionBackend/cachedInputTokenCount()``).
    var cachedBefore: Int? = nil

    /// The token ceiling the attempt gave the backend, or `nil`.
    let responseTokenCeiling: Int?

    /// The usage of the calls reported so far, summed.
    var reported: (input: Int, output: Int) = (0, 0)

    /// The cached input tokens of the calls reported so far, summed.
    var reportedCached = 0

    /// The usage of the newest call that ended, or `nil` before one ended.
    ///
    /// Its fed tokens are the whole render that the session sent to the model
    /// for that call. Its generated tokens are what the call added to that
    /// render. So the two together are the size of the render after the call.
    /// A tool loop sends the whole render again at each call, so the sum of
    /// the calls is not a size of the render (task ^tpsc0nf).
    var newestCall: (input: Int, output: Int)?

    /// When the generation call that runs now started: the open of the
    /// ledger, the end of the last call, or the close of the last tool call.
    /// The span of a call whose first output token the session did not see
    /// runs from here to the report of the call. The output rate is not
    /// measured over it: that rate is over the decode time alone.
    var callStartedAt = ContinuousClock.now

    /// When the pass of the generation call that runs now started, on the
    /// clock of the pass observer, or `nil` before the backend reported one.
    /// A pass is one generation call (``GenerationCallPhase/passStarted(at:)``).
    var passStartedAt: ContinuousClock.Instant?

    /// When that pass gave its first output token, on the same clock, or
    /// `nil` before the backend reported one
    /// (``GenerationCallPhase/firstOutput(at:)``).
    var firstOutputAt: ContinuousClock.Instant?

    /// Whether that pass sent an output event, or `false` before the backend
    /// reported one (``GenerationCallPhase/firstOutputEvent``). A pass that
    /// sent one and gave no first output token is buffered.
    var sawOutputEvent = false

    /// Applies one reported phase of the model call: the start of a pass
    /// starts the times of a new generation call, its first output event
    /// marks that it sent output, and its first output ends its prefill.
    ///
    /// - Parameter phase: The phase the model call reported.
    mutating func apply(_ phase: GenerationCallPhase) {
        switch phase {
        case .passStarted(let instant):
            passStartedAt = instant
            firstOutputAt = nil
            sawOutputEvent = false
        case .firstOutputEvent:
            sawOutputEvent = true
        case .firstOutput(let instant):
            firstOutputAt = firstOutputAt ?? instant
        case .submissionQueued, .submissionStarted, .passEnded:
            break
        }
    }

    /// The prefill and the decode time of the generation call that ends at
    /// `endedAt`, and whether its output was buffered.
    ///
    /// - Parameter endedAt: When the call ended, on the clock of the pass
    ///   observer.
    /// - Returns: The time from the start of the pass to its first output,
    ///   and from that output to `endedAt`. ``GenerationCallTiming/buffered``
    ///   when the pass sent an output event and gave no first output, and
    ///   ``GenerationCallTiming/unobserved`` when the backend reported no
    ///   start or no output of the pass.
    func timingOfEndedCall(endedAt: ContinuousClock.Instant) -> GenerationCallTiming {
        guard let passStartedAt, let firstOutputAt else { return sawOutputEvent ? .buffered : .unobserved }
        return GenerationCallTiming(
            timeToFirstToken: passStartedAt.duration(to: firstOutputAt), decodeTime: firstOutputAt.duration(to: endedAt),
            outputBuffered: false)
    }

    /// The usage of the call that ended since the last report.
    ///
    /// - Parameter usageAfter: The cumulative usage of the backend now.
    /// - Returns: The `(input, output)` counts of that call, or `nil` when the
    ///   cumulative usage did not move, so no call ended.
    func usageOfEndedCall(usageAfter: (input: Int, output: Int)) -> (input: Int, output: Int)? {
        let input = usageAfter.input - usageBefore.input - reported.input
        let output = usageAfter.output - usageBefore.output - reported.output
        guard input > 0 || output > 0 else { return nil }
        return (input, output)
    }

    /// The cached input tokens of the call that ended since the last report.
    ///
    /// - Parameters:
    ///   - cachedAfter: The cumulative cached input count of the backend now.
    ///   - input: The fed tokens of that call. The cached count is never
    ///     more than them.
    /// - Returns: The cached part of the fed tokens of that call, or `nil`
    ///   when the backend reports no cache count.
    func cachedOfEndedCall(cachedAfter: Int?, input: Int) -> Int? {
        guard let cachedBefore, let cachedAfter else { return nil }
        return min(max(cachedAfter - cachedBefore - reportedCached, 0), input)
    }
}

extension GenerationCallEntryKind {
    /// What the call that appended the last of `entries` left: a tool call
    /// when that entry is a `.toolCalls` entry, text in every other case.
    ///
    /// The attempt's close reads this. An attempt that ends with a tool call
    /// is one whose tool call the session rejected, so its last call left
    /// no text.
    ///
    /// - Parameter entries: The entries the attempt appended, in transcript
    ///   order.
    init(leftBy entries: [Transcript.Entry]) {
        guard case .toolCalls = entries.last else {
            self = .text
            return
        }
        self = .toolCall
    }
}

/// ``RoutedSessionActor``'s per-call usage reports: one
/// ``SessionEvent/generationCall(_:)`` and one
/// ``TranscriptEvent/Kind/generationCall`` journal event for each generation
/// call of an attempt.
///
/// Two moments end a generation call. A tool call of the session's own submission
/// opens, so the call that asked for the tool ended. Or the attempt closes,
/// so its last call ended. At both moments the cumulative usage of the
/// backend has moved past the ledger, and the difference is the usage of
/// that one call. The stream gives no snapshot for a call that sends no
/// text, so the tool-call open is the one signal for such a call.
extension RoutedSessionActor {
    /// Opens the ledger of one attempt, starts the attempt's
    /// ``ToolResultWatch`` from the backend entries that are there now, and
    /// clears the ``noOpToolCallStop`` and the ``noOpToolCallRound`` of an
    /// earlier attempt.
    ///
    /// - Parameters:
    ///   - usageBefore: The cumulative usage of the backend when the attempt
    ///     starts, or `nil` for a backend that reports no usage. Such a
    ///     backend opens no ledger, and the attempt reports no call.
    ///   - responseTokenCeiling: The token ceiling the attempt gives the
    ///     backend, or `nil`.
    func openGenerationCallLedger(usageBefore: (input: Int, output: Int)?, responseTokenCeiling: Int?) {
        generationCallLedger = usageBefore.map {
            GenerationCallLedger(
                usageBefore: $0, cachedBefore: backend.cachedInputTokenCount(),
                responseTokenCeiling: responseTokenCeiling)
        }
        toolResultWatch = ToolResultWatch(entryIdsBeforeAttempt: Set(backend.transcriptEntries().map(\.id)))
        noOpToolCallStop = nil
        noOpToolCallRound = NoOpToolCallRound()
        delegationHintStop = nil
    }

    /// Closes the ledger of the attempt.
    func closeGenerationCallLedger() {
        generationCallLedger = nil
    }

    /// Takes the usage of the generation call that ended since the last
    /// report, adds it to the ledger, and records its metrics: its tokens in,
    /// cached and out, its whole time, its prefill and decode times, and its
    /// decode rate
    /// (``RouterMetrics/recordGenerationCall(tokensIn:tokensCached:tokensOut:timing:duration:model:slot:)``),
    /// and writes its span (``traceGenerationCall(for:duration:toolCallCount:)``).
    ///
    /// It first applies the pass phases that the backend reported
    /// (``drainGenerationPassPhases()``), so the ledger holds the start and
    /// the first output of the pass of the call.
    ///
    /// Reads ``backend`` from a task of the running submission at a
    /// tool-call open. The model waits in the tool at that moment, so no
    /// concurrent writer exists (see
    /// ``LanguageModelSessionBackend/transcriptEntries()``). The record is
    /// synchronous and adds no suspension point.
    ///
    /// - Parameter entryKind: What the call left in the transcript.
    /// - Returns: The usage of that call, or `nil` when no ledger is open,
    ///   the backend reports no usage, or no call ended.
    func takeGenerationCall(leaving entryKind: GenerationCallEntryKind) -> GenerationCallUsage? {
        drainGenerationPassPhases()
        guard let ledger = generationCallLedger, let usageAfter = backend.usageTokenCounts(),
            let call = ledger.usageOfEndedCall(usageAfter: usageAfter)
        else {
            return nil
        }
        let cached = ledger.cachedOfEndedCall(cachedAfter: backend.cachedInputTokenCount(), input: call.input)
        let ended = noteEndedCall(call, cached: cached, backendUsage: call, of: ledger)
        let submissionEntries = unrecordedTranscriptEntries()
        let finishReason = FinishReason(
            submissionEntries: submissionEntries, outputTokens: call.output,
            lastCallOutputTokens: call.output, responseTokenCeiling: ledger.responseTokenCeiling)
        let usage = generationCallUsage(
            of: call, cached: cached, timing: ended.timing, duration: ended.duration, finishReason: finishReason,
            entryKind: entryKind)
        traceGenerationCall(
            for: usage, duration: ended.duration,
            toolCallCount: GenerationCallEntryKind.toolCallCount(of: submissionEntries))
        return usage
    }

    /// Takes the usage of the generation call that a watch stop cancelled
    /// (task ^3anq1yz), adds it to the ledger, and records its metrics.
    ///
    /// The session reads it before it replaces ``backend``, because a
    /// replaced backend starts a usage count of its own. A cancelled call
    /// ends before the backend reports its usage: the MLX executor sends its
    /// one usage update only after a call completes. So each count that the
    /// backend did not report comes from `counted`.
    ///
    /// A call that ended at a tool call is not in flight: the open of its
    /// tool reported it (``reportGenerationCallAtToolOpen()``). When the usage
    /// did not move since that report, no call is left to report.
    ///
    /// - Parameters:
    ///   - counted: The counted size of the render that the stopped call
    ///     received, and of the output that it wrote.
    ///   - endedAtToolCall: Whether the stopped call ended at a tool call.
    ///   - finishReason: The finish reason of the stop.
    ///   - entryKind: What the stopped call left in the transcript.
    ///   - toolCallCount: How many tool calls the stopped call asked for.
    /// - Returns: The usage of the stopped call, and the tokens that it adds
    ///   to the usage that the backend reported. `nil` when no ledger is
    ///   open, the backend reports no usage, or a call that ended at a tool
    ///   call has no usage left to report.
    func takeStoppedGenerationCall(
        counted: (input: Int, output: Int), endedAtToolCall: Bool, finishReason: FinishReason,
        entryKind: GenerationCallEntryKind, toolCallCount: Int
    ) -> (usage: GenerationCallUsage, addedUsage: (input: Int, output: Int))? {
        drainGenerationPassPhases()
        guard let ledger = generationCallLedger, let usageAfter = backend.usageTokenCounts() else { return nil }
        let backendUsage = ledger.usageOfEndedCall(usageAfter: usageAfter)
        guard backendUsage != nil || !endedAtToolCall else { return nil }
        let reported = backendUsage ?? (input: 0, output: 0)
        let call = (
            input: reported.input > 0 ? reported.input : counted.input,
            output: reported.output > 0 ? reported.output : counted.output
        )
        let cached = ledger.cachedOfEndedCall(cachedAfter: backend.cachedInputTokenCount(), input: call.input)
        let ended = noteEndedCall(call, cached: cached, backendUsage: reported, of: ledger)
        let usage = generationCallUsage(
            of: call, cached: cached, timing: ended.timing, duration: ended.duration, finishReason: finishReason,
            entryKind: entryKind)
        traceGenerationCall(for: usage, duration: ended.duration, toolCallCount: toolCallCount)
        return (usage, (input: call.input - reported.input, output: call.output - reported.output))
    }

    /// Records the metrics of one generation call that ended, and moves the
    /// ledger past it.
    ///
    /// The prefill and the decode time of the call are read on the clock of
    /// the pass observer (``GenerationPassObserver/clock``), which stamped
    /// the start and the first output of the pass.
    ///
    /// - Parameters:
    ///   - call: The fed and generated tokens of the call, as the session
    ///     reports them.
    ///   - cached: The cached part of the fed tokens of the call, or `nil`
    ///     when the backend reports no cache count. The ledger adds it.
    ///   - backendUsage: The part of the cumulative usage of the backend that
    ///     the call accounts for. The ledger adds it, so the next call starts
    ///     where the backend count is.
    ///   - ledger: The ledger of the attempt, as it was before the call ended.
    /// - Returns: The prefill and the decode time of the call, and how long
    ///   the call ran: its prefill and its decode when the session saw its
    ///   first output token, else the time since the ledger last moved
    ///   (``GenerationCallLedger/callStartedAt``).
    private func noteEndedCall(
        _ call: (input: Int, output: Int), cached: Int?, backendUsage: (input: Int, output: Int),
        of ledger: GenerationCallLedger
    ) -> (timing: GenerationCallTiming, duration: Duration) {
        let endedAt = ContinuousClock.now
        let timing = ledger.timingOfEndedCall(endedAt: generationPassObserver.clock.now)
        let duration =
            timing.timeToFirstToken.flatMap { prefill in timing.decodeTime.map { prefill + $0 } }
            ?? ledger.callStartedAt.duration(to: endedAt)
        sessionMetrics.recordGenerationCall(
            tokensIn: call.input, tokensCached: cached, tokensOut: call.output, timing: timing, duration: duration,
            model: model, slot: slot)
        generationCallLedger?.callStartedAt = endedAt
        generationCallLedger?.passStartedAt = nil
        generationCallLedger?.firstOutputAt = nil
        generationCallLedger?.sawOutputEvent = false
        generationCallLedger?.reported = (
            ledger.reported.input + backendUsage.input, ledger.reported.output + backendUsage.output
        )
        generationCallLedger?.reportedCached = ledger.reportedCached + (cached ?? 0)
        generationCallLedger?.newestCall = call
        toolResultWatch.noteEndedCall(tokens: call.input + call.output)
        return (timing, duration)
    }

    /// The usage report of one generation call.
    ///
    /// - Parameters:
    ///   - call: The fed and generated tokens of the call.
    ///   - cached: The cached part of the fed tokens, or `nil`.
    ///   - timing: The prefill and the decode time of the call.
    ///   - duration: The whole time of the call.
    ///   - finishReason: Why the call stopped.
    ///   - entryKind: What the call left in the transcript.
    /// - Returns: The report, with the fill of the render after the call.
    private func generationCallUsage(
        of call: (input: Int, output: Int), cached: Int?, timing: GenerationCallTiming, duration: Duration,
        finishReason: FinishReason, entryKind: GenerationCallEntryKind
    ) -> GenerationCallUsage {
        GenerationCallUsage(
            tokensIn: call.input,
            tokensOut: call.output,
            finishReason: finishReason,
            entryKind: entryKind,
            contextFill: ContextUsageState.measured(input: call.input, output: call.output)
                .fill(contextTokens: contextTokens),
            tokensCached: cached,
            timeToFirstToken: timing.timeToFirstToken,
            decodeTime: timing.decodeTime,
            outputBuffered: timing.outputBuffered,
            callDuration: duration)
    }

    /// Writes `usage` to the run journal and delivers it live.
    ///
    /// - Parameter usage: The usage of the call that ended.
    func report(generationCall usage: GenerationCallUsage) async {
        await append(
            partial: makePartialEvent(
                kind: .generationCall, grammar: grammar, text: usage.description,
                tokensIn: usage.tokensIn, tokensCached: usage.tokensCached, tokensOut: usage.tokensOut,
                callTiming: usage.timing, callDuration: usage.callDuration))
        deliverLive(.generationCall(usage))
    }

    /// Reports the generation call that asked for the tool whose call opens
    /// now, when the usage shows one ended. The second tool call of one
    /// round finds no new usage and reports nothing.
    func reportGenerationCallAtToolOpen() async {
        guard let usage = takeGenerationCall(leaving: .toolCall) else { return }
        await report(generationCall: usage)
    }

    /// Moves the ledger of the attempt across one tool invocation record of
    /// the session's own submission. ``deliver(invocation:)`` calls it for
    /// each record.
    ///
    /// An open record ends the generation call that asked for the tool, so
    /// the usage of that call is reported (``reportGenerationCallAtToolOpen()``).
    /// A close record starts the next generation call now: the model reads
    /// the tool output in that call, so the time of the tool body is not part
    /// of the duration of a generation call
    /// (``GenerationCallLedger/callStartedAt``).
    ///
    /// - Parameter record: The tool invocation record the outbox forwarded.
    func noteGenerationCallBoundary(at record: ToolInvocationRecord) async {
        guard record.closedAt != nil else {
            await reportGenerationCallAtToolOpen()
            return
        }
        generationCallLedger?.callStartedAt = ContinuousClock.now
    }
}
