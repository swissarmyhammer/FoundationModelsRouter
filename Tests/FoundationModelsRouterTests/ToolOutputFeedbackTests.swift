import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The shared vocabulary of the tool-output-feedback fixtures: the distinctive
/// marker a mounted tool stamps into its output, the steps a turn calls that
/// tool for, and the prefix the scripted model opens its final answer with.
///
/// One source of truth so the tool that *produces* a marker and the assertion
/// that *looks for* it can never drift apart, and so a test asserts on content
/// the model could only have learned from a tool output.
enum ToolOutputFeedbackFixture {
    /// The distinctive token every marker output opens with — long enough that
    /// no model prior could produce it and no other fixture collides with it.
    static let markerPrefix = "MARKER-7F3A-"

    /// The steps one turn calls the mounted tool for, in order. Two of them, so
    /// a turn is `call -> output -> call again -> output -> answer` and a loop
    /// that delivers only the first output is caught.
    static let steps = ["ONE", "TWO"]

    /// The marker each step's tool output carries, in step order.
    static var markers: [String] { steps.map { markerPrefix + $0 } }

    /// The text the scripted model opens its final answer with, before the
    /// marker outputs it read back out of the transcript.
    static let answerPrefix = "answer: "

    /// The prompt every test in this suite drives its turn with.
    static let prompt = "look up both steps and tell me what you were told"
}

// MARK: - The mounted tool

/// A `FoundationModels.Tool` whose output carries a distinctive marker for the
/// step it was called with, and which records every step it was called for.
///
/// The marker is what makes the feedback claim assertable *by content*: the
/// scripted model below has no way to produce `MARKER-7F3A-TWO` except by
/// reading the second tool output out of the transcript it is handed, so a
/// final answer carrying it proves the output re-entered generation.
///
/// A class deliberately, so the test can read back the calls the very instance
/// the session mounted actually served.
final class MarkerEmittingTool: Tool, Sendable {
    /// The model-facing tool name, also the name the scripted model calls.
    static let toolName = "marker-lookup"

    let name = MarkerEmittingTool.toolName
    let description = "test-only tool that returns a distinctive marker for the step it is given"

    /// Backing storage for ``calledSteps``.
    private let calledStepsBox: Mutex<[String]> = Mutex([])

    /// Every step this tool was called for, in call order.
    ///
    /// A `Mutex` because the model call that invokes the tool and the test that
    /// reads the calls back are not the same task; the test reads only after
    /// its driving turn returned, but the write happens inside the SDK's own
    /// tool-calling task.
    var calledSteps: [String] { calledStepsBox.withLock { $0 } }

    func call(arguments: AmbientToolArguments) async throws -> String {
        calledStepsBox.withLock { $0.append(arguments.value) }
        return ToolOutputFeedbackFixture.markerPrefix + arguments.value
    }
}

// MARK: - The scripted model

/// A deterministic `LanguageModel` that drives a multi-call tool turn and then
/// answers with what the tool outputs told it.
///
/// It carries no state of its own: every executor call re-reads the full
/// transcript it is handed (the `LanguageModel` boundary passes the whole
/// accumulated history on every call — see `LanguageModelBoundaryProbeTests`)
/// and branches on how many tool outputs are already in it:
///
/// - fewer tool outputs than ``ToolOutputFeedbackFixture/steps`` has steps:
///   emit a tool call for the next step;
/// - all steps answered: emit the final text answer, built from the tool
///   output text read back out of the transcript.
///
/// The final branch is the whole point of the fixture. The answer is composed
/// from what the transcript actually carries, never from a canned string, so a
/// turn whose tool outputs never reach generation cannot produce it.
struct ScriptedToolCallingModel: LanguageModel {
    /// Declares tool calling, and nothing else. Without it the SDK refuses a
    /// tool-mounted session outright ("The selected model does not support
    /// tool calling"), so this is the one capability a scripted tool turn
    /// needs.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key. The scripted behaviour is fully
    /// determined by the fixture constants, so the configuration carries only
    /// the tool name this model calls.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(toolName: MarkerEmittingTool.toolName)
    }

    /// The executor that emits this model's scripted tool calls and final
    /// answer over the SDK's own generation channel.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by: the name of
        /// the tool the scripted turn calls, which is the only thing that
        /// varies the behaviour.
        struct Configuration: Sendable, Hashable {
            /// The model-facing name of the tool this executor calls.
            let toolName: String
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = ScriptedToolCallingModel

        /// The token count every emitted fragment reports. The scripted model
        /// meters nothing, and no assertion in this suite reads token counts.
        private static let emittedTokenCount = 1

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration the SDK constructed this
        /// executor with.
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

        /// Emits one scripted tool call, or the final answer once every step
        /// has been answered.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ScriptedToolCallingModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let toolOutputs = Self.toolOutputTexts(in: request.transcript)
            guard toolOutputs.count < ToolOutputFeedbackFixture.steps.count else {
                let answer = ToolOutputFeedbackFixture.answerPrefix + toolOutputs.joined(separator: " ")
                await channel.send(
                    .response(action: .appendText(answer, tokenCount: Self.emittedTokenCount)))
                return
            }
            let step = ToolOutputFeedbackFixture.steps[toolOutputs.count]
            await channel.send(
                .toolCalls(
                    action: .toolCall(
                        id: "scripted-tool-call-\(step)",
                        name: configuration.toolName,
                        action: .appendArguments(
                            #"{"value":"\#(step)"}"#, tokenCount: Self.emittedTokenCount)
                    )
                )
            )
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
        /// to constrain here. No test in this suite drives a guided turn.
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

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        let options = GenerationOptions(maximumResponseTokens: maxTokens)
        return try await liveSession.respond(to: prompt, options: options).content
    }

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

    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        throw FixtureError.guidedGenerationUnsupported
    }

    func makeFork() -> any LanguageModelSessionBackend {
        makeFork(tools: tools)
    }

    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        ScriptedToolCallingBackend(model: model, tools: tools, transcript: liveSession.transcript)
    }

    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        ScriptedToolCallingBackend(model: model, tools: tools, transcript: transcript)
    }

    func transcriptEntries() -> [Transcript.Entry] {
        Array(liveSession.transcript)
    }

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
    let model = ScriptedToolCallingModel()

    /// The raw model handle, so a test can build its own session over the very
    /// model the container mounts.
    var languageModel: any FoundationModels.LanguageModel { model }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        ScriptedToolCallingBackend(model: model, tools: tools, instructions: instructions)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        ScriptedToolCallingBackend(model: model, tools: tools, transcript: transcript)
    }
}

