import FoundationModels

/// What one generate attempt saw at its tool-result boundaries: the context
/// of its newest ended generation call, the tool results of the round since
/// that call, and the yield marker.
///
/// ``RoutedSessionActor`` holds one value for the attempt in flight, and
/// ``RoutedSessionActor/openGenerationCallLedger(usageBefore:responseTokenCeiling:)``
/// makes a new one for each attempt.
struct ToolResultWatch {
    /// The ids of the backend entries that were there when the attempt
    /// started. Every other entry is an entry of the attempt.
    var entryIdsBeforeAttempt: Set<String> = []

    /// The composed prompt of the attempt.
    var composedPrompt = ""

    /// The input and output tokens of the newest generation call that
    /// ended, as the engine reports them, or `nil` before one ended.
    var newestCallTokens: Int?

    /// The tool results of the round that the newest ended call asked for,
    /// in the order they came back.
    var roundResults: [ToolResultAppend] = []

    /// The tokens of ``roundResults``, as the session's counter counts them.
    var roundResultTokens = 0

    /// The yield marker: set when a tool result crossed the compaction
    /// trigger and the session stopped the model call, else `nil`.
    var yield: CompactionYield?

    /// Starts a new round: a generation call ended.
    ///
    /// - Parameter callTokens: The input and output tokens of that call.
    mutating func noteEndedCall(tokens callTokens: Int) {
        newestCallTokens = callTokens
        roundResults = []
        roundResultTokens = 0
    }

    /// Adds one tool result to the round.
    ///
    /// - Parameters:
    ///   - result: The tool result.
    ///   - tokens: Its tokens.
    mutating func append(_ result: ToolResultAppend, tokens: Int) {
        roundResults.append(result)
        roundResultTokens += tokens
    }
}

/// The marker a session sets when a tool result crosses the compaction
/// trigger inside a turn, and the facts it needs to go on after the stop.
///
/// It is different from a user stop (``RoutedSession/cancelCurrentTurn()``):
/// only the tool-result boundary sets it, and a user stop wins over it.
struct CompactionYield: Sendable {
    /// The context size that crossed the trigger: the newest ended call plus
    /// the tool results of its round.
    let measuredTokens: Int

    /// The tool results of the round, in order. The rebuilt transcript ends
    /// with them.
    let results: [ToolResultAppend]

    /// The backend transcript read inside the tool call, before the stop.
    let liveEntries: [Transcript.Entry]

    /// The entries of the newest stream snapshot, or none.
    let snapshotEntries: [Transcript.Entry]
}

/// Rebuilds the transcript of an attempt that a compaction yield stopped.
///
/// `LanguageModelSession` keeps no entry of a call that throws, and Apple
/// does not state which entries a snapshot slice holds. So the rebuild merges
/// every source by entry id and adds only what no source holds.
enum InFlightTranscript {
    /// The transcript of the stopped attempt, whole and in order.
    ///
    /// 1. The backend transcript after the stop, then each entry of the
    ///    other sources that it does not hold, in their order.
    /// 2. A `.prompt` entry with `composedPrompt` in front of the entries of
    ///    the attempt, when none of them is a `.prompt` entry.
    /// 3. For each tool result: its `.toolOutput` entry, paired to a call of
    ///    the same tool that has no output yet. A result with no such call
    ///    gets a new `.toolCalls` entry first.
    /// 4. The calls of the last `.toolCalls` entry that got no output are
    ///    removed, because the stop cancelled them.
    ///
    /// - Parameters:
    ///   - settledEntries: The backend transcript after the stop.
    ///   - yield: The yield marker of the attempt.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the attempt.
    ///   - composedPrompt: The composed prompt of the attempt.
    /// - Returns: The rebuilt transcript entries.
    static func rebuilt(
        settledEntries: [Transcript.Entry],
        yield: CompactionYield,
        entryIdsBeforeAttempt: Set<String>,
        composedPrompt: String
    ) -> [Transcript.Entry] {
        let merged = merging(settledEntries, with: [yield.liveEntries, yield.snapshotEntries])
        let prompted = addingAttemptPrompt(
            to: merged, entryIdsBeforeAttempt: entryIdsBeforeAttempt, text: composedPrompt)
        let paired = appendingOutputs(of: yield.results, to: prompted)
        return removingUnansweredCalls(from: paired, entryIdsBeforeAttempt: entryIdsBeforeAttempt)
    }

