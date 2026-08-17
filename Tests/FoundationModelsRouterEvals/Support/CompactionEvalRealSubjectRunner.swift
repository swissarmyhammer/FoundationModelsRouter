import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

@testable import FoundationModelsRouter

/// The real (non-tiny) `mlx-community` model the gated eval resolves against
/// actual hardware — the same model `RealModels.standard` names for the gated
/// integration suite, so this target exercises genuinely capable multi-turn
/// recall rather than a toy model.
enum CompactionEvalRealModel {
    /// The `mlx-community/Muse-Glimmer-30B-4bit` HuggingFace model reference
    /// this runner resolves, the general substitute for the Qwen3.6 model
    /// this eval used before — see `RealModels` in the integration target for
    /// why Qwen lost prompt caching and Muse Glimmer keeps it.
    static let ref: ModelRef = "mlx-community/Muse-Glimmer-30B-4bit"

    /// The maximum context window, in tokens, to load ``ref`` with — passed
    /// straight through to ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``.
    static let context = 8192
}

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

    /// Every sample's recorded `FactRetention` evidence, appended by
    /// ``run(entries:prompt:budget:question:)`` in the order the samples ran.
    private var diagnostics: [CompactionEvalSampleDiagnostic] = []

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
    /// - Returns: The cached container, if one was already loaded, or the
    ///   newly-loaded and now-cached container otherwise.
    /// - Throws: ``CompactionEvaluationError/unexpectedContainerType`` if the
    ///   loaded container is not an `MLXFoundationModelsContainer`, or
    ///   whatever error ``LiveModelLoader/loadLLM(ref:slot:context:reporting:)``
    ///   throws while resolving/loading ``CompactionEvalRealModel/ref``.
    private func container() async throws -> MLXFoundationModelsContainer {
        if let loaded { return loaded }
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let container = try await loader.loadLLM(
            ref: CompactionEvalRealModel.ref,
            slot: .standard,
            context: CompactionEvalRealModel.context,
            reporting: { _ in }
        )
        guard let mlxContainer = container as? MLXFoundationModelsContainer else {
            throw CompactionEvaluationError.unexpectedContainerType
        }
        loaded = mlxContainer
        return mlxContainer
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
    func run(
        entries: [Transcript.Entry],
        prompt: CompactionPrompt,
        budget: TokenBudget,
        question: String
    ) async throws -> (answer: String, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String]) {
        let container = try await self.container()
        let summarizer = BlankSlateSummarizer(container: container)
        let (folded, result) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: budget,
            summarizer: summarizer
        )
        let answer = try await container.makeSession(transcript: folded)
            .respond(to: question, maxTokens: GatedRealModelBudget.responseTokenCeiling)
        diagnostics.append(
            CompactionEvalSampleDiagnostic(
                question: question,
                summary: result.summary,
                answer: answer,
                stagesApplied: result.stagesApplied,
                summarizerCalls: await summarizer.calls
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
