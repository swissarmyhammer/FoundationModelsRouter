import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

@testable import FoundationModelsRouter

/// The real (non-tiny) `mlx-community` model the gated eval resolves against
/// actual hardware — the same dense causal LM
/// `CompactionRoundTripIntegrationTests` uses as its own `.standard` slot, so
/// this target exercises genuinely capable multi-turn recall rather than a
/// toy model.
enum CompactionEvalRealModel {
    /// The `mlx-community/Qwen3.6-27B-mxfp4` HuggingFace model reference this
    /// runner resolves — see this enum's own doc comment for why that
    /// specific dense causal LM was chosen over a toy model.
    static let ref: ModelRef = "mlx-community/Qwen3.6-27B-mxfp4"
    static let context = 8192
}

/// A blank-slate summarizer over a resident container's model — the same
/// "fresh backend per call, never the live conversation" technique
/// `RoutedSessionActor`'s own (private) `BackendCompactionSummarizer` uses,
/// reimplemented here since that type is private to
/// `Sources/FoundationModelsRouter/Session/RoutedSession.swift` and this
/// target has no `RoutedSession`/`RoutedSessionActor` in play — the eval
/// drives the bare-session recipe (compaction_plan.md §1.5) directly.
private struct BlankSlateSummarizer: CompactionSummarizer {
    let container: MLXFoundationModelsContainer

    func summarize(_ prompt: String) async throws -> String {
        try await container.makeSession(transcript: Transcript(entries: [])).respond(to: prompt, maxTokens: nil)
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
actor CompactionEvalRealSubjectRunner {
    private var loaded: MLXFoundationModelsContainer?

    /// The resident container, loading it on first access and caching it for
    /// every later call.
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
    /// ``Compactor/compact(_:prompt:budget:summarizer:)``, resumes a live
    /// session over the folded transcript, and asks `question`.
    ///
    /// - Parameters:
    ///   - entries: The seed transcript's entries to fold.
    ///   - prompt: The compaction prompt under test.
    ///   - budget: The token budget to fold against.
    ///   - question: The question to ask the resumed session.
    /// - Returns: The resumed session's answer plus the fold's report.
    func run(
        entries: [Transcript.Entry],
        prompt: CompactionPrompt,
        budget: TokenBudget,
        question: String
    ) async throws -> (answer: String, tokensBefore: Int, tokensAfter: Int, stagesApplied: [String]) {
        let container = try await self.container()
        let (folded, result) = try await Compactor.compact(
            Transcript(entries: entries),
            prompt: prompt,
            budget: budget,
            summarizer: BlankSlateSummarizer(container: container)
        )
        let answer = try await container.makeSession(transcript: folded)
            .respond(to: question, maxTokens: 64)
        return (
            answer: answer,
            tokensBefore: result.tokensBefore,
            tokensAfter: result.tokensAfter,
            stagesApplied: result.stagesApplied
        )
    }

    /// Evicts the resident model, if one was ever loaded — called once after
    /// the gated `@Test` has read its ``EvaluationResult``, mirroring every
    /// other gated suite's own `container.model.evict()` teardown.
    func evictIfLoaded() async {
        guard let loaded else { return }
        await loaded.model.evict()
    }
}
