import FoundationModelsRouterTestSupport
import Synchronization

/// The shared vocabulary of the scripted-tool-turn fixtures: the distinctive
/// marker a mounted tool stamps into its output, the prefix the scripted model
/// opens its final answer with, and the prompt every scripted turn is driven
/// with.
///
/// One source of truth so the tool that *produces* a marker and the assertion
/// that *looks for* it can never drift apart, and so a test asserts on content
/// the model could only have learned from a tool output.
enum ScriptedToolFixture {
    /// The distinctive token every marker output opens with — long enough that
    /// no model prior could produce it and no other fixture collides with it.
    static let markerPrefix = ToolTurnScenario.markerPrefix

    /// The text the scripted model opens its final answer with, before the
    /// marker outputs it read back out of the transcript.
    static let answerPrefix = "answer: "

    /// The text the scripted model answers with in place of tool outputs when
    /// its turn produced none.
    ///
    /// A turn that calls nothing still has to answer with an exact string a
    /// test can compare against; without this the answer would end in the
    /// trailing space of ``answerPrefix``, which nothing in the SDK promises to
    /// preserve.
    static let noToolOutputsMarker = "NO-TOOL-OUTPUTS"

    /// What separates one tool output from the next in the answer the scripted
    /// model composes. Named so an asserting test can spell the answer it
    /// expects without repeating the separator literal per assertion.
    static let answerSeparator = " "

    /// The prompt every scripted turn is driven with. The scripted model
    /// branches on its transcript alone and never reads the prompt, so one
    /// wording serves every turn shape.
    static let prompt = "call whatever tools you need, then tell me what you were told"

    /// The step name a one-call scripted turn names — one source of truth, so
    /// the script's call argument and the assertion on the tool's recorded
    /// steps cannot drift apart.
    static let firstStepName = "ONE"

    /// The tool output text a call naming `step` produces.
    ///
    /// - Parameter step: The `value` argument the call named.
    /// - Returns: ``markerPrefix`` followed by `step`.
    static func marker(for step: String) -> String {
        markerPrefix + step
    }

    /// The final answer the scripted model composes from what its transcript
    /// carries.
    ///
    /// Composed from the outputs rather than from a canned string, so a turn
    /// whose tool outputs never reached generation cannot produce it.
    ///
    /// - Parameter toolOutputs: The tool output texts the answering generation
    ///   read out of its transcript, in transcript order.
    /// - Returns: ``answerPrefix`` followed by the outputs, or by
    ///   ``noToolOutputsMarker`` when there were none.
    static func answer(fromToolOutputs toolOutputs: [String]) -> String {
        let body =
            toolOutputs.isEmpty
            ? noToolOutputsMarker : toolOutputs.joined(separator: answerSeparator)
        return answerPrefix + body
    }
}

// MARK: - The script

/// How one scripted tool call's `value` argument is produced.
enum ScriptedCallArgument: Sendable, Hashable {
    /// A fixed argument, independent of anything the turn has produced so far.
    case literal(String)

    /// The text of the tool output at `index` in the transcript so far.
    ///
    /// The shape that makes one call's argument depend on an earlier call's
    /// output: a loop that delivers no output, or only the first one, cannot
    /// produce the argument this resolves to.
    ///
    /// - Parameter index: The position of the tool output to read, counting
    ///   every tool output in the transcript in order from zero.
    case priorToolOutput(index: Int)

    /// The `value` a ``priorToolOutput(index:)`` argument resolves to when the
    /// output it names is not in the transcript — a visible, assertable stand-in
    /// rather than a silent empty string.
    static let unresolvedArgument = "UNRESOLVED-PRIOR-OUTPUT"

    /// Resolves this argument against the tool outputs the transcript carries.
    ///
    /// - Parameter toolOutputs: Every tool output text in the transcript so
    ///   far, in transcript order.
    /// - Returns: The `value` to call with, or ``unresolvedArgument`` when this
    ///   argument names an output the transcript does not carry.
    func resolved(againstToolOutputs toolOutputs: [String]) -> String {
        switch self {
        case .literal(let value):
            return value
        case .priorToolOutput(let index):
            guard toolOutputs.indices.contains(index) else { return Self.unresolvedArgument }
            return toolOutputs[index]
        }
    }
}

/// One tool call a scripted round asks for.
struct ScriptedToolCall: Sendable, Hashable {
    /// The call's own id, which the SDK carries as `Transcript.ToolCall.id`.
    /// Distinct per call, so two calls in one round stay distinguishable.
    let id: String

    /// The model-facing name of the tool to call. Matches the `name` of a tool
    /// the session mounts, or the call reaches nothing.
    let toolName: String

    /// How the call's `value` argument is produced.
    let argument: ScriptedCallArgument
}

/// The turn shape a ``ScriptedToolCallingModel`` plays out: one entry per model
/// turn that requests tool calls, in order, and then the answering turn.
///
/// A round holding two calls is emitted as a single `.toolCalls` transcript
/// entry carrying both — the shape a model produces when it asks for two
/// independent calls at once. Once every round is spent the model answers with
/// whatever tool outputs its transcript carries.
struct ScriptedTurnScript: Sendable, Hashable {
    /// The tool calls to request, one entry per tool-calling model turn. Empty
    /// for a turn that answers without calling anything.
    let rounds: [[ScriptedToolCall]]

