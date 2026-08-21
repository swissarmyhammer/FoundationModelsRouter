import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

/// A blank-slate summarizer over a resident container's model — the same
/// "fresh backend per call, never the live conversation" technique
/// `RoutedSessionActor`'s own (private) `BackendCompactionSummarizer` uses,
/// reimplemented here since that type is private to
/// `Sources/FoundationModelsRouter/Session/RoutedSession.swift` and this
/// target has no `RoutedSession`/`RoutedSessionActor` in play — the eval
/// drives the bare-session recipe (compaction_plan.md §1.5) directly.
///
/// An `actor` rather than a `struct` so it can record its own calls: one fold
/// makes more than one summarizer call when ``Summarization`` chunks a long
/// span into several map calls plus a reduce call, and
/// ``CompactionEvalSampleDiagnostic/summarizerCalls`` reports every one of them
/// with the answer it produced.
private actor BlankSlateSummarizer: CompactionSummarizer {
    /// The resident container every call opens a fresh, empty session over.
    private let container: MLXFoundationModelsContainer

    /// Every call ``summarize(_:maxTokens:)`` completed, in call order.
    ///
    /// Recorded after the model answers, so a call the model failed leaves no
    /// row. That costs the record nothing: the failure propagates out of
    /// `Compactor.compact` and out of ``CompactionEvalRealSubjectRunner/run(entries:prompt:budget:question:)``
    /// before any diagnostic is appended, so no sample ever reads this list
    /// with a failed call missing from it.
    private(set) var calls: [CompactionEvalSummarizerCall] = []

    /// Creates a summarizer over a resident container.
    ///
    /// - Parameter container: The resident container to summarize with.
    init(container: MLXFoundationModelsContainer) {
        self.container = container
    }

    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let answer = try await container.makeSession(transcript: Transcript(entries: []))
            .respond(to: prompt, maxTokens: maxTokens)
        calls.append(CompactionEvalSummarizerCall(maxTokens: maxTokens, answer: answer))
        return answer
    }
}

