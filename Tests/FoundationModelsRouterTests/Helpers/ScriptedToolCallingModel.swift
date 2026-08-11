import FoundationModels
import Synchronization

@testable import FoundationModelsRouter

/// A deterministic `LanguageModel` that plays out a ``ScriptedTurnScript`` and
/// then answers with what the tool outputs told it.
///
/// It carries no generation state of its own: every executor call re-reads the
/// full transcript it is handed (the `LanguageModel` boundary passes the whole
/// accumulated history on every call — see `LanguageModelBoundaryProbeTests`)
/// and branches on how many tool-calling rounds are already in it:
///
/// - fewer rounds than the script has: emit that round's tool calls;
/// - every round spent: emit the final text answer, built from the tool output
///   text read back out of the transcript.
///
/// The final branch is the whole point of the fixture. The answer is composed
/// from what the transcript actually carries, never from a canned string, so a
/// turn whose tool outputs never reach generation cannot produce it.
struct ScriptedToolCallingModel: LanguageModel {
    /// The turn shape this model plays out.
    let script: ScriptedTurnScript

    /// The log this model's generation writes its observations into, and which
    /// the driving test reads back once the turn returned.
    let log: ScriptedTurnLog

    /// Declares tool calling, and nothing else. Without it the SDK refuses a
    /// tool-mounted session outright ("The selected model does not support tool
    /// calling"), so this is the one capability a scripted tool turn needs.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key. The scripted behaviour is fully
    /// determined by the script, and the log identifies this one run, so a
    /// configuration carrying both keys exactly one executor per run.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(script: script, log: log)
    }

    /// The executor that emits this model's scripted tool calls and final
    /// answer over the SDK's own generation channel.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by: the script it
        /// plays out, and the log it writes into.
        struct Configuration: Sendable, Hashable {
            /// The turn shape to play out.
            let script: ScriptedTurnScript

            /// The log to write observations into.
            let log: ScriptedTurnLog
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = ScriptedToolCallingModel

        /// The token count every emitted fragment reports. The scripted model
        /// meters nothing, and no assertion reads token counts off it.
        private static let emittedTokenCount = 1

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration the SDK constructed this executor
        /// with.
        ///
        /// - Parameter configuration: The script and log this executor runs
        ///   against.
        /// - Throws: Never — `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// The text content of every `.toolOutput` entry in `transcript`, in
        /// transcript order.
        ///
        /// - Parameter transcript: The transcript this call was handed.
        /// - Returns: One joined string per tool output entry, in order.
        private static func toolOutputTexts(in transcript: Transcript) -> [String] {
            transcript.compactMap { entry -> String? in
                guard case .toolOutput(let output) = entry else { return nil }
                let texts = output.segments.compactMap { segment -> String? in
                    guard case .text(let text) = segment else { return nil }
                    return text.content
                }
                return texts.isEmpty ? nil : texts.joined()
            }
        }

        /// Every tool call `transcript` carries, in transcript order — the
        /// model's own record of what it asked for.
        ///
        /// - Parameter transcript: The transcript this call was handed.
        /// - Returns: One record per call, across every `.toolCalls` entry.
        private static func requestedCalls(in transcript: Transcript) -> [ScriptedCallRecord] {
            transcript.flatMap { entry -> [ScriptedCallRecord] in
                guard case .toolCalls(let calls) = entry else { return [] }
                return calls.map {
                    ScriptedCallRecord(
                        toolName: $0.toolName, argumentValue: argumentValue(of: $0.arguments))
                }
            }
        }

        /// The `value` argument a call carries, decoded the way the mounted
        /// tools' own ``AmbientToolArguments`` decodes it, so an assertion reads
        /// the argument rather than one SDK's JSON spelling of it.
        ///
        /// - Parameter arguments: The call's arguments as the transcript
        ///   carries them.
        /// - Returns: The decoded `value`, or the arguments' raw JSON when they
        ///   carry no decodable `value`.
        private static func argumentValue(of arguments: GeneratedContent) -> String {
            (try? arguments.value(String.self, forProperty: "value")) ?? arguments.jsonString
        }

        /// How many tool-calling rounds `transcript` already holds — one per
        /// `.toolCalls` entry, however many calls that entry carries.
        ///
        /// - Parameter transcript: The transcript this call was handed.
        /// - Returns: The count of rounds already played out.
        private static func roundCount(in transcript: Transcript) -> Int {
            transcript.reduce(into: 0) { count, entry in
                if case .toolCalls = entry { count += 1 }
            }
        }

        /// The transcript entry id every call of round `round` is emitted
        /// under, so a round asking for two calls lands as one entry holding
        /// both rather than as two entries.
        ///
        /// - Parameter round: The round's zero-based position in the script.
        /// - Returns: The entry id to emit that round's calls under.
        private static func entryID(forRound round: Int) -> String {
            "scripted-round-\(round)"
        }

        /// Emits one scripted round of tool calls, or the final answer once
        /// every round has been played out.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript this
        ///     call branches on.
        ///   - model: The model this executor runs for. Unread: the script and
        ///     log both arrive through the configuration.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: Never — `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ScriptedToolCallingModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.recordModelTurn()
            let transcript = request.transcript
            let toolOutputs = Self.toolOutputTexts(in: transcript)
            let round = Self.roundCount(in: transcript)
            guard round < configuration.script.rounds.count else {
                configuration.log.recordAnswer(
                    requestedCalls: Self.requestedCalls(in: transcript),
                    deliveredToolOutputs: toolOutputs)
                await channel.send(
                    .response(
                        action: .appendText(
                            ScriptedToolFixture.answer(fromToolOutputs: toolOutputs),
                            tokenCount: Self.emittedTokenCount)))
                return
            }
            if let narration = configuration.script.narration {
                await channel.send(
                    .response(action: .appendText(narration, tokenCount: Self.emittedTokenCount)))
            }
            for call in configuration.script.rounds[round] {
                await channel.send(
                    .toolCalls(
                        entryID: Self.entryID(forRound: round),
                        action: .toolCall(
                            id: call.id,
                            name: call.toolName,
                            action: .appendArguments(
                                Self.argumentsJSON(for: call, toolOutputs: toolOutputs),
                                tokenCount: Self.emittedTokenCount)
                        )
                    )
                )
            }
        }

        /// Renders one scripted call's arguments as the JSON the SDK decodes
        /// into ``AmbientToolArguments``.
        ///
        /// - Parameters:
        ///   - call: The call whose arguments to render.
        ///   - toolOutputs: The tool output texts the transcript carries so
        ///     far, which an output-derived argument reads from.
        /// - Returns: The call's arguments as a JSON object.
        private static func argumentsJSON(
            for call: ScriptedToolCall, toolOutputs: [String]
        ) -> String {
            let value = call.argument.resolved(againstToolOutputs: toolOutputs)
            return #"{"value":"\#(value)"}"#
        }
    }
}