    /// `base`, then each entry of `sources` whose id `base` and the earlier
    /// sources do not hold.
    ///
    /// - Parameters:
    ///   - base: The entries that come first.
    ///   - sources: The other sources, in order of preference.
    /// - Returns: The merged entries.
    static func merging(_ base: [Transcript.Entry], with sources: [[Transcript.Entry]]) -> [Transcript.Entry] {
        var seen = Set(base.map(\.id))
        var merged = base
        for entry in sources.joined() where seen.insert(entry.id).inserted {
            merged.append(entry)
        }
        return merged
    }

    /// `entries` with a `.prompt` entry in front of the attempt's entries,
    /// when the attempt has none.
    ///
    /// - Parameters:
    ///   - entries: The merged entries.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the attempt.
    ///   - text: The composed prompt of the attempt.
    /// - Returns: The entries with the attempt's prompt.
    static func addingAttemptPrompt(
        to entries: [Transcript.Entry], entryIdsBeforeAttempt: Set<String>, text: String
    ) -> [Transcript.Entry] {
        let attemptEntries = entries.filter { !entryIdsBeforeAttempt.contains($0.id) }
        guard !attemptEntries.contains(where: { isPrompt(entry: $0) }) else { return entries }
        let firstAttemptIndex = entries.firstIndex { !entryIdsBeforeAttempt.contains($0.id) } ?? entries.endIndex
        var prompted = entries
        prompted.insert(
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])),
            at: firstAttemptIndex)
        return prompted
    }

    /// Whether `entry` is a `.prompt` entry.
    private static func isPrompt(entry: Transcript.Entry) -> Bool {
        guard case .prompt = entry else { return false }
        return true
    }

    /// `entries`, then one `.toolOutput` entry for each of `results`. A
    /// result whose call no `.toolCalls` entry holds gets a new call, in one
    /// new `.toolCalls` entry in front of the outputs.
    ///
    /// - Parameters:
    ///   - results: The tool results, in order.
    ///   - entries: The entries so far.
    /// - Returns: The entries with the outputs.
    private static func appendingOutputs(
        of results: [ToolResultAppend], to entries: [Transcript.Entry]
    ) -> [Transcript.Entry] {
        var open = openCalls(in: entries)
        var newCalls: [Transcript.ToolCall] = []
        var outputs: [Transcript.Entry] = []
        for result in results {
            let callId: String
            if let index = open.firstIndex(where: { $0.toolName == result.toolName }) {
                callId = open.remove(at: index).id
            } else {
                let call = Transcript.ToolCall(
                    id: ULID.generate().description, toolName: result.toolName,
                    arguments: result.arguments ?? GeneratedContent(properties: [:]))
                newCalls.append(call)
                callId = call.id
            }
            outputs.append(
                .toolOutput(Transcript.ToolOutput(id: callId, toolName: result.toolName, segments: [result.segment])))
        }
        let callsEntry: [Transcript.Entry] = newCalls.isEmpty ? [] : [.toolCalls(Transcript.ToolCalls(newCalls))]
        return entries + callsEntry + outputs
    }

    /// The calls of `entries` that no `.toolOutput` entry answers, in
    /// transcript order.
    private static func openCalls(in entries: [Transcript.Entry]) -> [Transcript.ToolCall] {
        let answered = answeredCallIds(in: entries)
        return entries.flatMap { entry -> [Transcript.ToolCall] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.filter { !answered.contains($0.id) }
        }
    }

    /// The ids of the calls that a `.toolOutput` entry of `entries` answers.
    private static func answeredCallIds(in entries: [Transcript.Entry]) -> Set<String> {
        Set(
            entries.compactMap { entry in
                guard case .toolOutput(let output) = entry else { return nil }
                return output.id
            })
    }

    /// `entries` with the unanswered calls of the attempt's last
    /// `.toolCalls` entry removed, and that entry removed when no call is
    /// left.
    ///
    /// - Parameters:
    ///   - entries: The entries with the outputs.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the attempt.
    /// - Returns: The entries with only answered calls in the last round.
    private static func removingUnansweredCalls(
        from entries: [Transcript.Entry], entryIdsBeforeAttempt: Set<String>
    ) -> [Transcript.Entry] {
        guard
            let index = entries.lastIndex(where: { entry in
                guard case .toolCalls = entry else { return false }
                return !entryIdsBeforeAttempt.contains(entry.id)
            }),
            case .toolCalls(let calls) = entries[index]
        else { return entries }
        let answered = answeredCallIds(in: entries)
        let kept = calls.filter { answered.contains($0.id) }
        var cleaned = entries
        if kept.isEmpty {
            cleaned.remove(at: index)
        } else {
            cleaned[index] = .toolCalls(Transcript.ToolCalls(id: calls.id, kept))
        }
        return cleaned
    }
}
