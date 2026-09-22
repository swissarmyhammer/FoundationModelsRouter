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
///    usage crosses it, narrates WHY the next turn will compact.
/// 2. That next turn compacts the transcript before it generates — nothing
///    here ever calls `session.compact()` — and the compaction's checkpoint
///    event (``SessionEvent/compaction(_:)``) prints the moment it arrives.
/// 3. The compacted summary the compaction wrote — the text the model now reads
///    in place of the compacted turns — prints last.
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
/// that actually WRITES the compaction's summary
/// (see `RoutedSessionActor.performAutoCompaction(prompt:budget:)`).
///
/// Deliberately a capable mid-size model rather than a tiny placeholder.
/// Measured on 2026-08-19: with `mlx-community/SmolLM-135M-Instruct-4bit`
/// here — the placeholder the repo's other demos use — every compaction summary
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
/// live context holds several turns: the compaction discards a summary that
/// fails to shrink the live context. Measured with `.greedy` decoding on
/// 2026-08-19: the six fixture documents land at 239, 428, 617, 811, 976 and
/// 1138 measured tokens, so this share crosses after the fifth document with
/// about 75 tokens of margin on each side.
let demoTriggerShare = 0.22

/// Where a compaction aims to land, as a share of ``demoContextTokens``: 205
/// tokens. The summary gets the room this target leaves after the
/// instructions, and the compaction states that room to the summarizer.
let demoTargetShare = 0.05

/// The reply ceiling every scripted turn is submitted with. Small, so the
/// documents — not the model's replies — decide how fast usage climbs.
let demoReplyTokenCeiling = 48

/// The compaction prompt this demo's compactions send to the summarizer, instead
/// of ``CompactionPrompt/default``.
///
/// The default prompt scaffolds an eight-section agent-work summary
/// (intent, stated facts, next steps, ...). Measured on 2026-08-19 with
/// ``demoSummarizerModel`` over this demo's compacted span: the sectioned
/// summary it earns is faithful but long, and the long scaffold then derails
/// the small session model's next reply into a repetition loop. This
/// one-paragraph prompt keeps the post-compaction reply coherent, and is the
/// public `compactionPrompt:` knob working as designed.
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

/// Drives one turn through the library's own event compaction —
/// ``RoutedSession/respond(to:maxTokens:observing:)`` — and prints any
/// applied compaction's checkpoint event the moment it arrives.
///
/// A compaction reaches a caller only as ``SessionEvent/compaction(_:)`` on the
/// turn's own event stream, so printing it from the `observing` callback IS
/// step 2 of the demo. A compaction whose ``CompactionResult/stagesApplied`` is
/// empty changed nothing and wrote no checkpoint, so it is not printed and
/// not returned.
///
/// - Parameters:
///   - session: The session to drive the turn on.
///   - prompt: The turn's prompt text.
/// - Returns: The turn's reply text and every applied compaction, in compaction order.
/// - Throws: Whatever the turn throws.
func runTurn(
    on session: RoutedSession, prompt: String
) async throws -> (reply: String, compactions: [CompactionResult]) {
    let outcome = try await session.respond(to: prompt, maxTokens: demoReplyTokenCeiling) { event in
        guard case .compaction(let result) = event, !result.stagesApplied.isEmpty else { return }
        // swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
        print(
            """

            [checkpoint] the compaction checkpoint event arrived, mid-turn, before this turn generated:
            [checkpoint]   id             = \(result.id)
            [checkpoint]   tokensBefore   = \(result.tokensBefore)
            [checkpoint]   tokensAfter    = \(result.tokensAfter)
            [checkpoint]   stagesApplied  = \(result.stagesApplied.joined(separator: ", "))
            [checkpoint]   summaryEntryId = \(result.summaryEntryId ?? "(none)")
            [checkpoint]   summarizerModel = \(result.summarizerModel ?? "(none)")
            """)
    }
    return (outcome.reply, outcome.compactions.filter { !$0.stagesApplied.isEmpty })
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

// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(
    """
    === CompactionDemo: one automatic compaction, narrated ===

    1. Scripted turns read project documents until measured context usage
       crosses the budget's compaction trigger.
    2. The next turn then compacts the transcript before it generates, and the
       compaction checkpoint event prints as it arrives.
    3. The compacted summary the compaction wrote prints last.

    """)

let recordingsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("CompactionDemo-\(ULID.generate().description)", isDirectory: true)

// `.greedy` pins decoding to argmax so the run repeats exactly — the same
// choice every compaction smoke test makes, and the reason two runs of this
// demo print the same numbers. The router carries the mode, not the loader:
// a loaded container serves every router in the pool, and the mode belongs
// to the router (`model-pool.md` §2.5).
let router = Router(
    recordingsDir: recordingsDir,
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader()
    ),
    samplingMode: .greedy
)