    /// Text the model emits into its `.response` entry before each round's tool
    /// calls, or `nil` (the default) for a round that emits calls and no prose.
    ///
    /// This is what makes a scripted turn's snapshot sequence non-monotonic:
    /// the SDK closes the narrated `.response` entry at the tool boundary and
    /// resumes into a new one, so the answer's first snapshot does not extend
    /// the narration — the shape defect D2 lives in (task ^w8dzvee).
    ///
    /// `nil` reproduces `MLXLanguageModel`'s own tool-calling executor, which
    /// buffers its whole output and emits *either* a tool call *or* text, never
    /// prose ahead of a call. Both shapes are real: the real model reaches the
    /// narrated one through its malformed-tool-call text fallback.
    var narration: String? = nil
}

// MARK: - What a scripted turn was observed to do

/// One tool call as the transcript carries it — the model's own view of what it
/// asked for, rather than the fixture's view of what it meant to ask for.
///
/// This type writes neither `==` nor `hash(into:)`. The compiler makes both
/// from the `Hashable` conformance. A test compares whole records, and it does
/// not read a single field. Thus those synthesized bodies are the only readers
/// of the two properties below. Periphery cannot see a body that the compiler
/// makes, thus each property has a `// periphery:ignore` marker. Do not delete
/// a property: the code then does not compile. If you delete both, then any two
/// records become equal.
struct ScriptedCallRecord: Sendable, Hashable {
    /// The called tool's model-facing name.
    // Only the synthesized `Hashable` `==` and `hash(into:)` read this property.
    // periphery:ignore
    let toolName: String

    /// The call's `value` argument, decoded out of the arguments the
    /// transcript carries — or the arguments' raw `GeneratedContent.jsonString`
    /// when they carry no decodable `value`, so a malformed call stays visible
    /// instead of reading as an absent argument.
    // Only the synthesized `Hashable` `==` and `hash(into:)` read this property.
    // periphery:ignore
    let argumentValue: String
}

/// What one scripted turn was observed to do, written by the scripted model as
/// it generates and read by the test once the turn returned.
///
/// A class hashed by identity, because it rides in the scripted executor's
/// `Configuration`: the SDK builds and caches one executor per configuration
/// value, so a fresh log per run both keys a fresh executor and hands the test
/// the very object that executor writes into. No global registry, and no two
/// runs sharing one counter.
final class ScriptedTurnLog: Sendable, Hashable {
    /// The observations a scripted turn accumulates.
    private struct Observations {
        /// How many times the executor was asked to generate.
        var modelTurnCount = 0

        /// The tool calls the answering turn found in its transcript.
        var requestedCalls: [ScriptedCallRecord] = []

        /// The tool output texts the answering turn read out of its transcript.
        var deliveredToolOutputs: [String] = []
    }

    /// The observations so far, behind a lock: the SDK generates on a task of
    /// its own while the test reads the log back on the task that drove the
    /// turn.
    private let observations: Mutex<Observations> = Mutex(Observations())

    /// How many times the scripted executor was asked to generate — the turn's
    /// count of model turns.
    var modelTurnCount: Int { observations.withLock { $0.modelTurnCount } }

    /// The tool calls the answering generation found in its transcript, in
    /// transcript order.
    var requestedCalls: [ScriptedCallRecord] { observations.withLock { $0.requestedCalls } }

    /// The tool output texts the answering generation read out of its
    /// transcript, in transcript order — the content that proves what reached
    /// the model, as against an event count that only proves something was
    /// announced.
    var deliveredToolOutputs: [String] { observations.withLock { $0.deliveredToolOutputs } }

    /// Records that the executor was asked to generate once more.
    func recordModelTurn() {
        observations.withLock { $0.modelTurnCount += 1 }
    }

    /// Records what the answering generation was handed.
    ///
    /// - Parameters:
    ///   - requestedCalls: The tool calls the transcript carries, in order.
    ///   - deliveredToolOutputs: The tool output texts the transcript carries,
    ///     in order.
    func recordAnswer(requestedCalls: [ScriptedCallRecord], deliveredToolOutputs: [String]) {
        observations.withLock {
            $0.requestedCalls = requestedCalls
            $0.deliveredToolOutputs = deliveredToolOutputs
        }
    }

    /// Compares two logs by identity, so a log keys the one executor that
    /// writes into it.
    ///
    /// - Parameters:
    ///   - lhs: One log.
    ///   - rhs: The other log.
    /// - Returns: `true` when both names are the same object.
    static func == (lhs: ScriptedTurnLog, rhs: ScriptedTurnLog) -> Bool {
        lhs === rhs
    }

    /// Hashes this log by identity, matching ``==(_:_:)``.
    ///
    /// - Parameter hasher: The hasher to feed.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
