import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The Qwen 3.8 generation model this suite drives: a dense 27B model in the
/// `mxfp4` quantization, with the `qwen3_5` architecture that MLX loads.
///
/// This is the largest model any tool-answer suite of this package drives. The
/// sibling `RealToolAnswerComparisonTests` moved from the 30B to a 4B for cost,
/// and this suite exists so that one tool-using answer on a model of this size
/// is measured at all. It drives the `respond(to:)` surface only, one answer,
/// one load, so its cost is the load plus one answer.
private let qwen38ToolAnswerModel: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

// MARK: - Suite

/// One real tool-using answer on Qwen 3.8 27B mxfp4.
///
/// The scenario is the one `ScriptedToolAnswerComparisonTests` and
/// `RealToolAnswerComparisonTests` share: two marker tools, one prompt that asks
/// for both, and an answer that must quote the identifiers the tools returned.
/// Every assertion is a claim about this one answer:
///
/// - the answer recorded at least one `.toolOutput`, so a tool really ran;
/// - every marker the answer's own tool outputs delivered is in the answer;
/// - the answer equals the text of the last `.response` entry the answer recorded;
/// - every announced call is answered exactly once, as a multiset of ordinals;
/// - the transcript ends with the answer, after the tool work it reports.
///
/// An answer that called the tools with an argument the scenario does not name
/// still runs a tool and still records its output, but that output carries no
/// marker. That is a model choice and not a Router defect, so it is recorded
/// as a known issue rather than failed, as the sibling suite does.
@Suite(
    "Gated real-model integration: Qwen 3.8 27B mxfp4 calls its tools on the respond surface",
    .serialized,
    .exclusiveRealModel
)
struct Qwen38ToolAnswerIntegrationTests {
    // MARK: - Scenario tools

    /// The argument schema both scenario tools take: one required string.
    @Generable
    struct StepArguments {
        /// The step name the model was told to look up.
        let step: String
    }

    /// A tool whose output carries the scenario's distinctive marker for the
    /// step it was called with.
    struct MarkerTool: FoundationModels.Tool {
        /// The model-facing tool name.
        let name: String

        /// The `Tool` description requirement, real prose a real model reads.
        let description = "Looks up the record for a step name and returns its identifier."

        /// Returns the marker for the step this call names.
        ///
        /// - Parameter arguments: The call's decoded arguments.
        /// - Returns: ``ToolAnswerScenario/marker(for:)`` for the named step.
        /// - Throws: Never. `throws` comes from the `Tool` requirement.
        func call(arguments: StepArguments) async throws -> String {
            ToolAnswerScenario.marker(for: arguments.step)
        }
    }

    /// The model-facing name the scenario's first call names.
    private static let firstTool = "lookup-alpha"

    /// The model-facing name the scenario's second call names.
    private static let secondTool = "lookup-beta"

    /// The instructions that make the model play the scenario out: two named
    /// calls, made together in one step, then an answer that quotes both
    /// identifiers.
    private static let instructions = """
        You have two tools. To answer the user you must call \
        `\(firstTool)` with step "\(ToolAnswerScenario.firstStep)" and \
        `\(secondTool)` with step "\(ToolAnswerScenario.secondStep)". \
        Make both calls together, in one step, before you reply. \
        Then reply with both identifiers the tools returned, exactly as they \
        were returned, and nothing else.
        """

    /// The prompt the scenario's answer is driven with.
    private static let prompt = """
        Look up both steps with your tools and tell me the two identifiers.
        """

    /// The decoding strategy the loaded container is pinned to. Argmax
    /// decoding consumes no randomness, so a red run is attributable to the
    /// change under test and not to the sampler.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

    // MARK: - Harness

    /// Builds a `RoutedSession` over the loaded model with the scenario's two
    /// tools mounted.
    ///
    /// - Parameter container: The loaded model container and the
    ///   ``samplingMode`` its caller pinned, which every session it makes
    ///   decodes with.
    /// - Returns: The vended session, the profile that must outlive it, and
    ///   the temp directory the caller removes.
    private func makeSession(
        over container: RealModelContainer
    ) -> (session: RoutedSession, profile: LanguageModelProfile, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen38ToolAnswer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let profile = RealModelHarness.make(
            model: qwen38ToolAnswerModel,
            context: ScriptedSessionContext.tokens,
            container: container.container,
            samplingMode: container.samplingMode,
            cacheDir: directory,
            recordingsDir: directory
        )
        let session = profile.standard.makeSession(
            instructions: Self.instructions,
            tools: [
                MarkerTool(name: Self.firstTool),
                MarkerTool(name: Self.secondTool),
            ])
        return (session, profile, directory)
    }

    /// Reads the session's own transcript back off its backend.
    ///
    /// - Parameter session: The session whose answer has already returned.
    /// - Returns: The SDK's transcript entries, in order.
    private func transcriptEntries(of session: RoutedSession) async -> [Transcript.Entry] {
        guard let actor = session as? RoutedSessionActor else { return [] }
        return await actor.backend.transcriptEntries()
    }

    /// Reads the session's cumulative token usage back off its backend, as
    /// text for the run's printed record.
    ///
    /// - Parameter session: The session whose answer has already returned.
    /// - Returns: `in=<input> out=<output>`, or `unmetered` when the backend
    ///   cannot report usage.
    private func usageDescription(of session: RoutedSession) async -> String {
        guard let actor = session as? RoutedSessionActor,
            let usage = await actor.backend.usageTokenCounts()
        else { return "unmetered" }
        return "in=\(usage.input) out=\(usage.output)"
    }

    // MARK: - Transcript arithmetic