// `standard` holds the conversation; `flash` writes the compaction's summary
// (see `demoSummarizerModel`); `embedding` is unused by this demo, but
// `Router.resolve` co-resides all three slots from one profile, so it is
// the same small placeholder the repo's other demos use.
let demoProfile = ProfileDefinition(
    name: "compaction-demo",
    description: "One small resident model whose transcript is compacted in place once scripted turns cross the trigger.",
    standard: [demoModel],
    flash: [demoSummarizerModel],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"],
    context: demoContextTokens
)

// `progress.phases` yields each phase transition as one element and ends at
// ready/failed, so the resolve runs as a structured `async let` child while
// this top-level code prints each transition — no stored task handle.
let progress = ResolutionProgress()
async let resolvedProfile = router.resolve(profile: demoProfile, reporting: progress)
for await transition in progress.phases {
    let percent = Int((transition.fraction * 100).rounded())
    // swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
    print("[setup] \(transition.phase) \(percent)%")
}
let profile = try await resolvedProfile

// The auto-compaction opt-in: a budget on the session is the ONLY thing
// that makes the compaction below automatic. `limit` mirrors the slot's resolved
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
    compactionPrompt: demoCompactionPrompt
)

// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(
    """
    [setup] resolved \(profile.standard.chosen.stringValue)
    [setup] working context: \(budget.limit) tokens
    [setup] compaction trigger: \(budget.triggerTokens) tokens (\(demoTriggerShare) of the window; production default is 0.80)
    [setup] compaction target: \(budget.targetTokens) tokens (\(demoTargetShare) of the window)
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

// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(
    """

    --- 1. what the transcript holds, and why the next turn triggers compaction ---

    Each turn below reads one project document into the transcript. The
    session measures its context usage after every turn and compares it
    against the trigger before every turn — once usage is at or over
    \(budget.triggerTokens) tokens, the NEXT turn compacts the transcript before it
    generates. No caller asks for the compaction; the budget on the session is the
    whole mechanism.

    """)

var documentsRead = 0
var usageTokens = 0
for fixtureURL in fixtureURLs {
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    let turn = try await runTurn(
        on: session, prompt: "Here is \(fixtureURL.lastPathComponent):\n\n\(contents)")
    guard turn.compactions.isEmpty else {
        // swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
        print("[error] a compaction fired during the document turns; the trigger crossed earlier than this demo narrates")
        exit(EXIT_FAILURE)
    }
    documentsRead += 1
    usageTokens = await measuredTokens(of: session, against: budget)
    // swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
    print(
        "[turn \(documentsRead)] read \(fixtureURL.lastPathComponent) — usage \(usageTokens) of \(budget.triggerTokens) trigger tokens"
    )
    if usageTokens >= budget.triggerTokens { break }
}

guard usageTokens >= budget.triggerTokens else {
    // swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
    print("[error] all \(documentsRead) documents together stayed under the trigger; lower demoTriggerShare")
    exit(EXIT_FAILURE)
}

// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(
    """

    The transcript now holds \(documentsRead) document turns and measures \(usageTokens)
    tokens — at or over the \(budget.triggerTokens)-token trigger. The next turn will
    therefore compact the transcript before it generates: one summarizer call
    reads the whole live context, and the session restarts the live context
    as the instructions and the model-written summary.

    --- 2. the compaction checkpoint event ---
    """)

// MARK: - 2. Trigger the compaction; the checkpoint event prints as it arrives

let triggerTurn = try await runTurn(
    on: session, prompt: "In one sentence: what kind of project do these documents describe?")

guard let compaction = triggerTurn.compactions.last else {
    // swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
    print("[error] the trigger turn applied no compaction, so there is no checkpoint to show")
    exit(EXIT_FAILURE)
}

let usageAfterCompaction = await measuredTokens(of: session, against: budget)
// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(
    """

    The turn still answered, from the compacted transcript:
      reply: "\(triggerTurn.reply)"
      usage after the compaction: \(usageAfterCompaction) tokens (was \(usageTokens) before)
    """)

// MARK: - 3. The compacted summary the compaction wrote

// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(
    """

    --- 3. the compacted summary the compaction wrote ---

    \(compaction.summary ?? "(no summary text)")
    """)
// swiftlint:disable:next no_direct_standard_out_logs  the demo narrates on standard out; that is its output
print(String(format: "\n[done] wall clock: %.1f seconds", Date().timeIntervalSince(startedAt)))
