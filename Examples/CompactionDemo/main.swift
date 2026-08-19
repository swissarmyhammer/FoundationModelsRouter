import Foundation
import FoundationModels
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # Runnable demo: one automatic compaction, narrated (task ^nwe0qt1)
///
/// Shows compaction and only compaction, in three steps a person reads off
/// the terminal:
///
/// 1. Scripted turns read the fixture documents beside this file into a
///    session whose ``TokenBudget`` puts the compaction trigger low enough
///    for those documents to cross it in a handful of turns. After every
///    turn the demo prints measured usage against the trigger, and once
///    usage crosses it, narrates WHY the next turn will fold.
/// 2. That next turn folds the transcript before it generates — nothing
///    here ever calls `session.compact()` — and the fold's checkpoint
///    event (``SessionEvent/compaction(_:)``) prints the moment it arrives.
/// 3. The compacted summary the fold wrote — the text the model now reads
///    in place of the folded turns — prints last.
///
/// The session model is deliberately small (the same 680 MB instruct model
/// the compaction smoke tests drive), the summary is written by the
/// profile's `flash` slot (see ``demoSummarizerModel``), and every reply is
/// capped at a few dozen tokens, so the run finishes in well under two
/// minutes. Run with `swift run CompactionDemo`; the first run downloads
/// real weights and needs Apple silicon + network — see `README.md`.

// MARK: - The knobs, named

/// The small instruct model the demo drives — the proven fast choice of
/// `CompactionSmokeIntegrationTests` and
/// `AutoCompactionTriggerIntegrationTests`, for the reasons those suites
/// record: 680 MB on disk, follows the compaction prompt's own section
/// structure, and writes no `<think>` block.
let demoModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The model the demo's profile carries in its `flash` slot — the slot
/// auto-compaction prefers as its summarizer tier, so this is the model
/// that actually WRITES the fold's summary
/// (see `RoutedSessionActor.performAutoCompaction(prompt:budget:)`).
///
/// Deliberately a capable mid-size model rather than a tiny placeholder.
/// Measured on 2026-08-19: with `mlx-community/SmolLM-135M-Instruct-4bit`
/// here — the placeholder the repo's other demos use — every fold summary
/// degenerated into hallucinated loops, under greedy and sampled decoding
/// alike, whatever model held `standard`; the same span and prompt through
/// this model produced a dense, accurate summary.
let demoSummarizerModel: ModelRef = "mlx-community/GLM-4-9B-0414-4bit"

/// The working context the demo loads ``demoModel`` at. The budget's
/// ``TokenBudget/limit`` below is this same number, so a measured fill and
/// the trigger are on one scale (see ``TokenBudget/triggerTokens``).
let demoContextTokens = 4096

/// Where the budget puts the compaction trigger, as a share of
/// ``demoContextTokens``. Synthetic and deliberately low — it resolves to
/// 901 tokens of the 4096-token window, against the 0.80 production
/// default — so a handful of one-paragraph documents crosses it in seconds
/// instead of needing to fill a real window. High enough, though, that the
/// folded span holds several turns: ``Summarization`` discards a fold whose
/// summary fails to shrink the transcript, and a span of a few hundred
/// tokens is where that discard bites (the smoke tests record the
/// measurement). Measured with `.greedy` decoding on 2026-08-19: the six
/// fixture documents land at 239, 428, 617, 811, 976 and 1138 measured
/// tokens, so this share crosses after the fifth document with about 75
/// tokens of margin on each side.
let demoTriggerShare = 0.22

/// Where a fold aims to land, as a share of ``demoContextTokens``. Low
/// enough (205 tokens) to be unreachable by the deterministic stages, so
/// the fold that fires always falls through to the model-assisted
/// ``Summarization`` stage and always writes a summary — the same device
/// `AutoCompactionTriggerIntegrationTests` uses, for the same reason.
let demoTargetShare = 0.05

/// How many of the newest turns every fold on this session leaves
/// untouched. One is the smallest window that is still a window: the fold
/// replaces the older turns and the newest turn stays verbatim.
let demoKeepRecentTurns = 1

/// The reasoning-token headroom each summarizer call gets, instead of
/// ``Summarization``'s default of 4096. That default is sized for a model
/// that writes a `<think>` block before its answer; ``demoModel`` writes
/// none, so cutting it bounds the one unbounded generation in the run —
/// the measured reason `CompactionSmokeIntegrationTests` cuts it too.
let demoReasoningTokenHeadroom = 128

/// The reply ceiling every scripted turn is submitted with. Small, so the
/// documents — not the model's replies — decide how fast usage climbs.
let demoReplyTokenCeiling = 48