    /// The ordinal of every tool call the answer announced, in announcement
    /// order.
    ///
    /// - Parameter transcript: The run's normalized transcript.
    /// - Returns: One ordinal per call in every `.toolCalls` entry.
    private static func announcedCallOrdinals(in transcript: [NormalizedTranscriptEntry]) -> [Int] {
        transcript.flatMap { entry -> [Int] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.map(\.ordinal)
        }
    }

    /// The call each `.toolOutput` entry answers, in record order, `nil`
    /// where its id named no call the same transcript announced.
    ///
    /// - Parameter transcript: The run's normalized transcript.
    /// - Returns: One resolved call ordinal per tool-output entry.
    private static func answeredCallOrdinals(in transcript: [NormalizedTranscriptEntry]) -> [Int?] {
        transcript.flatMap { entry -> [Int?] in
            guard case .toolOutput(let callOrdinal, _, _) = entry else { return [] }
            return [callOrdinal]
        }
    }

    /// How many times each value occurs.
    ///
    /// - Parameter values: The values to count.
    /// - Returns: The number of occurrences of each distinct value.
    private static func tally<Value: Hashable>(_ values: [Value]) -> [Value: Int] {
        values.reduce(into: [:]) { counts, value in counts[value, default: 0] += 1 }
    }

    // MARK: - Test

    @Test("a tool-using answer on Qwen 3.8 records its tool calls and outputs, and carries the markers")
    func toolAnswerRecordsCallsAndDeliversMarkers() async throws {
        let loadStarted = ContinuousClock.now
        let container = try await RealModelContainer.load(
            ref: qwen38ToolAnswerModel, samplingMode: Self.samplingMode)
        let loadDuration = ContinuousClock.now - loadStarted

        let (session, profile, directory) = makeSession(over: container)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The session's handle holds its owning profile weakly, so the profile
        // has to stay referenced for the whole answer.
        defer { withExtendedLifetime(profile) {} }

        let startInstant = ContinuousClock.now
        let answer = try await session.respond(
            to: Self.prompt, maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let answerDuration = ContinuousClock.now - startInstant

        let run = ToolAnswerRunOutcome(
            answer: answer,
            calledIds: [],
            completedIds: [],
            failedIds: [],
            entries: await transcriptEntries(of: session))
        let usage = await usageDescription(of: session)

        // The answer is complete and every fact the assertions read is in
        // `run`, so the 14 GB of weights go back before the assertions run
        // rather than after them. Every other gated suite of this target
        // evicts what it loads. The CI run of 2026-09-08 for commit 422023d
        // measured what a suite that does not evict costs the suites after it:
        // on the runner, the Muse Glimmer load that took 6 seconds before this
        // suite ran took 104 seconds after it, and four Muse suites timed out
        // at the time limit of that day.
        await container.container.model.evict()

        // Printed so a reader can see what the model did, and so the cost
        // splits into the load and the answer.
        print(
            """
            QWEN38 load: \(loadDuration), respond answer: \(answerDuration), usage: \(usage)
            QWEN38 transcript:
            \(run.transcriptDescription)
            QWEN38 answer: \(run.answer.debugDescription)
            """)

        // The answer really used its tools, proved by the tool outputs its own
        // transcript records.
        let recordedToolOutputs = run.transcript.filter { $0.kind == .toolOutput }.count
        #expect(recordedToolOutputs > 0, "the answer recorded no tool output, so nothing proves a tool ran")

        // The markers trace delivery, and only an answer that called the tools
        // the way the scenario names them delivers one. A different argument
        // is a model choice, recorded rather than failed.
        if recordedToolOutputs > 0 {
            withKnownIssue(
                "the answer called its tools with arguments the scenario does not name, so no output carried a marker",
                isIntermittent: true
            ) {
                #expect(!run.deliveredMarkers.isEmpty)
            }
        }

        // The answer carries every identifier its own tools returned.
        for marker in run.deliveredMarkers {
            #expect(run.answer.contains(marker), "the answer lost \(marker), which a tool output delivered")
        }

        // The surface reports the answer it drove, character for character.
        #expect(
            run.answer == run.finalResponseText,
            """
            the reported answer is not the one the transcript records.
            reported: \(run.answer.debugDescription)
            recorded: \(run.finalResponseText.debugDescription)
            """)

        // Every announced call was answered exactly once, as a multiset.
        let announced = Self.announcedCallOrdinals(in: run.transcript)
        let answered = Self.answeredCallOrdinals(in: run.transcript)
        #expect(
            Self.tally(answered) == Self.tally(announced.map { ordinal -> Int? in ordinal }),
            """
            the answer did not answer each announced call exactly once.
            announced: \(announced)
            answered:  \(answered.map { $0.map(String.init) ?? "UNMATCHED" })
            """)

        // The transcript holds the scenario's shape and ends with the answer,
        // after the tool work it reports. A `<think>` block after the answer
        // is a `.reasoning` entry, so the last entry that is not reasoning is
        // the `.response`.
        let kinds = run.transcript.map(\.kind)
        #expect(kinds.first == .instructions)
        #expect(kinds.contains(.toolCalls))
        #expect(kinds.contains(.toolOutput))
        #expect(
            kinds.last(where: { $0 != .reasoning }) == .response,
            "the answer should end with its reply; kinds were \(kinds.map(\.rawValue))")
        let lastResponseIndex = try #require(kinds.lastIndex(of: .response))
        let lastToolOutputIndex = try #require(kinds.lastIndex(of: .toolOutput))
        #expect(lastResponseIndex > lastToolOutputIndex)
    }
}
