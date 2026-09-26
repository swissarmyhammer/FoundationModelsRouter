import FoundationModels

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

    /// The token ceiling the attempt gave the backend, or `nil`.
    let responseTokenCeiling: Int?

    /// The usage of the calls reported so far, summed.
    var reported: (input: Int, output: Int) = (0, 0)

    /// The usage of the newest call that ended, or `nil` before one ended.
    ///
    /// Its fed tokens are the whole render that the session sent to the model
    /// for that call. Its generated tokens are what the call added to that
    /// render. So the two together are the size of the render after the call.
    /// A tool loop sends the whole render again at each call, so the sum of
    /// the calls is not a size of the render (task ^tpsc0nf).
    var newestCall: (input: Int, output: Int)?

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
/// Two moments end a generation call. A tool call of the session's own turn
/// opens, so the call that asked for the tool ended. Or the attempt closes,
/// so its last call ended. At both moments the cumulative usage of the
/// backend has moved past the ledger, and the difference is the usage of
/// that one call. The stream gives no snapshot for a call that sends no
/// text, so the tool-call open is the one signal for such a call.
extension RoutedSessionActor {
    /// Opens the ledger of one attempt, and starts the attempt's
    /// ``ToolResultWatch`` from the backend entries that are there now.
    ///
    /// - Parameters:
    ///   - usageBefore: The cumulative usage of the backend when the attempt
    ///     starts, or `nil` for a backend that reports no usage. Such a
    ///     backend opens no ledger, and the attempt reports no call.
    ///   - responseTokenCeiling: The token ceiling the attempt gives the
    ///     backend, or `nil`.
    func openGenerationCallLedger(usageBefore: (input: Int, output: Int)?, responseTokenCeiling: Int?) {
        generationCallLedger = usageBefore.map {
            GenerationCallLedger(usageBefore: $0, responseTokenCeiling: responseTokenCeiling)
        }
        toolResultWatch = ToolResultWatch(entryIdsBeforeAttempt: Set(backend.transcriptEntries().map(\.id)))
    }

    /// Closes the ledger of the attempt.
    func closeGenerationCallLedger() {
        generationCallLedger = nil
    }

    /// Takes the usage of the generation call that ended since the last
    /// report, and adds it to the ledger.
    ///
    /// Reads ``backend`` from a task of the running submission at a
    /// tool-call open. The model waits in the tool at that moment, so no
    /// concurrent writer exists (see
    /// ``LanguageModelSessionBackend/transcriptEntries()``).
    ///
    /// - Parameter entryKind: What the call left in the transcript.
    /// - Returns: The usage of that call, or `nil` when no ledger is open,
    ///   the backend reports no usage, or no call ended.
    func takeGenerationCall(leaving entryKind: GenerationCallEntryKind) -> GenerationCallUsage? {
        guard let ledger = generationCallLedger, let usageAfter = backend.usageTokenCounts(),
            let call = ledger.usageOfEndedCall(usageAfter: usageAfter)
        else {
            return nil
        }
        generationCallLedger?.reported = (ledger.reported.input + call.input, ledger.reported.output + call.output)
        generationCallLedger?.newestCall = call
        toolResultWatch.noteEndedCall(tokens: call.input + call.output)
        let finishReason = FinishReason(
            turnEntries: unrecordedTranscriptEntries(), outputTokens: call.output,
            lastCallOutputTokens: call.output, responseTokenCeiling: ledger.responseTokenCeiling)
        return GenerationCallUsage(
            tokensIn: call.input,
            tokensOut: call.output,
            finishReason: finishReason,
            entryKind: entryKind,
            contextFill: ContextUsageState.measured(input: call.input, output: call.output)
                .fill(contextTokens: contextTokens))
    }

    /// Writes `usage` to the run journal and delivers it live.
    ///
    /// - Parameter usage: The usage of the call that ended.
    func report(generationCall usage: GenerationCallUsage) async {
        await append(
            partial: makePartialEvent(
                kind: .generationCall, grammar: grammar, text: usage.description,
                tokensIn: usage.tokensIn, tokensOut: usage.tokensOut))
        deliverLive(.generationCall(usage))
    }

    /// Reports the generation call that asked for the tool whose call opens
    /// now, when the usage shows one ended. The second tool call of one
    /// round finds no new usage and reports nothing.
    func reportGenerationCallAtToolOpen() async {
        guard let usage = takeGenerationCall(leaving: .toolCall) else { return }
        await report(generationCall: usage)
    }
}
