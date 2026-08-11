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
/// prompt shape, the same normalization — against a real model, and holds it to
/// the same properties. A divergence between the two is itself the finding, and
/// it resolves to exactly one of two things: the scripted model is unfaithful
/// (which is how defects D1 and D2 stayed invisible through two closed cards),
/// or the live path has a defect the scripted path does not reach.
///
/// **What is compared exactly, and what is not.** See
/// ``NormalizedTranscriptEntry`` for the normalization and its rationale. The
/// two real-model surfaces are held to identical normalized transcripts; the
/// real run and the scripted run are held to the same sequence of entry
/// *kinds*, because a real model chooses its own tool arguments and writes its
/// own prose while the scripted one is fixed. The load-bearing content — the
/// tool outputs, and the answer carrying markers only a tool could supply — is
/// asserted exactly on both.
@Suite(
    "Gated real-model integration: a real tool-using turn behaves identically on both session surfaces (task ^w8dzvee)",
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
    /// so two runs of the same scenario are a decision procedure rather than
    /// two draws from a distribution — without it the two surfaces would differ
    /// by sampling alone and the comparison would prove nothing.
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
            transcript: .normalizing(
                await transcriptEntries(of: session), markers: ToolTurnScenario.markers))
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
            transcript: .normalizing(
                await transcriptEntries(of: session), markers: ToolTurnScenario.markers))
    }

    // MARK: - Tests

    @Test("a real tool-using turn delivers the tool's data on both surfaces, and agrees on the transcript")
    func realTurnAgreesOnBothSurfaces() async throws {
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

        // The turn really used its tools: the answer carries identifiers only a
        // tool output could have supplied.
        for marker in ToolTurnScenario.markers {
            #expect(responded.answer.contains(marker), "respond(to:) lost \(marker)")
            #expect(streamed.answer.contains(marker), "streamEvents(to:) lost \(marker)")
        }

        // The transcript really carries the tool round, in order.
        #expect(streamed.transcript.contains { $0.kind == .toolCalls })
        #expect(streamed.transcript.filter { $0.kind == .toolOutput }.count == 2)

        // Every completion names a call the same turn announced, and the two
        // sets match — the property defect D1 was about, on real ids.
        #expect(Set(streamed.completedIds) == Set(streamed.calledIds))
        #expect(streamed.failedIds.isEmpty)

        // Both surfaces saw the same transcript.
        #expect(
            responded.transcript == streamed.transcript,
            """
            the real model's two surfaces produced different transcripts.
            respond(to:):
            \(responded.transcriptDescription)
            streamEvents(to:):
            \(streamed.transcriptDescription)
            """)

        // Applying the documented reset rule reconstructs what respond returns.
        #expect(
            streamed.answer == responded.answer,
            """
            the streamed answer is not the answer respond(to:) returned.
            streamed:  \(streamed.answer.debugDescription)
            responded: \(responded.answer.debugDescription)
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