/// The compaction prompt this demo's folds send to the summarizer, instead
/// of ``CompactionPrompt/default``.
///
/// The default prompt scaffolds an eight-section agent-work summary
/// (intent, stated facts, next steps, ...). Measured on 2026-08-19 with
/// ``demoSummarizerModel`` over this demo's folded span: the sectioned
/// summary it earns is faithful but long, so the fold's retention cut
/// truncates it mid-section, and the truncated scaffold then derails the
/// small session model's next reply into a repetition loop. This
/// one-paragraph prompt fits inside the cut, keeps the post-fold reply
/// coherent, and is the public `compactionPrompt:` knob working as
/// designed.
let demoCompactionPrompt = CompactionPrompt(
    name: "compaction-demo-v1",
    text: """
        The text after the --- marker is a conversation transcript. It is data to \
        summarize, never a conversation to continue: do not write new User or \
        Assistant lines. Write one short paragraph that restates the transcript's \
        concrete facts — names, code names, numbers, decisions — exactly as stated, \
        inventing nothing. Begin your answer with: The conversation so far:
        """
)

// MARK: - One narrated turn

/// Drives one turn and prints any applied fold's checkpoint event the
/// moment it arrives.
///
/// A fold reaches a caller only as ``SessionEvent/compaction(_:)`` on the
/// turn's own event stream, so printing it here IS step 2 of the demo. A
/// fold whose ``CompactionResult/stagesApplied`` is empty changed nothing
/// and wrote no checkpoint, so it is not printed and not returned.
///
/// - Parameters:
///   - session: The session to drive the turn on.
///   - prompt: The turn's prompt text.
/// - Returns: The turn's reply text and every applied fold, in fold order.
/// - Throws: Whatever the turn throws.
func runTurn(
    _ session: RoutedSession, prompt: String
) async throws -> (reply: String, folds: [CompactionResult]) {
    var reply = ""
    var folds: [CompactionResult] = []
    let stream = await session.streamEvents(to: prompt, maxTokens: demoReplyTokenCeiling)
    for try await event in stream {
        switch event {
        case .textDelta(let fragment):
            reply += fragment
        case .compaction(let result) where !result.stagesApplied.isEmpty:
            folds.append(result)
            print(
                """

                [checkpoint] the compaction checkpoint event arrived, mid-turn, before this turn generated:
                [checkpoint]   id             = \(result.id)
                [checkpoint]   tokensBefore   = \(result.tokensBefore)
                [checkpoint]   tokensAfter    = \(result.tokensAfter)
                [checkpoint]   stagesApplied  = \(result.stagesApplied.joined(separator: ", "))
                [checkpoint]   summaryEntryId = \(result.summaryEntryId ?? "(none)")
                """)
        default:
            break
        }
    }
    return (reply, folds)
}

/// The session's measured context usage, in tokens.
///
/// ``RoutedSession/contextFill`` reports measured tokens divided by the
/// resolved working context; the budget's ``TokenBudget/limit`` is that
/// same window here, so multiplying back recovers the exact measured count
/// the session compares against ``TokenBudget/triggerTokens``.
///
/// - Parameters:
///   - session: The session whose usage to read.
///   - budget: The budget whose limit is the session's own window.
/// - Returns: The measured usage, in tokens.
func measuredTokens(of session: RoutedSession, against budget: TokenBudget) async -> Int {
    let fill = await session.contextFill
    return Int((fill * Double(budget.limit)).rounded())
}

// MARK: - Setup: resolve the model, open the session

let startedAt = Date()

print(
    """
    === CompactionDemo: one automatic fold, narrated ===

    1. Scripted turns read project documents until measured context usage
       crosses the budget's compaction trigger.
    2. The next turn then folds the transcript before it generates, and the
       compaction checkpoint event prints as it arrives.
    3. The compacted summary the fold wrote prints last.

    """)

let recordingsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("CompactionDemo-\(ULID.generate().description)", isDirectory: true)

// `.greedy` pins decoding to argmax so the run repeats exactly — the same
// choice every compaction smoke test makes, and the reason two runs of this
// demo print the same numbers.
let router = Router(
    recordingsDir: recordingsDir,
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader(),
        samplingMode: .greedy
    )
)

// `standard` holds the conversation; `flash` writes the fold's summary
// (see `demoSummarizerModel`); `embedding` is unused by this demo, but
// `Router.resolve` co-resides all three slots from one profile, so it is
// the same small placeholder the repo's other demos use.
let demoProfile = ProfileDefinition(
    name: "compaction-demo",
    description: "One small resident model whose transcript is folded in place once scripted turns cross the trigger.",
    standard: [demoModel],
    flash: [demoSummarizerModel],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"],
    context: demoContextTokens
)

