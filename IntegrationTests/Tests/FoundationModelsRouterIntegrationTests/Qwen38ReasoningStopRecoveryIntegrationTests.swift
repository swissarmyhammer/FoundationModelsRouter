import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The Qwen 3.8 generation model this suite drives, as the SWE-bench run of
/// task ^0dcsd3t did.
private let qwen38ReasoningStopModel: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

/// Task ^0dcsd3t on a real model: after a reasoning stop, the recovery pass
/// runs with the reasoning of the model off, and the model acts: it calls a
/// tool.
///
/// The session gets a small reasoning token limit, so the first pass of
/// Qwen 3.8 surely reaches it before it acts. The limit is a setting of this
/// test only: the default of the session does not change.
@Suite(
    "Gated real-model integration: Qwen 3.8 27B acts in the recovery after a reasoning stop",
    .serialized,
    .exclusiveRealModel
)
struct Qwen38ReasoningStopRecoveryIntegrationTests {
    /// The argument schema of the scenario tool: one required string.
    @Generable
    struct FileArguments {
        /// The path of the file the model wants to read.
        let path: String
    }

    /// A tool that returns the text of a file of the scenario.
    struct ReadFileTool: FoundationModels.Tool {
        /// The model-facing tool name.
        let name = "read_file"

        /// The `Tool` description requirement, real prose a real model reads.
        let description = "Reads one file of the project and returns its text."

        /// Returns the text of the scenario file.
        ///
        /// - Parameter arguments: The call's decoded arguments.
        /// - Returns: A short file text.
        /// - Throws: Never. `throws` comes from the `Tool` requirement.
        func call(arguments: FileArguments) async throws -> String {
            "def add(a, b):\n    return a - b\n"
        }
    }

    /// The reasoning token limit of this test: small, so the first pass of a
    /// reasoning model reaches it before it acts.
    private static let reasoningTokenLimit = 64

    /// The instructions of the scenario.
    private static let instructions = """
        You fix bugs in a Python project. Use the `read_file` tool to read a file before you change it.
        """

    /// The prompt of the scenario.
    private static let prompt = """
        The function `add` in `calc.py` gives wrong results. Find the bug.
        """

    /// The decoding strategy the loaded container is pinned to.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

    /// Whether `entry` is the prompt of the recovery after a reasoning stop.
    ///
    /// - Parameter entry: One transcript entry.
    /// - Returns: `true` for that prompt.
    private static func isReasoningRecoveryPrompt(_ entry: Transcript.Entry) -> Bool {
        guard case .prompt(let prompt) = entry else { return false }
        return WatchedText.text(of: prompt.segments) == RoutedSessionActor.reasoningStopContinuationPrompt
    }

    @Test("the recovery after a reasoning stop runs with the reasoning off and calls a tool")
    func recoveryAfterReasoningStopCallsATool() async throws {
        let container = try await RealModelContainer.load(
            ref: qwen38ReasoningStopModel, samplingMode: Self.samplingMode)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen38ReasoningStop-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = RealModelHarness.make(
            model: qwen38ReasoningStopModel, context: ScriptedSessionContext.tokens,
            container: container.container, samplingMode: container.samplingMode,
            cacheDir: directory, recordingsDir: directory)
        // The session's handle holds its owning profile weakly, so the profile
        // has to stay referenced for the whole answer.
        defer { withExtendedLifetime(profile) {} }
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(
                instructions: Self.instructions, tools: [ReadFileTool()],
                repetitionDetection: RepetitionDetection(reasoningTokenLimit: Self.reasoningTokenLimit)))

        let stops = Mutex<[ReasoningStop]>([])
        let answer = try await session.respond(
            to: Self.prompt, maxTokens: GatedRealModelBudget.responseTokenCeiling
        ) { event in
            guard case .reasoningStopped(let stop) = event else { return }
            stops.withLock { $0.append(stop) }
        }
        let entries = await (session as? RoutedSessionActor)?.backend.transcriptEntries() ?? []
        await container.container.model.evict()

        let stop = try #require(stops.withLock { $0.first })
        #expect(stop.recovery == 1)
        let recoveryPrompt = try #require(entries.lastIndex(where: Self.isReasoningRecoveryPrompt))
        let actedAfterRecovery = entries[recoveryPrompt...].contains { entry in
            guard case .toolCalls = entry else { return false }
            return true
        }
        #expect(actedAfterRecovery, "the recovery pass made no tool call")
        #expect(!answer.reply.isEmpty)
    }
}