// MARK: - Suite

/// Task ^cvtfem3: pins the claim a `RoutedSession` turn is supposed to make —
/// **a mounted tool's output reaches the model's next generation** — on both of
/// the session's generation surfaces, `respond(to:)` and `streamEvents(to:)`.
///
/// Both tests drive the same scripted multi-call turn against the same mounted
/// tool and assert the same thing about the answer, by content: it carries the
/// marker text of *every* tool output the turn produced. Holding the two
/// surfaces to one assertion is the point — a surface that drops tool output,
/// or a loop that delivers only the first output, fails here while the other
/// surface passes, and the difference is the defect.
@Suite("Mounted tool output reaches the model's next generation")
struct ToolOutputFeedbackTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ToolOutputFeedbackTests"

    /// Builds a fresh router + resolved profile + `RoutedSession` over a
    /// ``ScriptedToolCallingContainer``, with one ``MarkerEmittingTool``
    /// mounted.
    ///
    /// - Returns: The vended session, the mounted tool instance, and the temp
    ///   directory the caller must remove.
    private static func makeSession() async throws -> (
        session: RoutedSession, tool: MarkerEmittingTool, dir: URL
    ) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(
                container: ScriptedToolCallingContainer(), dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let tool = MarkerEmittingTool()
        let session = profile.standard.makeSession(tools: [tool])
        return (session, tool, dir)
    }

    /// Asserts the one contract both surfaces are held to: the turn really made
    /// a call per step, and the answer carries every tool output's marker.
    ///
    /// - Parameters:
    ///   - answer: The turn's final answer text.
    ///   - tool: The mounted tool the turn called.
    private static func expectEveryToolOutputReachedTheAnswer(
        _ answer: String, tool: MarkerEmittingTool
    ) {
        // The turn is genuinely multi-call: one tool call per step, in order.
        #expect(tool.calledSteps == ToolOutputFeedbackFixture.steps)
        // And every one of those outputs reached the generation that answered.
        for marker in ToolOutputFeedbackFixture.markers {
            #expect(answer.contains(marker), "answer did not carry \(marker): \(answer)")
        }
    }

    @Test("respond(to:) answers with every mounted tool output the turn produced")
    func respondFeedsToolOutputBackIntoGeneration() async throws {
        let (session, tool, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let answer = try await session.respond(to: ToolOutputFeedbackFixture.prompt)

        Self.expectEveryToolOutputReachedTheAnswer(answer, tool: tool)
    }

    @Test("streamEvents(to:) answers with every mounted tool output the turn produced")
    func streamEventsFeedsToolOutputBackIntoGeneration() async throws {
        let (session, tool, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        var answer = ""
        let events = await session.streamEvents(to: ToolOutputFeedbackFixture.prompt)
        for try await event in events {
            guard case .textDelta(let delta) = event else { continue }
            answer += delta
        }

        Self.expectEveryToolOutputReachedTheAnswer(answer, tool: tool)
    }
}
