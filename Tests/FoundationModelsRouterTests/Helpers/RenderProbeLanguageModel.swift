import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// The log of one ``RenderProbeLanguageModel``: the transcript that each
/// generation call of the session received, and the count of the summaries
/// that the summarizer calls wrote.
///
/// A class, so that the test reads the same log that the executor writes. A
/// `Mutex`, because the executor writes from the task of the SDK and the test
/// reads from its own task.
final class RenderProbeLog: Sendable {
    /// The state of the log.
    private struct State {
        /// The transcript of each generation call of the session, in call
        /// order. A summarizer call is not in this list.
        var renders: [Transcript] = []

        /// The count of the summaries that the summarizer calls wrote.
        var summaryCount = 0
    }

    /// Backing storage for the log.
    private let state = Mutex(State())

    /// The transcript of each generation call of the session, in call order.
    var renders: [Transcript] { state.withLock { $0.renders } }

    /// Records the transcript that one generation call of the session received.
    ///
    /// - Parameter render: The transcript of the call.
    func record(render: Transcript) {
        state.withLock { $0.renders.append(render) }
    }

    /// Counts one more summary, and gives its number.
    ///
    /// - Returns: The number of the new summary. The first summary is number 1.
    func takeSummaryNumber() -> Int {
        state.withLock { state in
            state.summaryCount += 1
            return state.summaryCount
        }
    }
}

/// A deterministic `LanguageModel` that records the transcript of each
/// generation call, and reports usage that is the size of that transcript.
///
/// Each executor call does one of two things:
///
/// - a compaction's summarizer call (its prompt holds the compaction prompt):
///   it answers with ``Executor/snapshotText(number:)``, and the log counts
///   the summary;
/// - any other call: the log records the transcript of the call. The call asks
///   for the ``MarkerEmittingTool`` while the turn has made fewer than
///   ``toolRoundsPerTurn`` tool calls, and answers with
///   ``Executor/answerText(to:)`` after that.
///
/// The fed tokens that each call reports are the count of the
/// ``CharacterTokenCounter`` over the transcript of the call. So the fed tokens
/// are the size of the render that the session sent to the model.
struct RenderProbeLanguageModel: LanguageModel {
    /// The log that the executor writes.
    let log: RenderProbeLog

    /// The count of the tool calls that each turn makes before it answers.
    let toolRoundsPerTurn: Int

    /// Declares tool calling, because a tool-mounted session refuses a model
    /// without it.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the log and the tool rounds.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, toolRoundsPerTurn: toolRoundsPerTurn)
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that the executor writes.
            let log: RenderProbeLog

            /// The count of the tool calls that each turn makes before it
            /// answers.
            let toolRoundsPerTurn: Int

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.toolRoundsPerTurn == rhs.toolRoundsPerTurn
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(toolRoundsPerTurn)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = RenderProbeLanguageModel

        /// The token count every emitted fragment reports. The usage of a call
        /// comes from its `.updateUsage` action, not from this count.
        private static let emittedTokenCount = 1

        /// The counter that measures each transcript and each output.
        private static let counter = CharacterTokenCounter()

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The log and the tool rounds.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// The text of the summary with number `number`.
        ///
        /// - Parameter number: The number of the summary. The first is 1.
        /// - Returns: The summary text.
        static func snapshotText(number: Int) -> String {
            "Snapshot number \(number) of the earlier work."
        }

        /// The answer text of a turn whose prompt is `prompt`.
        ///
        /// - Parameter prompt: The text of the prompt of the turn.
        /// - Returns: The answer text.
        static func answerText(to prompt: String) -> String {
            "Answer to: \(prompt)"
        }

        /// The step name that tool call `round` of a turn gives the tool as
        /// its `value` argument.
        ///
        /// - Parameter round: The zero-based position of the tool call in the
        ///   turn.
        /// - Returns: The step name.
        static func toolStep(round: Int) -> String {
            "probe-\(round)"
        }

        /// The entries of `transcript` after its last `.prompt` entry: the
        /// entries of the turn in flight.
        private static func entriesOfTurn(in transcript: Transcript) -> ArraySlice<Transcript.Entry> {
            let entries = Array(transcript)
            let lastPrompt = entries.lastIndex { entry in
                guard case .prompt = entry else { return false }
                return true
            }
            return entries[(lastPrompt.map { $0 + 1 } ?? entries.startIndex)...]
        }