// MARK: - The container the scripted model is mounted behind

/// A ``LoadedLLMContainer`` that vends the production
/// ``MLXFoundationModelsSessionBackend`` over a ``ScriptedToolCallingModel``,
/// so a `RoutedSession` vended off a stub-resolved profile drives the real
/// backend — the real `pumpStream`, the real `respond` — with no GPU in the
/// loop.
///
/// The backend used to be a hand-written stand-in in this file, and that is
/// exactly why defects D1 and D2 survived two closed cards (task ^w8dzvee):
/// the stand-in carried its own copy of the snapshot-to-fragment conversion, so
/// every scripted suite tested the copy and nothing tested the original.
/// `MLXFoundationModelsSessionBackend.init` now takes the
/// `FoundationModels.LanguageModel` existential rather than a concrete
/// `MLXLanguageModel`, which is what lets the production type stand here.
///
/// It overrides both `tools:` factory overloads rather than taking the
/// protocol's tool-dropping defaults: mounting the session's tools is exactly
/// what this fixture exists to exercise.
struct ScriptedToolCallingContainer: LoadedLLMContainer {
    /// The scripted model every backend this container vends runs over.
    let model: ScriptedToolCallingModel

    /// Every backend this container has vended, in vending order.
    ///
    /// A `RoutedSession` exposes no transcript accessor of its own, and a
    /// comparison of whole transcripts needs one. Reading it off the vended
    /// backend is the honest route: it is the SDK's own live transcript, the
    /// same object the turn chokepoint diffs. Only safe to read once the turn
    /// has returned, which is the turn-lock discipline
    /// ``LanguageModelSessionBackend/transcriptEntries()`` documents.
    let vendedBackends = VendedBackendLog()

