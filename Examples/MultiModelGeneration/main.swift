import Foundation
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # Runnable demo: multi-model direct generation.
///
/// This is the live twin of `ExamplesTests.multiModelDirectGeneration()` — same
/// call pattern, real models. One `Router.resolve` makes two generation models
/// co-resident at once; the program then routes a cheap triage turn to
/// `profile.flash` and a heavyweight turn to `profile.standard`, streaming the
/// latter fragment by fragment.
///
/// Run with `swift run MultiModelGeneration`. It downloads real weights on
/// first run and needs Apple silicon + network — see `README.md`.

// MARK: - Live router

// In production you build a `Router` with a durable `recordingsDir` and a
// `LiveModelLoader` configured with a real `Downloader`/`TokenizerLoader`. The
// `MLXHuggingFace` macros `#hubDownloader()` / `#huggingFaceTokenizerLoader()`
// expand to code that supplies both, backed by the `HuggingFace` and
// `Tokenizers` packages linked into this target.
let recordingsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("MultiModelGeneration-\(UUID().uuidString)", isDirectory: true)

let router = Router(
    recordingsDir: recordingsDir,
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader()
    )
)

// MARK: - Author a profile with two distinct generation models

// Deliberately small, distinct model refs per generation slot so both co-fit
// comfortably and the multi-model point is visible: `flash` and `standard`
// really are two different resident models, not the same one reused.
let demo = ProfileDefinition(
    name: "multi-model-demo",
    description: "Flash triages, standard answers — two co-resident models from one resolve.",
    standard: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    flash: ["mlx-community/SmolLM-135M-Instruct-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"]
)

// MARK: - Resolve once, watching progress

// `ResolutionProgress` is `@Observable`; a SwiftUI view binds to it directly.
// Here a background task polls it and prints each phase transition so a
// first-time user watching this run in a terminal sees
// sizing -> downloading -> loading -> ready, plus the overall fraction.
let progress = ResolutionProgress()

let progressTask = Task { @MainActor in
    var lastPhase: ResolutionProgress.Phase?
    while !Task.isCancelled {
        if progress.phase != lastPhase {
            let percent = Int((progress.fraction * 100).rounded())
            print("[resolve] phase=\(progress.phase) fraction=\(percent)%")
            lastPhase = progress.phase
        }
        switch progress.phase {
        case .ready, .failed:
            return
        default:
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

let profile = try await router.resolve(demo, reporting: progress)
progressTask.cancel()

print(
    """
    Resolved "\(profile.definitionName)":
      standard = \(profile.standard.chosen.stringValue)
      flash    = \(profile.flash.chosen.stringValue)
    """
)

// MARK: - Cheap triage on `flash`

// Route the light classification work to the small, fast model.
let triage = profile.flash.makeSession(
    instructions: "Classify the support ticket into one category word."
)
let category = try await triage.respond(
    to: "My Q3 invoice has a discrepancy in the refund total."
)
print("\n[flash · \(profile.flash.chosen.stringValue)] category: \(category)")

// MARK: - Heavyweight answer on `standard`, streamed

// Route the full, considered response to the larger resident model, printing
// fragments as they arrive.
let answer = profile.standard.makeSession(
    instructions: "You are a support agent. Write a helpful, precise reply."
)
print("\n[standard · \(profile.standard.chosen.stringValue)] reply:")
for try await fragment in await answer.streamResponse(
    to: "Explain our \(category) policy for the customer's Q3 invoice."
) {
    print(fragment, terminator: "")
}
print()

// MARK: - Release residency

// Frees both resident models and the router's residency slot.
await profile.release()
