import FoundationModels

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

// MARK: - The backend and container the scripted model is mounted behind

/// A ``LanguageModelSessionBackend`` that drives a real, tool-mounted
/// `LanguageModelSession` over a ``ScriptedToolCallingModel``.
///
/// The live `MLXFoundationModelsSessionBackend` cannot stand in here: its
/// initializer takes a concrete `MLXLanguageModel`, which needs real weights
/// and a GPU. This backend is the same shape over a scripted model, so the
/// SDK's own tool loop — not a simulation of it — is what a `RoutedSession`
/// turn runs through.
///
/// `@unchecked Sendable` on the same terms as the live backend it stands in
/// for: the owning session drives one backend method at a time under its turn
/// lock, so `liveSession` — a non-`Sendable` class — is never touched
/// concurrently.
final class ScriptedToolCallingBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// A generation shape this fixture deliberately does not stand in for.
    enum FixtureError: Error, Equatable {
        /// Raised by the guided entry point: the scripted model emits plain
        /// text and tool calls only, so a grammar-constrained turn has nothing
        /// to constrain here. No scripted suite drives a guided turn.
        case guidedGenerationUnsupported
    }

    /// The scripted model every session this backend builds runs over.
    private let model: ScriptedToolCallingModel

    /// The tools mounted on ``liveSession``, retained so a fork can mount the
    /// same ones.
    private let tools: [any Tool]

    /// The real, tool-mounted session this backend drives.
    private let liveSession: LanguageModelSession

    /// Creates a backend over a fresh session carrying `instructions`.
    ///
    /// - Parameters:
    ///   - model: The scripted model to run the session over.
    ///   - tools: The tools to mount on the session.
    ///   - instructions: The session's system instructions, or `nil`.
    init(model: ScriptedToolCallingModel, tools: [any Tool], instructions: String?) {
        self.model = model
        self.tools = tools
        self.liveSession = LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Creates a backend over a fresh session seeded from `transcript`.
    ///
    /// - Parameters:
    ///   - model: The scripted model to run the session over.
    ///   - tools: The tools to mount on the session.
    ///   - transcript: The transcript to seed the session from.
    init(model: ScriptedToolCallingModel, tools: [any Tool], transcript: Transcript) {
        self.model = model
        self.tools = tools
        self.liveSession = LanguageModelSession(model: model, tools: tools, transcript: transcript)
    }

    /// Runs one whole-response turn on ``liveSession``.
    ///
    /// The SDK drains its own tool loop inside this one call, so the text that
    /// comes back is already the post-tool answer — the backend surface a
    /// ``RoutedSession/respond(to:)`` turn ends up driving.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The response token ceiling, or `nil` for the SDK's own.
    /// - Returns: The turn's final text, after every scripted tool call ran.
    /// - Throws: Whatever the underlying session throws.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        return try await liveSession.respond(to: prompt, options: options).content
    }

    /// Streams one turn on ``liveSession`` as response fragments — the backend
    /// surface a ``RoutedSession/streamEvents(to:)`` turn ends up driving.
    ///
    /// The SDK yields cumulative snapshots, not fragments, so the conversion
    /// this protocol requires happens in ``pumpStream(prompt:options:into:)``;
    /// a consumer that stops reading cancels the pumping task.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The response token ceiling, or `nil` for the SDK's own.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task { await self.pumpStream(prompt: prompt, options: options, into: continuation) }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Drives ``liveSession``'s cumulative-snapshot stream to completion,
    /// yielding each snapshot's new suffix.
    ///
    /// `LanguageModelSessionBackend/streamResponse(to:maxTokens:)`'s contract
    /// is a stream of *fragments* the caller accumulates, while the SDK yields
    /// cumulative snapshots, so a conformer has to convert — this is the
    /// conversion, not a copy of production logic under test.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to stream a response to.
    ///   - options: The generation options to run under.
    ///   - continuation: The continuation each fragment is yielded to.
    private func pumpStream(
        prompt: String,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var previous = ""
        do {
            for try await snapshot in liveSession.streamResponse(to: prompt, options: options) {
                let current = snapshot.content
                let delta = current.hasPrefix(previous) ? String(current.dropFirst(previous.count)) : current
                if !delta.isEmpty {
                    continuation.yield(delta)
                }
                previous = current
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Refuses a grammar-constrained turn.
    ///
    /// The scripted model emits plain text and tool calls only, so a grammar
    /// has nothing to constrain here and no scripted suite drives a guided
    /// turn. Failing loudly is what keeps a future guided test from quietly
    /// reading unconstrained text as if it had been constrained.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - grammar: The grammar the output would be constrained to.
    ///   - maxTokens: The response token ceiling, or `nil` for the SDK's own.
    /// - Returns: Nothing — this entry point never returns a value.
    /// - Throws: ``FixtureError/guidedGenerationUnsupported``, always.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        throw FixtureError.guidedGenerationUnsupported
    }

    /// Forks this backend, keeping the tools this one already mounts.
    ///
    /// Delegates to ``makeFork(tools:)`` with the stored tool list, the way the
    /// live `MLXFoundationModelsSessionBackend` delegates to its own `tools:`
    /// overload: a fork of a tool-mounted session has to stay tool-mounted, or
    /// the child's first turn silently loses tool calling.
    ///
    /// - Returns: A new backend that begins from this session's history and
    ///   then diverges independently, with the same tools mounted.
    func makeFork() -> any LanguageModelSessionBackend {
        makeFork(tools: tools)
    }

    /// Forks this backend over the same scripted model, seeding the child from
    /// this session's transcript as of now and mounting `tools` on it.
    ///
    /// Implemented rather than left to the protocol's tool-dropping default:
    /// that default exists for stubs whose model cannot call tools at all, and
    /// this fixture's model can.
    ///
    /// - Parameter tools: The tools to mount on the forked session, in place of
    ///   this backend's own.
    /// - Returns: A new, independent backend seeded from this session's
    ///   history.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        ScriptedToolCallingBackend(model: model, tools: tools, transcript: liveSession.transcript)
    }

    /// Reseeds a new backend over the same scripted model from `transcript`,
    /// discarding this backend's own accumulated history.
    ///
    /// The seam ``RoutedSessionActor/compact(prompt:budget:)`` swaps a session's
    /// inner backend through. No scripted suite compacts, but the conformance
    /// is real rather than the protocol's fork-shaped default, so a later test
    /// that does compact gets the transcript it asked for instead of this
    /// backend's.
    ///
    /// - Parameter transcript: The transcript to seed the new backend from.
    /// - Returns: A new, independent backend whose history begins with
    ///   `transcript`'s entries.
    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        ScriptedToolCallingBackend(model: model, tools: tools, transcript: transcript)
    }

    /// Reports ``liveSession``'s transcript so far, in order.
    ///
    /// Read straight off the live session, so it holds only under the owning
    /// session's turn lock — the same discipline the live backend documents.
    /// The scripted model reads its own copy out of the request the SDK hands
    /// it, so nothing in the scripted suites depends on this accessor; it is
    /// here because the protocol requires it.
    ///
    /// - Returns: Every entry ``liveSession`` has accumulated so far, in order.
    func transcriptEntries() -> [Transcript.Entry] {
        Array(liveSession.transcript)
    }

    /// Reports ``liveSession``'s cumulative token usage.
    ///
    /// Never `nil`: the SDK meters the fragments the scripted model emits, so a
    /// real pair of counts exists — fixture arithmetic rather than real
    /// metering, and no scripted assertion reads it.
    ///
    /// - Returns: The session's cumulative `(input, output)` token counts.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        let usage = liveSession.usage
        return (usage.input.totalTokenCount, usage.output.totalTokenCount)
    }
}

/// A ``LoadedLLMContainer`` that vends ``ScriptedToolCallingBackend``s, so a
/// `RoutedSession` vended off a stub-resolved profile drives a real,
/// tool-mounted `LanguageModelSession` with no GPU in the loop.
///
/// It overrides both `tools:` factory overloads rather than taking the
/// protocol's tool-dropping defaults: mounting the session's tools is exactly
/// what this fixture exists to exercise.
struct ScriptedToolCallingContainer: LoadedLLMContainer {
    /// The scripted model every backend this container vends runs over.
    let model: ScriptedToolCallingModel

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
        ScriptedToolCallingBackend(model: model, tools: tools, instructions: instructions)
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
        ScriptedToolCallingBackend(model: model, tools: tools, transcript: transcript)
    }
}