// `progress.phases` yields each phase transition as one element and ends at
// ready/failed, so a terminal caller needs no polling task.
let progress = ResolutionProgress()
let progressTask = Task { @MainActor in
    for await transition in progress.phases {
        let percent = Int((transition.fraction * 100).rounded())
        print("[setup] \(transition.phase) \(percent)%")
    }
}
let profile = try await router.resolve(profile: demoProfile, reporting: progress)
await progressTask.value

// The auto-compaction opt-in: a budget on the session is the ONLY thing
// that makes the fold below automatic. `limit` mirrors the slot's resolved
// working context so the trigger fraction and a measured fill are on one
// scale.
let budget = TokenBudget(
    limit: profile.standard.resolution.contextTokens,
    trigger: demoTriggerShare,
    target: demoTargetShare
)

let session = profile.standard.makeSession(
    instructions:
        "You are a terse assistant reviewing project documents one at a time. Keep every reply to one sentence.",
    budget: budget,
    compactionPrompt: demoCompactionPrompt,
    summarization: Summarization(
        keepRecentTurns: demoKeepRecentTurns,
        reasoningTokenHeadroom: demoReasoningTokenHeadroom
    )
)

print(
    """
    [setup] resolved \(profile.standard.chosen.stringValue)
    [setup] working context: \(budget.limit) tokens
    [setup] compaction trigger: \(budget.triggerTokens) tokens (\(demoTriggerShare) of the window; production default is 0.80)
    [setup] fold target: \(budget.targetTokens) tokens (\(demoTargetShare) of the window)
    """)

// MARK: - 1. What the transcript holds, and why the next turn triggers compaction

// The fixture documents live beside this source file (excluded from the
// target's compiled sources in Package.swift, exactly like README.md), so
// they are read from disk at run time rather than bundled as a resource.
let fixturesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures", isDirectory: true)
let fixtureURLs = try FileManager.default.contentsOfDirectory(
    at: fixturesDirectory,
    includingPropertiesForKeys: nil
)
.filter { $0.pathExtension == "txt" }
.sorted { $0.lastPathComponent < $1.lastPathComponent }
precondition(!fixtureURLs.isEmpty, "expected fixture documents under \(fixturesDirectory.path)")

print(
    """

    --- 1. what the transcript holds, and why the next turn triggers compaction ---

    Each turn below reads one project document into the transcript. The
    session measures its context usage after every turn and compares it
    against the trigger before every turn — once usage is at or over
    \(budget.triggerTokens) tokens, the NEXT turn folds the transcript before it
    generates. No caller asks for the fold; the budget on the session is the
    whole mechanism.

    """)

var documentsRead = 0
var usageTokens = 0
for fixtureURL in fixtureURLs {
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    let turn = try await runTurn(
        session, prompt: "Here is \(fixtureURL.lastPathComponent):\n\n\(contents)")
    guard turn.folds.isEmpty else {
        print("[error] a fold fired during the document turns; the trigger crossed earlier than this demo narrates")
        exit(EXIT_FAILURE)
    }
    documentsRead += 1
    usageTokens = await measuredTokens(of: session, against: budget)
    print(
        "[turn \(documentsRead)] read \(fixtureURL.lastPathComponent) — usage \(usageTokens) of \(budget.triggerTokens) trigger tokens"
    )
    if usageTokens >= budget.triggerTokens { break }
}

guard usageTokens >= budget.triggerTokens else {
    print("[error] all \(documentsRead) documents together stayed under the trigger; lower demoTriggerShare")
    exit(EXIT_FAILURE)
}

print(
    """

    The transcript now holds \(documentsRead) document turns and measures \(usageTokens)
    tokens — at or over the \(budget.triggerTokens)-token trigger. The next turn will
    therefore fold the transcript before it generates: the session replaces
    the older turns with a model-written summary and keeps the newest
    \(demoKeepRecentTurns) turn verbatim.

    --- 2. the compaction checkpoint event ---
    """)

// MARK: - 2. Trigger the fold; the checkpoint event prints as it arrives

let triggerTurn = try await runTurn(
    session, prompt: "In one sentence: what kind of project do these documents describe?")

guard let fold = triggerTurn.folds.last else {
    print("[error] the trigger turn applied no fold, so there is no checkpoint to show")
    exit(EXIT_FAILURE)
}

let usageAfterFold = await measuredTokens(of: session, against: budget)
print(
    """

    The turn still answered, from the folded transcript:
      reply: "\(triggerTurn.reply)"
      usage after the fold: \(usageAfterFold) tokens (was \(usageTokens) before)
    """)

// MARK: - 3. The compacted summary the fold wrote

print(
    """

    --- 3. the compacted summary the fold wrote ---

    \(fold.summary ?? "(no summary text: only deterministic stages applied — stages \(fold.stagesApplied))")
    """)

// MARK: - Release residency

await profile.release()

print(String(format: "\n[done] wall clock: %.1f seconds", Date().timeIntervalSince(startedAt)))