/// Loads ``CompactionEvalRealModel`` at most once and reuses it across every
/// sample's ``runSubject`` call, so the gated eval's ~24 samples share one
/// resident model instead of reloading per sample.
///
/// An `actor` (not a plain lazy `let`) because loading is `async throws` —
/// exactly the seam that lets ``CompactionEvaluation`` be constructed
/// synchronously (as a `.evaluates(...)` trait argument requires) while the
/// actual load only happens the first time a sample's subject work runs.
actor CompactionEvalRealSubjectRunner: GatedEvalRealModelRunner {
    private var loaded: MLXFoundationModelsContainer?

    /// The seeds this runner's tier measures, in the order the tier states
    /// them.
    ///
    /// Held here rather than passed beside the runner at every call site, so
    /// one tier cannot evaluate one seed set while its progress lines and its
    /// unreached list are read against another. Both the tier's evaluation and
    /// ``expectFactRetention(of:)`` take the set from here.
    ///
    /// `nonisolated` because a `let` of `Sendable` elements is fixed for the
    /// actor's whole life: the evaluation is constructed synchronously, as a
    /// `.evaluates(...)` trait argument requires, long before any `await` on
    /// this actor is possible.
    nonisolated let seeds: [CompactionEvalSeed]

    /// ``seeds``, keyed by the question a recorded sample carries — the join
    /// that names the seed a running sample is measuring.
    private nonisolated let seedsByQuestion: [String: CompactionEvalSeed]

    /// Every sample's recorded `FactRetention` evidence, appended by
    /// ``run(entries:prompt:budget:question:)`` in the order the samples ran.
    private var diagnostics: [CompactionEvalSampleDiagnostic] = []

    /// How many samples have entered ``run(entries:prompt:budget:question:)``,
    /// including the ones still running.
    ///
    /// Counted apart from ``diagnostics``, which holds only the samples that
    /// finished BOTH their fold and their answering turn. A sample the time
    /// limit cut short is counted here and recorded nowhere else, which is what
    /// lets its progress lines state where in the tier it stood.
    private var startedSampleCount = 0

    /// Grants one sample at a time the whole of
    /// ``run(entries:prompt:budget:question:)``, so the tier's dispatch shape
    /// is a decision this runner holds rather than the framework's default.
    ///
    /// `Evaluation.run(info:)` takes no concurrency limit, and task ^23qeprz
    /// holds two gated trails of identical dispatch code: one drove all seven
    /// samples together, and one drove them one at a time. Every per-sample
    /// figure the tier limits rest on (`CompactionEvalTiers.swift`) is read
    /// off one sample's own progress lines, and those figures are clean only
    /// when no other sample runs beside them. The hermetic
    /// `CompactionEvalDispatchShapeTests` states what the framework itself
    /// does today; this permit is what the tier's shape rests on either way.
    ///
    /// This runner is an actor, and an actor method interleaves other calls at
    /// every `await`, so the actor alone cannot hold the shape. The permit is
    /// taken before the sample's label and clock exist, so a wait here is
    /// charged to no sample's own trail.
    private let samplePermit = AsyncSemaphore(value: 1)

    /// Creates a runner over one tier's seeds.
    ///
    /// - Parameter seeds: The tier's seeds, in the order the tier states them.
    init(seeds: [CompactionEvalSeed]) {
        self.seeds = seeds
        self.seedsByQuestion = CompactionEvalSeed.keyedByQuestion(seeds)
    }

    /// The evidence recorded so far, for the gated `@Test` to classify once
    /// the evaluation has finished running every sample.
    ///
    /// - Returns: One record per sample that ran, in sample order.
    func recordedDiagnostics() -> [CompactionEvalSampleDiagnostic] {
        diagnostics
    }

    /// The resident container, loading it on first access and caching it for
    /// every later call.
    ///
    /// The load is timed and stated on its own two progress lines, so it is
    /// never charged to the first sample. A tier that spends its whole limit
    /// here leaves the started line and no returned line, which is the trail
    /// ``compactionEvalSubsetTimeLimitMinutes`` exists to bound and which the
    /// run of 2026-08-18 could not show (task ^h2xxsse).
    ///
    /// - Returns: The cached container, if one was already loaded, or the
    ///   newly-loaded and now-cached container otherwise.
    /// - Throws: ``CompactionEvaluationError/unexpectedContainerType`` if the
    ///   loaded container is not an `MLXFoundationModelsContainer`, or
    ///   whatever error ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``
    ///   throws while resolving/loading ``CompactionEvalRealModel/ref``.
    private func container() async throws -> MLXFoundationModelsContainer {
        if let loaded { return loaded }
        // Decoding is pinned to greedy. The provider default samples at
        // temperature 0.6 from MLX's process-global PRNG, which seeds itself
        // from the clock, so two runs of identical code drew different answers:
        // the runs of 2026-08-17 scored 7 of 7 and 6 of 7 against the same fold
        // code, and the one seed that moved, `env-file`, answered with its key
        // phrase once and refused once.
        //
        // This tier scores a key-phrase search over an answer rather than the
        // answer's exact text, and that was once the reason the pin was left
        // off. It is not a reason: the draw decides whether the model states the
        // phrase at all. Argmax consumes no randomness, so a red run here is a
        // fact about the prompt and the fixtures rather than a coin flip
        // (task ^xscp198).
        let container = try await CompactionEvalRealModelContainer.load(
            ref: CompactionEvalRealModel.ref,
            context: CompactionEvalRealModel.context,
            samplingMode: .greedy,
            unexpectedContainerType: CompactionEvaluationError.unexpectedContainerType)
        loaded = container
        return container
    }

    /// Names the sample now entering ``run(entries:prompt:budget:question:)``,
    /// and counts it.
    ///
    /// Advances ``startedSampleCount``, so each call names the next position in
    /// the tier. Called once per sample, at the top of its run.
    ///
    /// - Parameter question: The question this sample asks, which resolves the
    ///   seed it runs.
    /// - Returns: The label every one of this sample's progress lines carries.
    private func makeSampleLabel(forQuestion question: String) -> CompactionEvalSampleLabel {
        startedSampleCount += 1
        return CompactionEvalSampleLabel(
            ordinal: startedSampleCount,
            of: seeds.count,
            fixture: .seed,
            id: seedsByQuestion[question]?.id
        )
    }

    /// Runs one sample's real subject work (compaction_plan.md §1.4/§1.5's bare-session
    /// recipe): folds `entries` with `prompt`/`budget` via
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``, resumes a live
    /// session over the folded transcript, and asks `question`.
    ///
    /// - Parameters:
    ///   - entries: The seed transcript's entries to fold.
    ///   - prompt: The compaction prompt under test.
    ///   - budget: The token budget to fold against.
    ///   - question: The question to ask the resumed session.
    /// - Returns: The resumed session's answer plus the fold's report.
    /// - Throws: Whatever ``container()`` throws while loading the resident
    ///   model, or whatever ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    ///   or the resumed session's `respond(to:maxTokens:)` throws while
    ///   folding `entries` or answering `question`.
    ///
    /// Also appends this sample's ``CompactionEvalSampleDiagnostic`` to
    /// ``recordedDiagnostics()``. The evaluation's own outcome type carries no
    /// summary text, so without this the gated run cannot tell a fact the fold
    /// dropped from a fact the fold preserved into an answer that ignored it.
    ///
    /// A diagnostic is appended only once BOTH real model calls have returned,
    /// so a sample the suite time limit cut short leaves no record at all. The
    /// ``CompactionEvalProgressLog`` lines emitted around each call are what
    /// that sample does leave: they name it, and they name the call it was
    /// inside when the run stopped.
    func run(
        entries: [Transcript.Entry],
        prompt: CompactionPrompt,
        budget: TokenBudget,
        question: String
    ) async throws -> (answer: String, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String]) {
        // One sample at a time, whatever shape the framework dispatches —
        // see ``samplePermit``. Taken before the label and the clock, so a
        // wait here is charged to no sample's own trail.
        await samplePermit.wait()
        defer { samplePermit.signal() }
        let container = try await self.container()
        let label = makeSampleLabel(forQuestion: question)
        let sampleStartedAt = Date()

        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeStepStartedLine(.fold, sample: label, elapsedSeconds: nil))
        let summarizer = BlankSlateSummarizer(container: container)
        // The summarization cuts `reasoningTokenHeadroom` to the shared eval
        // bound, because the resident model writes no `<think>` block and the
        // default headroom of 8192 is free generation room for it — see
        // `compactionEvalReasoningTokenHeadroom` for the measured runaway
        // folds behind the cut. Every other summarization value stays at its
        // production default, so the fold under test is the production fold.
        let (folded, result) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: budget,
            summarizer: summarizer,
            summarization: Summarization(reasoningTokenHeadroom: compactionEvalReasoningTokenHeadroom)
        )
        let foldReturnedAt = Date()
        let summarizerCalls = await summarizer.calls
        let foldSeconds = foldReturnedAt.timeIntervalSince(sampleStartedAt)
        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeStepReturnedLine(
                .fold,
                sample: label,
                elapsedSeconds: foldSeconds,
                stepSeconds: foldSeconds,
                detail: CompactionEvalProgressLog.makeFoldDetail(
                    stagesApplied: result.stagesApplied, summarizerCalls: summarizerCalls)
            ))

        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeStepStartedLine(
                .answer, sample: label, elapsedSeconds: foldSeconds))
        let answer = try await container.makeSession(transcript: folded)
            .respond(to: question, maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let answerReturnedAt = Date()
        CompactionEvalProgressLog.emit(
            CompactionEvalProgressLog.makeStepReturnedLine(
                .answer,
                sample: label,
                elapsedSeconds: answerReturnedAt.timeIntervalSince(sampleStartedAt),
                stepSeconds: answerReturnedAt.timeIntervalSince(foldReturnedAt),
                detail: CompactionEvalProgressLog.makeAnswerDetail(answer: answer)
            ))

        diagnostics.append(
            CompactionEvalSampleDiagnostic(
                question: question,
                summary: result.summary,
                answer: answer,
                stagesApplied: result.stagesApplied,
                summarizerCalls: summarizerCalls
            )
        )
        return (
            answer: answer,
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            stagesApplied: result.stagesApplied
        )
    }

    /// Evicts the resident model, if one was ever loaded — called once by
    /// ``GatedEvalResidencyTrait`` as the gated suite ends, however it ended,
    /// mirroring every other gated suite's own `container.model.evict()`
    /// teardown.
    func evictIfLoaded() async {
        guard let loaded else { return }
        await loaded.model.evict()
    }
}