    /// The raw model handle, so a test can build its own session over the very
    /// model the container mounts.
    var languageModel: any FoundationModels.LanguageModel { model }

    /// Vends a backend over a fresh session carrying `instructions`, with no
    /// tools mounted.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A backend a vended `RoutedSession` drives for its lifetime.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    /// Vends a backend over a fresh session carrying `instructions`, with
    /// `tools` mounted so the model can call them.
    ///
    /// The factory a scripted suite's own session is built through, and the
    /// reason this container implements the `tools:` overloads at all: the
    /// protocol's default drops the tools, which would leave the turn nothing
    /// to call and the test asserting on a fixture defect rather than on
    /// Router.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools to mount on the session.
    /// - Returns: A backend a vended `RoutedSession` drives for its lifetime.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        vendedBackends.record(
            MLXFoundationModelsSessionBackend(
                session: LanguageModelSession(
                    model: model, tools: tools, instructions: instructions),
                model: model,
                instructions: instructions,
                tools: tools
            ))
    }

    /// Vends a backend over a fresh session seeded from `transcript`, with no
    /// tools mounted.
    ///
    /// - Parameter transcript: The transcript to seed the session from.
    /// - Returns: A backend whose history begins with `transcript`'s entries.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    /// Vends a backend over a fresh session seeded from `transcript`, with
    /// `tools` mounted — the restore-shaped counterpart of
    /// ``makeSession(instructions:tools:)``, implemented for the same reason.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the session from.
    ///   - tools: The tools to mount on the session.
    /// - Returns: A backend whose history begins with `transcript`'s entries,
    ///   with `tools` mounted.
    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        vendedBackends.record(
            MLXFoundationModelsSessionBackend(
                session: LanguageModelSession(model: model, tools: tools, transcript: transcript),
                model: model,
                instructions: TranscriptDiffer.leadingInstructionsText(of: transcript),
                tools: tools
            ))
    }
}

/// The backends a ``ScriptedToolCallingContainer`` vended, so a test can read
/// the SDK's own transcript back off the very session a turn ran through.
///
/// A class behind a lock because the container is a `struct` a `Sendable`
/// profile holds, while the recording happens on whatever task built the
/// session and the reading happens on the task that drove the turn.
final class VendedBackendLog: Sendable {
    /// The backends vended so far, in vending order.
    private let vended: Mutex<[any LanguageModelSessionBackend]> = Mutex([])

    /// The most recently vended backend, or `nil` before any was vended.
    var latest: (any LanguageModelSessionBackend)? { vended.withLock { $0.last } }

    /// Records a vended backend and hands it straight back, so a factory can
    /// record and return in one expression.
    ///
    /// - Parameter backend: The backend just vended.
    /// - Returns: `backend`, unchanged.
    @discardableResult
    func record(_ backend: any LanguageModelSessionBackend) -> any LanguageModelSessionBackend {
        vended.withLock { $0.append(backend) }
        return backend
    }
}
