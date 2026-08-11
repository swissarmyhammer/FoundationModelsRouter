import FoundationModels
import FoundationModelsRouter

/// One tool-using scenario, expressed once and run four ways: scripted model
/// through `respond(to:)`, scripted model through `streamEvents(to:)`, real
/// model through `respond(to:)`, real model through `streamEvents(to:)`.
///
/// The comparison is the point. Same-model/different-surface disagreement is a
/// Router defect (that is where task ^w8dzvee's D1 and D2 live);
/// scripted-versus-real disagreement is either an unfaithful mock or a live
/// path defect, and both are worth knowing. Comparing whole normalized
/// transcripts rather than a hand-picked list of properties is what catches the
/// defect nobody thought to assert on — which is precisely how D1 and D2 got
/// through two closed cards.
public enum ToolTurnScenario {
    /// The distinctive token a scenario tool stamps into its output.
    ///
    /// Long enough that no model prior can produce it, so an answer carrying it
    /// proves the tool output re-entered generation rather than being guessed.
    public static let markerPrefix = "MARKER-7F3A-"

    /// The step name the scenario's first call names.
    public static let firstStep = "ONE"

    /// The step name the scenario's second call names.
    public static let secondStep = "TWO"

    /// The tool output text a call naming `step` produces.
    ///
    /// - Parameter step: The `value` argument the call named.
    /// - Returns: ``markerPrefix`` followed by `step`.
    public static func marker(for step: String) -> String {
        markerPrefix + step
    }

    /// Every marker the scenario's tools can emit, in call order — the set a
    /// normalized `.response` entry is measured against.
    public static var markers: [String] {
        [marker(for: firstStep), marker(for: secondStep)]
    }
}

// MARK: - Normalization

/// One `Transcript.Entry` reduced to the part of it that is the same on every
/// run, so two transcripts can be compared for equality without a real model's
/// prose or a fresh run's identifiers making every comparison fail.
///
/// **What is normalized, and why.** Three kinds of field are volatile and only
/// three:
///
/// - **Identifiers.** `Transcript.Entry.id`, `Transcript.ToolCall.id` and the
///   segment ids are minted per run — by Apple's SDK for `.instructions`,
///   `.prompt` and `.response`, and by the model's own executor for
///   `.toolCalls` (`MLXLanguageModel` uses `UUID().uuidString`). Router cannot
///   inject them, so they cannot be made deterministic from this side. They are
///   replaced by a **first-occurrence ordinal within the transcript**, never
///   erased: a `.toolOutput` whose id names the second call instead of the
///   first normalizes to a different ordinal, so the id correlation is still
///   checked.
/// - **Free-form model prose.** A real model writes different words each run. A
///   `.response` entry is therefore compared by the set of tool markers its text
///   carries — the part the tool supplied, which is exactly the part a grounded
///   answer must contain — and never by its wording.
/// - **Timing.** No `Transcript.Entry` carries a timestamp, so nothing is
///   dropped for it here; the recorded ``TranscriptEvent`` stream does, and this
///   type deliberately does not read that stream.
///
/// Everything else is compared exactly: the entry kinds and their order, the
/// number of tool calls, each call's tool name and its decoded `value`
/// argument, and each tool output's whole text.
public enum NormalizedTranscriptEntry: Sendable, Equatable, CustomStringConvertible {
    /// An `.instructions` entry, carrying the model-facing names of the tools
    /// it declared, in declaration order.
    case instructions(toolNames: [String])

    /// A `.prompt` entry and its text, which the caller supplies and so is
    /// identical on every path.
    case prompt(text: String)

    /// A `.toolCalls` entry: one `(ordinal, toolName, value)` triple per call,
    /// in request order.
    case toolCalls([NormalizedToolCall])

    /// A `.toolOutput` entry: the ordinal of the call it answers (`nil` when
    /// its id names no call the transcript announced — the shape defect D1 is
    /// about), the tool's name, and the output text.
    case toolOutput(callOrdinal: Int?, toolName: String, text: String)

    /// A `.response` entry, reduced to the tool markers its text carries.
    case response(markers: [String])

    /// A `.reasoning` entry. Its content is model prose and carries nothing a
    /// comparison can hold two paths to.
    case reasoning

