import Foundation
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// Loads ``CompactionEvalRealModel`` at most once and reuses it across every
/// sample's ``run(steps:finalInstruction:prompt:budget:)`` call, driving a
/// real, full ``RoutedSession`` (task 8213x39's auto-compaction opt-in) per
/// call rather than the bare `Compactor.compact` + one-shot session recipe
/// ``CompactionEvalRealSubjectRunner`` uses — this evaluation needs the whole
/// session surface (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``,
/// ``RoutedSession/streamEvents(to:maxTokens:)``, and its durable recording)
/// to drive a genuinely multi-step, auto-compacting conversation, not just
/// one fold-then-ask call.
///
/// Builds a fresh ``LanguageModelProfile``/``Router`` per call over the one
/// cached, already-loaded ``MLXFoundationModelsContainer``, so every sample gets
/// its own isolated recording root without paying for a second model download.
actor CompactionContinuityEvalRealSubjectRunner: GatedEvalRealModelRunner {
    private var loaded: MLXFoundationModelsContainer?

    /// The tasks this runner's tier measures, in the order the tier states them.
    ///
    /// Held here rather than passed beside the runner at every call site, for
    /// the reason ``CompactionEvalRealSubjectRunner/seeds`` is: one tier cannot
    /// evaluate one task set while its progress lines are read against another.
    private nonisolated let tasks: [CompactionContinuitySeed]

    /// ``tasks``, keyed by the final instruction a running sample carries — the
    /// join that names the task a sample is driving.
    ///
    /// The final instruction is the key the sample already carries into
    /// ``run(steps:finalInstruction:prompt:budget:)``, and it is what
    /// ``CompactionContinuityEvaluation/dataset`` stamps as each sample's own
    /// prompt, so a live line and the tier's own sample list name one task the
    /// same way.
    private nonisolated let tasksByFinalInstruction: [String: CompactionContinuitySeed]

    /// How many samples have entered
    /// ``run(steps:finalInstruction:prompt:budget:)``, including the ones still
    /// running.
    ///
    /// A sample the time limit cut short is counted here and recorded nowhere
    /// else, which is what lets its progress lines state where in the tier it
    /// stood.
    private var startedSampleCount = 0

    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the unused
    /// `.embedding` slot every ``LanguageModelProfile`` built here must still
    /// carry — never exercised, only present to satisfy the type.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        /// The dimension of a vector this container never makes.
        let dimension = 1

        /// Answers with no vectors, because nothing calls this.
        ///
        /// - Parameter texts: The texts to embed. Ignored.
        /// - Returns: An empty array.
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

    /// The model-assisted stage every session this runner vends is created
    /// with.
    ///
    /// A parameter rather than the production default, because the fast tier
    /// needs ``compactionContinuityFastSummarization``'s one-turn recency
    /// window for a three-turn task to fold at all — see that constant.
    private nonisolated let summarization: Summarization

    /// The system instructions every session this runner vends is created
    /// with.
    ///
    /// A parameter for the same reason ``summarization`` is: the instructions
    /// are part of the tier's fixture, and the fast tier states its own — see
    /// ``compactionContinuityFastInstructions`` for the measured run behind
    /// them.
    private nonisolated let instructions: String

    /// Creates a runner over one tier's tasks.
    ///
    /// - Parameters:
    ///   - tasks: The tier's tasks, in the order the tier states them.
    ///   - instructions: The system instructions every session this runner
    ///     vends is created with — see ``instructions``.
    ///   - summarization: The model-assisted stage every session this runner
    ///     vends is created with — see ``summarization``.
    init(tasks: [CompactionContinuitySeed], instructions: String, summarization: Summarization) {
        self.tasks = tasks
        self.tasksByFinalInstruction = CompactionContinuitySeed.keyedByFinalInstruction(tasks)
        self.instructions = instructions
        self.summarization = summarization
    }

    /// The resident container, loading it on first access and caching it for
    /// every later call.
    ///
    /// The load is timed and stated on its own two progress lines by
    /// ``CompactionEvalRealModelContainer/load(samplingMode:unexpectedContainerType:)``,
    /// so it is never charged to the first sample. A tier that spends its whole
    /// limit here leaves the started line and no returned line, which is the
    /// trail ``gatedEvalSuiteTimeLimitMinutes`` exists to bound (task ^aktsp2e).
    ///
    /// - Returns: The cached container, if one was already loaded, or the
    ///   newly-loaded and now-cached container otherwise.
    /// - Throws: ``CompactionContinuityEvaluationError/unexpectedContainerType``
    ///   if the loaded container is not an `MLXFoundationModelsContainer`, or
    ///   whatever error ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``
    ///   throws while resolving/loading ``CompactionEvalRealModel/ref``.
    private func container() async throws -> MLXFoundationModelsContainer {
        if let loaded { return loaded }
        // Decoding is pinned to greedy. The provider default samples at
        // temperature 0.6 from MLX's process-global PRNG, which seeds itself
        // from the clock, so every run of this evaluation drew different
        // answers from identical code — `mean(AnswersCorrect)` measured 0.5,
        // 0.8, and 0.7 across three runs of the same tree, which is a coin
        // flip against a 0.8 threshold rather than a measurement of the prompt
        // under test (task f80n046). Argmax decoding consumes no randomness at
        // all, so a run's score is a fact about the prompt and the fixtures.
        let container = try await CompactionEvalRealModelContainer.load(
            samplingMode: .greedy,
            unexpectedContainerType: CompactionContinuityEvaluationError.unexpectedContainerType
        )
        loaded = container
        return container
    }

    /// Names the sample now entering
    /// ``run(steps:finalInstruction:prompt:budget:)``, and counts it.
    ///
    /// Advances ``startedSampleCount``, so each call names the next position in
    /// the tier. Called once per sample, at the top of its run.
    ///
    /// - Parameter finalInstruction: The final instruction this sample asks,
    ///   which resolves the task it drives.
    /// - Returns: The label every one of this sample's progress lines carries.
    private func makeSampleLabel(forFinalInstruction finalInstruction: String) -> CompactionEvalSampleLabel {
        startedSampleCount += 1
        return CompactionEvalSampleLabel(
            ordinal: startedSampleCount,
            of: tasks.count,
            fixture: .task,
            id: tasksByFinalInstruction[finalInstruction]?.id
        )
    }

    /// Builds a real ``LanguageModelProfile`` directly over `container`, with
    /// a fresh, isolated recording root.
    ///
    /// ## Why this is not `RealModelHarness.make`
    ///
    /// `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`
    /// is the same consolidation. This copy was written when the harness lived
    /// inside the integration test target, where only `@testable import` could
    /// reach the router's then-internal initializers and SwiftPM cannot share
    /// source between two leaf test targets. Task ^cvsh3m9 widened those
    /// initializers to `package` and moved the harness to a plain target, so
    /// the constraint is gone; folding this runner onto the harness is its own
    /// card.
    ///
    /// - Parameters:
    ///   - container: The model that is already loaded and resident.
    ///   - cacheDir: The directory the router caches under.
    ///   - recordingsDir: The directory the router records under.
    /// - Returns: The profile to vend this sample's session from.
    private func buildProfile(
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL
    ) -> LanguageModelProfile {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(
                slot: slot,
                remainingBudgetBytes: 0,
                chosen: CompactionEvalRealModel.ref,
                considered: [],
                contextTokens: CompactionEvalRealModel.context
            )
        }
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: recordingsDir,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: CompactionEvalRealModel.ref,
                    context: noopResolution(slot).contextTokens,
                    recordingLevel: .full,
                    profile: nil,
                    routerId: router.id
                )
            )
        }
        // `.standard` and `.flash` differ only in which slot they're stamped
        // with — both share the same resident `container`, so a single
        // helper builds either from its slot alone. Both therefore take the
        // one gate set that container carries, as they would from a pool
        // entry: two sets would let two generations run inside the one
        // container at once.
        let generationGates = ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        func makeRoutedLLM(_ slot: ModelSlot) -> RoutedLLM {
            RoutedLLM(
                slot: slot,
                chosen: CompactionEvalRealModel.ref,
                footprintBytes: 0,
                resolution: noopResolution(slot),
                container: container,
                routerId: router.id,
                recorder: recorder,
                durableRecording: durableRecording(slot),
                gates: generationGates
            )
        }
        let standard = makeRoutedLLM(.standard)
        let flash = makeRoutedLLM(.flash)
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: CompactionEvalRealModel.ref,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.embedding),
            gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        )
        return LanguageModelProfile(
            definitionName: "compaction-continuity-eval",
            standard: standard,
            flash: flash,
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )
    }

    /// Runs one sample's real subject work (task 4ce0a1k): opens a fresh
    /// session over the resident model vended with `prompt`/`budget`, drives
    /// every one of `steps` through it in order, then asks
    /// `finalInstruction` — counting every APPLIED fold this drives (a
    /// ``SessionEvent/compaction(_:)`` whose `stagesApplied` is not empty),
    /// wherever in the sequence it lands, and reading the session's own
    /// durable recording afterward to report how many entries it actually
    /// persisted. A discarded fold — one of `Compactor`'s shortfall exits —
    /// changed nothing, so it is not counted; see the event handling below.
    ///
    /// Every one of those generations states itself on a
    /// ``CompactionEvalProgressLog`` line as it happens, so a run the suite time
    /// limit cuts short names the sample it stopped in AND the step of that
    /// sample. Nothing else survives such a run: the tier's own outcome is
    /// returned only once every step has finished (task ^aktsp2e).
    ///
    /// - Parameters:
    ///   - steps: The setup/filler steps to send, in order, before
    ///     `finalInstruction`.
    ///   - finalInstruction: The final step, whose reply is `finalAnswer`.
    ///   - prompt: The compaction prompt to vend the session with.
    ///   - budget: The auto-compaction budget to vend the session with.
    /// - Returns: The final answer, the total fold count and last fold's
    ///   token counts (zero if none ran), the durable recording's own
    ///   persisted entry count, and the resolved model's name.
    /// - Throws: Whatever ``container()`` throws while loading the resident
    ///   model, or whatever a step's `streamEvents(to:maxTokens:)` throws.
    func run(
        steps: [String],
        finalInstruction: String,
        prompt: CompactionPrompt,
        budget: TokenBudget
    ) async throws -> (
        finalAnswer: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int, recordedEntryCount: Int,
        modelName: String
    ) {
        let container = try await self.container()
        let label = makeSampleLabel(forFinalInstruction: finalInstruction)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactionContinuityEval-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactionContinuityEval-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let profile = buildProfile(container: container, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let session = profile.standard.makeSession(
            instructions: instructions,
            budget: budget,
            compactionPrompt: prompt,
            summarization: summarization
        )

        // A free function, not a nested closure capturing this method's own
        // mutable locals: a nested closure that both hops across the
        // `session` actor (via `await session.streamEvents`) and mutates
        // this actor-isolated method's own local `var`s trips Swift 6's
        // stricter concurrency checking ("sending risks causing data
        // races") even though every call here is fully sequential — so each
        // step's own fold accounting is returned and folded into the
        // running totals by the caller instead.
        func driveStep(
            _ session: RoutedSession, _ text: String
        ) async throws -> (reply: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int) {
            var reply = ""
            var stepFoldCount = 0
            var stepTokensBefore = 0
            var stepTokensAfter = 0
            let stream = await session.streamEvents(to: text, maxTokens: GatedRealModelBudget.responseTokenCeiling)
            for try await event in stream {
                switch event {
                case .textDelta(let fragment):
                    reply += fragment
                case .compaction(let result):
                    // Only an APPLIED fold counts. `Compactor` reports its
                    // shortfall exits with an empty `stagesApplied` and the
                    // original transcript, and a session still emits the
                    // event for one. Counting those would let `FoldOccurred`
                    // pass on a fold that changed nothing, which is a test
                    // that measures nothing (task ^k0d30s4).
                    // `AutoCompactionTriggerIntegrationTests` applies the
                    // same filter for the same reason.
                    guard !result.stagesApplied.isEmpty else { break }
                    // The summary text, on the trail. A red run cannot tell a
                    // fact the fold dropped from a fact the answering turn
                    // ignored without it — the debugging of 2026-08-19 read
                    // exactly this line to find that 9 of 10 summaries
                    // carried both facts verbatim while the answers did not.
                    print("[compaction-eval] fold summary:\n\(result.summary ?? "<none>")")
                    stepFoldCount += 1
                    stepTokensBefore = result.tokensBefore
                    stepTokensAfter = result.tokensAfter
                default:
                    break
                }
            }
            return (reply, stepFoldCount, stepTokensBefore, stepTokensAfter)
        }

        var foldCount = 0
        var lastTokensBefore = 0
        var lastTokensAfter = 0

        func accumulate(_ stepResult: (reply: String, foldCount: Int, tokensBefore: Int, tokensAfter: Int)) {
            foldCount += stepResult.foldCount
            if stepResult.foldCount > 0 {
                lastTokensBefore = stepResult.tokensBefore
                lastTokensAfter = stepResult.tokensAfter
            }
        }

        // Timed from here rather than from the top of this call, so `elapsed`
        // measures the generations alone. Everything above is one temporary
        // directory and one profile build, which cost nothing a reader of the
        // trail is trying to account for.
        let sampleStartedAt = Date()

        for (offset, step) in steps.enumerated() {
            let stepStartedAt = Date()
            CompactionEvalProgressLog.emit(
                CompactionEvalProgressLog.makeStepStartedLine(
                    .step,
                    sample: label,
                    // The first step has measured nothing yet, so it states no
                    // elapsed clause at all rather than a zero that reads as a
                    // measurement.
                    elapsedSeconds: offset == 0 ? nil : stepStartedAt.timeIntervalSince(sampleStartedAt),
                    detail: CompactionEvalProgressLog.makeStepPositionDetail(ordinal: offset + 1, of: steps.count)
                ))
            let stepResult = try await driveStep(session, step)
            accumulate(stepResult)
            let stepReturnedAt = Date()
            CompactionEvalProgressLog.emit(
                CompactionEvalProgressLog.makeStepReturnedLine(
                    .step,
                    sample: label,
                    elapsedSeconds: stepReturnedAt.timeIntervalSince(sampleStartedAt),
                    stepSeconds: stepReturnedAt.timeIntervalSince(stepStartedAt),
                    detail: CompactionEvalProgressLog.makeDrivenStepDetail(
                        reply: stepResult.reply, foldCount: stepResult.foldCount)
                ))
        }

        let finalStartedAt = Date()
        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeStepStartedLine(
                .finalInstruction,
                sample: label,
                elapsedSeconds: finalStartedAt.timeIntervalSince(sampleStartedAt)
            ))
        let finalStepResult = try await driveStep(session, finalInstruction)
        accumulate(finalStepResult)
        let finalAnswer = finalStepResult.reply
        let finalReturnedAt = Date()
        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeStepReturnedLine(
                .finalInstruction,
                sample: label,
                elapsedSeconds: finalReturnedAt.timeIntervalSince(sampleStartedAt),
                stepSeconds: finalReturnedAt.timeIntervalSince(finalStartedAt),
                detail: CompactionEvalProgressLog.makeDrivenStepDetail(
                    reply: finalAnswer, foldCount: finalStepResult.foldCount)
            ))

        let routerDirectory = recordingsDir.appendingPathComponent(profile.standard.routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let fullHistory = try tree.effectiveTranscript(forSession: session.id, view: .fullHistory)

        return (
            finalAnswer: finalAnswer,
            foldCount: foldCount,
            tokensBefore: lastTokensBefore,
            tokensAfter: lastTokensAfter,
            recordedEntryCount: fullHistory.count,
            modelName: CompactionEvalRealModel.ref.stringValue
        )
    }

    /// Evicts the resident model, if one was ever loaded — called once by
    /// ``GatedEvalResidencyTrait`` as the gated suite ends, however it ended,
    /// mirroring ``CompactionEvalRealSubjectRunner/evictIfLoaded()``.
    func evictIfLoaded() async {
        guard let loaded else { return }
        await loaded.model.evict()
    }
}
