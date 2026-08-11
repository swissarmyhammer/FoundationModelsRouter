import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// The target's opt-in gate: unset (the default, and on any CI/GPU-less box)
/// this whole suite is skipped, so `swift test` stays green without network or
/// a GPU. Kept as its own file-scoped constant rather than sharing another
/// file's — Swift's top-level `private` is file-scoped, not target-scoped.
private let realToolTurnEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var realToolTurnEnabled: Bool {
    ProcessInfo.processInfo.environment[realToolTurnEnvVar] != nil
}

/// The same real `mlx-community` generation model this target's other gated
/// suites drive for the `.standard` slot.
private let realToolTurnModel: ModelRef = RealModels.standard

// MARK: - Suite

/// Task ^w8dzvee: the real-model half of the four-way tool-turn comparison.
///
/// The ungated `ScriptedToolTurnComparisonTests` runs one tool-using scenario
/// through both `RoutedSession` surfaces over a deterministic scripted model.
/// This suite runs the *same* scenario — the same two marker tools, the same
/// prompt shape, the same normalization — against a real model, and holds the
/// live path to every property the scripted path proves and a real model can
/// still decide.
///
/// **Why this suite compares each surface with its own turn, not with the
/// other's.** Driving a scenario twice against a real model produces two
/// *independent* turns, and this model does not repeat itself across them.
/// Measured over four gated runs of this suite on one machine, with sampling
/// pinned to ``GenerationOptions/SamplingMode/greedy`` and the prompt held
/// fixed, one surface took **11, 3, 2 and 1** tool rounds — and in one run the
/// two surfaces even chose different tools first. So an assertion that the two
/// transcripts are equal, or that the turn made exactly two calls, asserts that
/// the *model* is reproducible. It is not, and no Router change makes it so.
/// Those cross-turn equalities live in the scripted suite, where the model is
/// fixed and they are decidable; here every assertion is a claim about a single
/// turn, and every one of them is still an equality:
///
/// - each surface's answer equals, character for character, the text of the
///   last `.response` entry **its own** turn recorded (the property defect D2
///   corrupted);
/// - the answer carries every marker that turn's own tool outputs delivered;
/// - the transcript holds one `.toolOutput` per announced call, each resolving
///   to the call it answers (the property defect D1 was about, on real ids);
/// - the streamed completion ids are exactly the streamed call ids.
///
/// A model that calls fewer tools than the scenario asks for is not a Router
/// defect and is not measured here; it belongs to task ^pw807cp.
///
/// See ``NormalizedTranscriptEntry`` for the normalization and its rationale.
@Suite(
    "Gated real-model integration: a real tool-using turn delivers its tools' data on both session surfaces (task ^w8dzvee)",
    .serialized,
    .timeLimit(.minutes(30)),
    .enabled(if: realToolTurnEnabled),
    .exclusiveRealModel
)
struct RealToolTurnComparisonTests {
    // MARK: - Scenario tools

    /// The argument schema both scenario tools take: one required string, the
    /// smallest surface a real model reliably fills in when told what to pass.
    @Generable
    struct StepArguments {
        /// The step name the model was told to look up.
        let step: String
    }

    /// A tool whose output carries the scenario's distinctive marker for the
    /// step it was called with.
    ///
    /// The marker is what makes the delivery claim assertable by content: a
    /// real model has no way to produce `MARKER-7F3A-ONE` except by reading
    /// this output back out of the transcript it is handed.
    struct MarkerTool: FoundationModels.Tool {
        /// The model-facing tool name.
        let name: String

        /// The `Tool` description requirement — real prose, because a real
        /// model reads it to decide what to call.
        let description = "Looks up the record for a step name and returns its identifier."

        /// Returns the marker for the step this call names.
        ///
        /// - Parameter arguments: The call's decoded arguments.
        /// - Returns: ``ToolTurnScenario/marker(for:)`` for the named step.
        /// - Throws: Never — `throws` comes from the `Tool` requirement.
        func call(arguments: StepArguments) async throws -> String {
            ToolTurnScenario.marker(for: arguments.step)
        }
    }

