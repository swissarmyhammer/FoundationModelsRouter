import Foundation
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # Runnable demo: multi-model generation, observed end to end.
///
/// One observation story, from resolve to reply. `Router.resolve` makes two
/// generation models co-resident at once, reporting each resolution phase
/// through ``ResolutionProgress/phases``; the program then routes a cheap
/// triage turn to `profile.flash` and a heavyweight turn to
/// `profile.standard`, reading BOTH turns off
/// ``RoutedSession/streamEvents(to:maxTokens:)``
/// so the named ``SessionEvent`` cases print as they arrive — `turnStarted`,
/// the `textDelta` fragments, `entryRecorded`, and `turnEnded` with measured
/// token usage.
///
/// The routing is the live counterpart of
/// `ExamplesTests.multiModelDirectGeneration()` — the same two-model
/// resolve-and-route — driven here through session event observation
/// instead of awaited final strings.
///
/// Run with `swift run MultiModelGeneration`. It downloads real weights on
/// first run and needs Apple silicon + network — see `README.md`. Every reply
/// is capped at ``demoReplyTokenCeiling`` tokens, so the run finishes in
/// under two minutes.

// MARK: - One observed turn

/// The reply ceiling every observed turn is submitted with.
///
/// Load-bearing for the demo's wall clock: SmolLM-135M in `flash` rambles to
/// the model's own 8192-token default ceiling when nothing caps it (measured
/// on 2026-08-19: that one uncapped triage turn put the whole run at 121.7
/// seconds). Both real answers fit comfortably inside this cap — the triage
/// wants one word, and the measured `standard` reply ran 59 tokens.
let demoReplyTokenCeiling = 160

/// Drives one turn through ``RoutedSession/streamEvents(to:maxTokens:)``,
/// capped at ``demoReplyTokenCeiling``, and prints each named
/// ``SessionEvent`` case as it arrives.
///
/// Both turns below run through this one helper, so the flash triage and the
/// standard reply read as one observed session flow. Four cases carry a
/// plain text turn, in this order:
///
/// - ``SessionEvent/turnStarted(_:)`` opens the turn's correlation frame.
/// - ``SessionEvent/textDelta(_:)`` fragments print as the model produces
///   them and accumulate into the reply this function returns.
///   ``SessionEvent/textReset`` clears that accumulation — the documented
///   consumer rule — so the returned reply is character for character the
///   string ``RoutedSession/respond(to:)`` would have returned.
/// - ``SessionEvent/entryRecorded(id:kind:)`` closes the recorded transcript
///   entry under its durable SDK id once the turn's diff runs.
/// - ``SessionEvent/turnEnded(_:)`` closes the turn with measured
///   ``TokenUsage``.
///
/// The remaining cases stay silent by construction: these sessions carry no
/// tools, no `budget:`, and no discovery priming, so the tool-lifecycle,
/// compaction, and priming events never fire, and a stall report would only
/// say the machine is busy.
///
/// - Parameters:
///   - session: The session to drive the turn on.
///   - label: The slot name printed before each event line.
///   - prompt: The turn's prompt text.
/// - Returns: The turn's accumulated reply text.
/// - Throws: Whatever the turn throws.
func runObservedTurn(
    on session: RoutedSession, label: String, prompt: String
) async throws -> String {
    var reply = ""
    var midFragmentBlock = false

    // The textDelta fragments print inline with no per-fragment prefix, so
    // the next named event closes their block with one newline first.
    func closeFragmentBlock() {
        guard midFragmentBlock else { return }
        print()
        midFragmentBlock = false
    }

    for try await event in await session.streamEvents(to: prompt, maxTokens: demoReplyTokenCeiling) {
        switch event {
        case .turnStarted(let start):
            print("[\(label)] turnStarted turn=\(start.turnId)")
        case .textDelta(let fragment):
            if !midFragmentBlock {
                print("[\(label)] textDelta fragments:")
                midFragmentBlock = true
            }
            print(fragment, terminator: "")
            reply += fragment
        case .textReset:
            closeFragmentBlock()
            print("[\(label)] textReset — the fragments so far are superseded")
            reply = ""
        case .entryRecorded(let id, let kind):
            closeFragmentBlock()
            print("[\(label)] entryRecorded kind=\(kind) id=\(id)")
        case .turnEnded(let usage):
            closeFragmentBlock()
            let percent = Int((usage.contextFill * 100).rounded())
            print(
                "[\(label)] turnEnded tokensIn=\(usage.tokensIn) tokensOut=\(usage.tokensOut) contextFill=\(percent)%"
            )
        case .reasoningDelta, .toolCall, .toolStatus, .toolInvocation,
            .compaction, .discoveryPrimingFailed, .generationStalled:
            // Silent by construction — see this function's documentation.
            break
        }
    }
    return reply
}

// MARK: - Live router

let startedAt = Date()

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
//
// SmolLM-135M in `flash` is safe here ONLY because no session in this demo
// opts into auto-compaction with a `budget:`. Auto-compaction prefers the
// `flash` slot as its summarizer, and this model is too small to summarize —
// see the summary quality hazard on
// `RoutedSessionActor.performAutoCompaction(prompt:budget:)` (task ^59fd9rt).
// A demo that adds a `budget:` must also put a capable model into `flash`,
// as `CompactionDemo` does.
let demo = ProfileDefinition(
    name: "multi-model-demo",
    description: "Flash triages, standard answers — two co-resident models from one resolve.",
    standard: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    flash: ["mlx-community/SmolLM-135M-Instruct-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"]
)

// MARK: - Resolve once, observing progress

// `ResolutionProgress` is `@Observable`; a SwiftUI view binds to it directly.
// `progress.phases` is the same progress as an AsyncSequence for a terminal:
// each phase transition arrives as one element — sizing -> downloading ->
// loading -> ready — and the sequence ends at ready/failed. The resolve runs
// as a structured `async let` child while this top-level code prints each
// transition, so the observation starts here and simply continues, per turn,
// once the sessions below generate.
let progress = ResolutionProgress()
async let resolvedProfile = router.resolve(profile: demo, reporting: progress)
for await transition in progress.phases {
    let percent = Int((transition.fraction * 100).rounded())
    print("[resolve] phase=\(transition.phase) fraction=\(percent)%")
}
let profile = try await resolvedProfile

print(
    """
    Resolved "\(profile.definitionName)":
      standard = \(profile.standard.chosen.stringValue)
      flash    = \(profile.flash.chosen.stringValue)
    """
)

// MARK: - Cheap triage on `flash`, observed

// Route the light classification work to the small, fast model, and read the
// turn off its own event stream instead of awaiting a final string.
let triage = profile.flash.makeSession(
    instructions: "Classify the support ticket into one category word."
)
print("\n[flash] session on \(profile.flash.chosen.stringValue)")
let category = try await runObservedTurn(
    on: triage,
    label: "flash",
    prompt: "My Q3 invoice has a discrepancy in the refund total."
)

// MARK: - Heavyweight answer on `standard`, observed

// Route the full, considered response to the larger resident model — the same
// observed flow, so its fragments print as they arrive.
let answer = profile.standard.makeSession(
    instructions: "You are a support agent. Write a helpful, precise reply."
)
print("\n[standard] session on \(profile.standard.chosen.stringValue)")
_ = try await runObservedTurn(
    on: answer,
    label: "standard",
    prompt: "Explain our \(category) policy for the customer's Q3 invoice."
)

// MARK: - Release residency

// Frees both resident models and the router's residency slot.
await profile.release()

print(String(format: "\n[done] wall clock: %.1f seconds", Date().timeIntervalSince(startedAt)))