    /// A one-line rendering, so a failed comparison prints a legible diff
    /// instead of a wall of structure.
    public var description: String {
        switch self {
        case .instructions(let toolNames):
            return "instructions(tools: \(toolNames))"
        case .prompt(let text):
            return "prompt(\(text))"
        case .toolCalls(let calls):
            return "toolCalls(\(calls.map(\.description)))"
        case .toolOutput(let callOrdinal, let toolName, let text):
            return "toolOutput(call: \(callOrdinal.map(String.init) ?? "UNMATCHED"), \(toolName), \(text))"
        case .response(let markers):
            return "response(markers: \(markers))"
        case .reasoning:
            return "reasoning"
        }
    }
}

/// One tool call inside a normalized `.toolCalls` entry.
public struct NormalizedToolCall: Sendable, Equatable, CustomStringConvertible {
    /// The call's position among every call the transcript announced, counting
    /// from zero — the stand-in for its run-specific id.
    public let ordinal: Int

    /// The model-facing name of the tool called.
    public let toolName: String

    /// The call's `value` argument, decoded the way the scenario's tools decode
    /// it, or the arguments' raw JSON when they carry no decodable `value`.
    public let argumentValue: String

    /// Creates a normalized call.
    ///
    /// - Parameters:
    ///   - ordinal: The call's zero-based position among the transcript's calls.
    ///   - toolName: The model-facing name of the tool called.
    ///   - argumentValue: The call's decoded `value` argument.
    public init(ordinal: Int, toolName: String, argumentValue: String) {
        self.ordinal = ordinal
        self.toolName = toolName
        self.argumentValue = argumentValue
    }

    /// A one-line rendering for a failed comparison's diff.
    public var description: String {
        "#\(ordinal) \(toolName)(\(argumentValue))"
    }
}

extension Array where Element == NormalizedTranscriptEntry {
    /// Normalizes a whole `Transcript` for comparison.
    ///
    /// See ``NormalizedTranscriptEntry`` for what is normalized and what is
    /// compared exactly.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to normalize, in order.
    ///   - markers: The tool markers a `.response` entry is measured against,
    ///     in the order they are reported.
    /// - Returns: One normalized entry per transcript entry, in order.
    public static func normalizing(
        _ transcript: some Sequence<Transcript.Entry>,
        markers: [String]
    ) -> [NormalizedTranscriptEntry] {
        var ordinalByCallId: [String: Int] = [:]
        return transcript.map { entry in
            normalize(entry, markers: markers, ordinalByCallId: &ordinalByCallId)
        }
    }

    /// Normalizes one entry, assigning and resolving call ordinals against
    /// `ordinalByCallId` as it goes.
    ///
    /// - Parameters:
    ///   - entry: The entry to normalize.
    ///   - markers: The tool markers a `.response` entry is measured against.
    ///   - ordinalByCallId: The ordinal assigned to each call id seen so far,
    ///     extended here by a `.toolCalls` entry and read by a `.toolOutput`
    ///     entry.
    /// - Returns: The normalized entry.
    private static func normalize(
        _ entry: Transcript.Entry,
        markers: [String],
        ordinalByCallId: inout [String: Int]
    ) -> NormalizedTranscriptEntry {
        switch entry {
        case .instructions(let instructions):
            return .instructions(toolNames: instructions.toolDefinitions.map(\.name))
        case .prompt(let prompt):
            return .prompt(text: text(of: prompt.segments))
        case .toolCalls(let calls):
            return .toolCalls(
                calls.map { call in
                    let ordinal = ordinalByCallId.count
                    ordinalByCallId[call.id] = ordinal
                    return NormalizedToolCall(
                        ordinal: ordinal,
                        toolName: call.toolName,
                        argumentValue: argumentValue(of: call.arguments))
                })
        case .toolOutput(let output):
            return .toolOutput(
                callOrdinal: ordinalByCallId[output.id],
                toolName: output.toolName,
                text: text(of: output.segments))
        case .response(let response):
            let body = text(of: response.segments)
            return .response(markers: markers.filter { body.contains($0) })
        case .reasoning:
            return .reasoning
        @unknown default:
            return .reasoning
        }
    }