    /// The model-facing name the scenario's first call names.
    private static let firstTool = "lookup-alpha"

    /// The model-facing name the scenario's second call names.
    private static let secondTool = "lookup-beta"

    /// The instructions that make a real model play the scenario out: two
    /// named calls, then an answer quoting both identifiers.
    private static let instructions = """
        You have two tools. To answer the user you must call \
        `\(firstTool)` with step "\(ToolTurnScenario.firstStep)" and \
        `\(secondTool)` with step "\(ToolTurnScenario.secondStep)". \
        Then reply with both identifiers the tools returned, exactly as they \
        were returned, and nothing else.
        """

    /// The prompt the scenario's turn is driven with.
    private static let prompt = """
        Look up both steps with your tools and tell me the two identifiers.
        """

    // MARK: - Harness

    /// Loads the real model directly through a live ``LiveModelLoader``.
    ///
    /// - Returns: The loaded container.
    /// - Throws: Whatever loading throws.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: realToolTurnModel,
            slot: .standard,
            context: RealModels.context,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// Builds a `RoutedSession` over the loaded real model with the scenario's
    /// two tools mounted.
    ///
    /// Greedy sampling is pinned (see ``MLXFoundationModelsContainer/samplingMode``)
    /// so nothing this suite can control is left to a draw from a distribution.
    /// It is not enough to make two turns identical — the suite's own doc
    /// comment records four runs in which it was not — which is why nothing
    /// here compares one turn against another.
    ///
    /// The embedding slot this suite never drives. Every gated suite in this
    /// target carries one: a `LanguageModelProfile` requires all three slots,
    /// and only `.standard` is ever exercised here.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        /// The embedding width, never read.
        let dimension = 1