        /// The count of the tool calls that the turn in flight made.
        private static func toolRounds(in transcript: Transcript) -> Int {
            entriesOfTurn(in: transcript).filter { entry in
                guard case .toolCalls = entry else { return false }
                return true
            }.count
        }

        /// A new entry id with `prefix`. Each call makes new ids, because the
        /// SDK reads an entry id that the transcript already holds as that
        /// entry, and a session of this model makes many calls.
        ///
        /// - Parameter prefix: The prefix that names the kind of the entry.
        /// - Returns: The entry id.
        private static func newEntryID(_ prefix: String) -> String {
            "\(prefix)-\(UUID().uuidString)"
        }

        /// Plays out the call that `request` asks for.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript this
        ///     call branches on.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: What the counter throws.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: RenderProbeLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let transcript = request.transcript
            let fedTokens = try Self.counter.count(transcript)
            let prompts = transcript.promptTexts
            if prompts.contains(where: { $0.contains(CompactionPrompt.default.text) }) {
                let text = Self.snapshotText(number: configuration.log.takeSummaryNumber())
                await Self.send(text: text, entryID: Self.newEntryID("snapshot"), fedTokens: fedTokens, into: channel)
                return
            }
            configuration.log.record(render: transcript)
            let round = Self.toolRounds(in: transcript)
            guard round < configuration.toolRoundsPerTurn else {
                let text = Self.answerText(to: prompts.last ?? "")
                await Self.send(text: text, entryID: Self.newEntryID("answer"), fedTokens: fedTokens, into: channel)
                return
            }
            await Self.sendToolCall(round: round, fedTokens: fedTokens, into: channel)
        }

        /// Sends one text response, and its usage: `fedTokens` in, and the
        /// size of `text` out.
        private static func send(
            text: String, entryID: String, fedTokens: Int,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(entryID: entryID, action: .appendText(text, tokenCount: emittedTokenCount)))
            await send(fedTokens: fedTokens, generatedTokens: counter.count(text), entryID: entryID, into: channel)
        }

        /// Sends tool call `round` of the turn, and its usage: `fedTokens` in,
        /// and the size of the tool name and the arguments out.
        private static func sendToolCall(
            round: Int, fedTokens: Int, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            let arguments = #"{"value":"\#(toolStep(round: round))"}"#
            await channel.send(
                .toolCalls(
                    entryID: newEntryID("probe-tool-calls"),
                    action: .toolCall(
                        id: newEntryID("probe-call"),
                        name: MarkerEmittingTool.toolName,
                        action: .appendArguments(arguments, tokenCount: emittedTokenCount))))
            await send(
                fedTokens: fedTokens, generatedTokens: counter.count(MarkerEmittingTool.toolName + arguments),
                entryID: newEntryID("probe-tool-usage"), into: channel)
        }

        /// Sends the usage of one call.
        private static func send(
            fedTokens: Int, generatedTokens: Int, entryID: String,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(
                .response(
                    entryID: entryID,
                    action: .updateUsage(
                        input: .init(totalTokenCount: fedTokens, cachedTokenCount: 0),
                        output: .init(totalTokenCount: generatedTokens, reasoningTokenCount: 0))))
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``RenderProbeLanguageModel``, with the log of the model and the recorder
/// that holds the run journal of the session.
struct RenderProbeSessionFixture {
    /// The vended session a test drives its turns on.
    let session: RoutedSession

    /// The log that the model writes.
    let log: RenderProbeLog

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router, resolves a profile at `context`, and vends a session
    /// with `instructions` over a ``RenderProbeLanguageModel``.
    ///
    /// - Parameters:
    ///   - instructions: The instructions of the session.
    ///   - toolRoundsPerTurn: The count of the tool calls that each turn
    ///     makes before it answers.
    ///   - context: The working context the profile resolves at.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        instructions: String,
        toolRoundsPerTurn: Int,
        context: Int,
        tempDirPrefix: String
    ) async throws -> RenderProbeSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let log = RenderProbeLog()
        let model = RenderProbeLanguageModel(log: log, toolRoundsPerTurn: toolRoundsPerTurn)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: model), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: context), reporting: ResolutionProgress())
        return RenderProbeSessionFixture(
            session: profile.standard.makeSession(instructions: instructions, tools: [MarkerEmittingTool()]),
            log: log,
            recorder: recorder,
            directory: directory)
    }
}