    /// The concatenated text of every `.text` segment, in order.
    ///
    /// - Parameter segments: The entry's segments.
    /// - Returns: The joined text content.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        .joined()
    }

    /// The `value` argument a call carries, decoded the way the scenario's
    /// tools decode it, so a comparison reads the argument rather than one
    /// SDK's JSON spelling of it.
    ///
    /// - Parameter arguments: The call's arguments as the transcript carries
    ///   them.
    /// - Returns: The decoded `value`, or the raw JSON when there is none.
    private static func argumentValue(of arguments: GeneratedContent) -> String {
        (try? arguments.value(String.self, forProperty: "value")) ?? arguments.jsonString
    }
}

/// The `Transcript.Entry` kind of one normalized entry, so two paths can be
/// compared on shape alone where their content legitimately differs.
public enum NormalizedTranscriptEntryKind: String, Equatable {
    /// An `.instructions` entry.
    case instructions
    /// A `.prompt` entry.
    case prompt
    /// A `.toolCalls` entry.
    case toolCalls
    /// A `.toolOutput` entry.
    case toolOutput
    /// A `.response` entry.
    case response
    /// A `.reasoning` entry.
    case reasoning
}

extension NormalizedTranscriptEntry {
    /// This entry's kind, discarding everything it carries.
    ///
    /// The coarsest comparison the four-way run makes: a scripted path and a
    /// real path must agree on the sequence of entry kinds even where the
    /// model's own wording and chosen arguments legitimately differ.
    public var kind: NormalizedTranscriptEntryKind {
        switch self {
        case .instructions: return .instructions
        case .prompt: return .prompt
        case .toolCalls: return .toolCalls
        case .toolOutput: return .toolOutput
        case .response: return .response
        case .reasoning: return .reasoning
        }
    }
}

// MARK: - What one run of the scenario was observed to do

/// Everything one run of the scenario produced, gathered identically whichever
/// surface drove it and whichever model backed it.
public struct ToolTurnRunOutcome: Sendable {
    /// The turn's answer text: `respond(to:)`'s return value, or — on the
    /// streaming surface — the ``SessionEvent/textDelta(_:)`` fragments
    /// accumulated by a consumer that **honours ``SessionEvent/textReset``**,
    /// clearing what it holds when the model abandons one response for another.
    ///
    /// That is the invariant the two surfaces are held to: applying the
    /// documented rule reconstructs, character for character, what
    /// `respond(to:)` returns for the same turn.
    public let answer: String

    /// The same fragments accumulated by a consumer that **ignores**
    /// ``SessionEvent/textReset`` and simply appends everything.
    ///
    /// Empty on the `respond(to:)` surface, which yields no fragments at all.
    /// Kept because delivering superseded text is a deliberate guarantee, not
    /// an accident: a delivered chunk cannot be retracted and a live consumer
    /// is entitled to everything the model said, so a test asserts that the
    /// superseded text is still *there* as well as no longer part of the
    /// answer.
    public let rawAnswer: String

    /// Every `.toolCall` id the turn announced, in announcement order.
    public let calledIds: [String]

    /// Every id a `.toolStatus` of ``ToolCallStatus/completed`` carried, in
    /// arrival order.
    public let completedIds: [String]

    /// Every id a `.toolStatus` of ``ToolCallStatus/failed`` carried.
    public let failedIds: [String]

    /// The session's whole transcript after the turn, normalized.
    public let transcript: [NormalizedTranscriptEntry]

    /// Creates an outcome.
    ///
    /// - Parameters:
    ///   - answer: The turn's answer text, reset rule applied.
    ///   - rawAnswer: Every fragment appended with the reset rule ignored.
    ///   - calledIds: Every announced `.toolCall` id, in order.
    ///   - completedIds: Every completed `.toolStatus` id, in order.
    ///   - failedIds: Every failed `.toolStatus` id.
    ///   - transcript: The session's normalized transcript after the turn.
    public init(
        answer: String,
        rawAnswer: String = "",
        calledIds: [String],
        completedIds: [String],
        failedIds: [String],
        transcript: [NormalizedTranscriptEntry]
    ) {
        self.answer = answer
        self.rawAnswer = rawAnswer
        self.calledIds = calledIds
        self.completedIds = completedIds
        self.failedIds = failedIds
        self.transcript = transcript
    }

    /// A multi-line rendering of the normalized transcript, for the
    /// scripted-versus-real comparison table.
    public var transcriptDescription: String {
        transcript.map { "  \($0)" }.joined(separator: "\n")
    }
}