        /// Never called.
        ///
        /// - Parameter texts: The strings that would be embedded.
        /// - Returns: Nothing — this entry point always fails a requirement.
        func embed(texts: [String]) async throws -> [[Float]] {
            Issue.record("the embedding slot is never driven by this suite")
            return []
        }
    }

    /// - Parameter container: The loaded model container.
    /// - Returns: The vended session, the profile that must outlive it (the
    ///   session's handle holds its owning profile weakly), and the temp
    ///   directory the caller removes.
    private func makeSession(
        over container: MLXFoundationModelsContainer
    ) -> (session: RoutedSession, profile: LanguageModelProfile, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealToolTurnComparison-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let greedy = MLXFoundationModelsContainer(model: container.model, samplingMode: .greedy)
        let recorder = JSONLRecorder(directory: directory)
        let router = Router(cacheDir: directory, recordingsDir: directory, recorder: recorder)
        func resolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(
                slot: slot, remainingBudgetBytes: 0, chosen: realToolTurnModel, considered: [])
        }
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: directory,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: realToolTurnModel,
                    context: resolution(slot).contextTokens,
                    recordingLevel: .full,
                    profile: nil,
                    routerId: router.id
                )
            )
        }
        func routedLLM(_ slot: ModelSlot) -> RoutedLLM {
            RoutedLLM(
                slot: slot,
                chosen: realToolTurnModel,
                footprintBytes: 0,
                resolution: resolution(slot),
                container: greedy,
                routerId: router.id,
                recorder: recorder,
                durableRecording: durableRecording(slot)
            )
        }
        let profile = LanguageModelProfile(
            definitionName: "real-tool-turn",
            standard: routedLLM(.standard),
            flash: routedLLM(.flash),
            embedding: RoutedEmbedder(
                slot: .embedding,
                chosen: realToolTurnModel,
                footprintBytes: 0,
                resolution: resolution(.embedding),
                container: UnusedEmbeddingContainer(),
                routerId: router.id,
                recorder: recorder,
                durableRecording: durableRecording(.embedding)
            ),
            router: router,
            residencyToken: .generate()
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
    /// - Parameter session: The session whose turn has already returned.
    /// - Returns: The SDK's transcript entries, in order.
    private func transcriptEntries(of session: RoutedSession) async -> [Transcript.Entry] {
        guard let actor = session as? RoutedSessionActor else { return [] }
        return await actor.backend.transcriptEntries()
    }

    // MARK: - Runs

    /// Drives one real turn through `respond(to:)`.
    ///
    /// - Returns: The run's answer and normalized transcript.
    /// - Throws: Whatever loading or the turn throws.
    private func respondRun() async throws -> ToolTurnRunOutcome {
        let container = try await makeContainer()
        let (session, profile, directory) = makeSession(over: container)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The session's handle holds its owning profile weakly, so the profile
        // has to stay referenced for the whole turn.
        defer { withExtendedLifetime(profile) {} }

        let answer = try await session.respond(to: Self.prompt)
        return ToolTurnRunOutcome(
            answer: answer,
            calledIds: [],
            completedIds: [],
            failedIds: [],
            entries: await transcriptEntries(of: session))
    }

    /// Drives one real turn through `streamEvents(to:)`, accumulating the text
    /// twice — once applying ``SessionEvent/textReset`` and once ignoring it —
    /// plus every tool id the turn reported.
    ///
    /// - Returns: The run's answers, ids, and normalized transcript.
    /// - Throws: Whatever loading or the turn throws.
    private func streamRun() async throws -> ToolTurnRunOutcome {
        let container = try await makeContainer()
        let (session, profile, directory) = makeSession(over: container)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The session's handle holds its owning profile weakly, so the profile
        // has to stay referenced for the whole turn.
        defer { withExtendedLifetime(profile) {} }

        var answer = ""
        var rawAnswer = ""
        var calledIds: [String] = []
        var completedIds: [String] = []
        var failedIds: [String] = []
        for try await event in await session.streamEvents(to: Self.prompt) {
            switch event {
            case .textDelta(let delta):
                answer += delta
                rawAnswer += delta
            case .textReset:
                answer = ""
            case .toolCall(let id, _, _):
                calledIds.append(id)
            case .toolStatus(let id, .completed, _):
                completedIds.append(id)
            case .toolStatus(let id, .failed, _):
                failedIds.append(id)
            case .toolStatus, .reasoningDelta, .compaction, .discoveryPrimingFailed, .turnEnded:
                break
            }
        }
        return ToolTurnRunOutcome(
            answer: answer,
            rawAnswer: rawAnswer,
            calledIds: calledIds,
            completedIds: completedIds,
            failedIds: failedIds,
            entries: await transcriptEntries(of: session))
    }

    // MARK: - Transcript arithmetic

    /// The number of tool calls a turn announced, summed over every round.
    ///
    /// - Parameter transcript: The run's normalized transcript.
    /// - Returns: The total number of calls in every `.toolCalls` entry.
    private static func announcedCallCount(in transcript: [NormalizedTranscriptEntry]) -> Int {
        transcript.reduce(0) { total, entry in
            guard case .toolCalls(let calls) = entry else { return total }
            return total + calls.count
        }
    }

    /// The number of `.toolOutput` entries a turn recorded.
    ///
    /// - Parameter transcript: The run's normalized transcript.
    /// - Returns: The count of tool-output entries.
    private static func toolOutputCount(in transcript: [NormalizedTranscriptEntry]) -> Int {
        transcript.filter { $0.kind == .toolOutput }.count
    }

    /// The `.toolOutput` entries whose id named no call the same transcript
    /// announced — the shape defect D1 was about, rendered as `UNMATCHED`.
    ///
    /// - Parameter transcript: The run's normalized transcript.
    /// - Returns: The unmatched entries, for a legible failure message.
    private static func unmatchedToolOutputs(
        in transcript: [NormalizedTranscriptEntry]
    ) -> [NormalizedTranscriptEntry] {
        transcript.filter { entry in
            guard case .toolOutput(let callOrdinal, _, _) = entry else { return false }
            return callOrdinal == nil
        }
    }

    // MARK: - Tests

    @Test("a real tool-using turn delivers its own tools' data, on each surface, in the answer that surface reports")
    func realTurnDeliversToolDataOnBothSurfaces() async throws {
        let responded = try await respondRun()
        let streamed = try await streamRun()

        // Printed so the scripted-versus-real comparison is checkable by a
        // reader rather than asserted and thrown away.
        print(
            """
            REAL-RESPOND transcript:
            \(responded.transcriptDescription)
            REAL-RESPOND answer: \(responded.answer.debugDescription)
            REAL-STREAM transcript:
            \(streamed.transcriptDescription)
            REAL-STREAM answer: \(streamed.answer.debugDescription)
            REAL-STREAM raw answer: \(streamed.rawAnswer.debugDescription)
            REAL-STREAM called ids: \(streamed.calledIds)
            REAL-STREAM completed ids: \(streamed.completedIds)
            REAL-STREAM failed ids: \(streamed.failedIds)
            """)

        for (surface, run) in [("respond(to:)", responded), ("streamEvents(to:)", streamed)] {
            // The turn really used its tools. Zero tool calls is a real
            // failure of this scenario, not a shape the assertions bend
            // around: every one of the eight turns measured while this suite
            // was written called at least one.
            #expect(
                !run.deliveredMarkers.isEmpty,
                "\(surface) recorded no tool output, so nothing proves a tool ran")

            // The answer carries every identifier this turn's own tools
            // returned — data the model could only have read back out of the
            // transcript Router handed it.
            for marker in run.deliveredMarkers {
                #expect(
                    run.answer.contains(marker),
                    "\(surface) lost \(marker), which its own tool output delivered")
            }

            // The surface reports the answer of the turn it drove, character
            // for character — the property defect D2 corrupted by appending
            // superseded pre-tool text to it.
            #expect(
                run.answer == run.finalResponseText,
                """
                \(surface) reported an answer its own transcript does not record.
                reported: \(run.answer.debugDescription)
                recorded: \(run.finalResponseText.debugDescription)
                """)

            // Every announced call was answered, and every answer names the
            // call it answers — the property defect D1 was about, on real ids.
            #expect(
                Self.toolOutputCount(in: run.transcript)
                    == Self.announcedCallCount(in: run.transcript),
                """
                \(surface) did not record one tool output per announced call.
                \(run.transcriptDescription)
                """)
            #expect(
                Self.unmatchedToolOutputs(in: run.transcript).isEmpty,
                """
                \(surface) recorded a tool output naming no announced call.
                \(run.transcriptDescription)
                """)
        }

        // The streamed event stream reports exactly the calls the streamed
        // transcript announced, each completed once and none failed.
        #expect(streamed.calledIds.count == Self.announcedCallCount(in: streamed.transcript))
        #expect(Set(streamed.completedIds) == Set(streamed.calledIds))
        #expect(streamed.completedIds.count == streamed.calledIds.count)
        #expect(streamed.failedIds.isEmpty)

        // A consumer that ignores the reset still receives every fragment, and
        // the answer is the tail of what it received.
        #expect(
            streamed.rawAnswer.hasSuffix(streamed.answer),
            """
            the streamed answer is not a suffix of everything the stream delivered.
            answer: \(streamed.answer.debugDescription)
            raw:    \(streamed.rawAnswer.debugDescription)
            """)
    }

    @Test("the real transcript has the same entry kinds the scripted scenario produces")
    func realTranscriptShapeMatchesScriptedShape() async throws {
        let kinds = try await streamRun().transcript.map(\.kind)

        // The scripted scenario's own shape, which
        // `ScriptedToolTurnComparisonTests.transcriptCarriesToolCallsAndToolOutputs`
        // asserts exactly. A real model may add `.reasoning` entries and may
        // split its work over more than one round, so this asserts the kinds
        // the scripted run produces are all present, in order, rather than
        // that the two sequences are identical — and prints the real sequence
        // so a divergence is legible rather than merely red.
        print("REAL transcript kinds: \(kinds.map(\.rawValue))")
        #expect(kinds.first == .instructions)
        #expect(kinds.contains(.prompt))
        #expect(kinds.contains(.toolCalls))
        #expect(kinds.contains(.toolOutput))
        #expect(kinds.last == .response)
    }
}
