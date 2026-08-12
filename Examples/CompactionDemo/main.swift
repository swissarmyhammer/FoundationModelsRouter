import Foundation
import FoundationModels
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # Runnable demo: the compaction loop, end to end, with real tool traffic
/// (compaction_plan.md §4, task 4ce0a1k).
///
/// Proves the whole fold-and-restore loop against a real, resident model,
/// with genuine tool-call traffic in the mix: resolve a profile, open a
/// `RoutedSession` vended with sample tools (`SampleTools.swift`) and a tiny
/// `TokenBudget` (task 8213x39's auto-compaction opt-in), drive scripted
/// turns — some plain fixture reads, some explicit tool calls — while
/// `contextFill` climbs, let the budget fold the transcript automatically
/// once it crosses the 0.80 trigger (no caller-side `session.compact()`
/// polling), keep talking to the same session — same `id`, and it still
/// recalls a fact planted only in the folded span, from the compaction
/// summary, and can still call a tool to look it up — then restore the
/// session from disk and show the restored transcript is the checkpointed
/// live window, followed by the `fullHistory` view proving nothing was
/// actually lost.
///
/// This is a human-run demo, not a test: nothing here is asserted, only
/// printed for a person reading the terminal. The gated
/// `CompactionRoundTripIntegrationTests` (`FM_ROUTER_INTEGRATION_TESTS`)
/// asserts the same five steps mechanically, with real measured token
/// counts, against a real model.
///
/// Run with `swift run CompactionDemo`. It downloads real weights on first
/// run and needs Apple silicon + network — see `README.md`.

// MARK: - Live event printing

/// Prints one raw `SessionEvent` as the turn produces it — the `observing`
/// callback every demo turn passes to `session.respond(to:observing:)`.
///
/// The demo folds nothing itself: `respond(to:observing:)` owns the event
/// fold (task ^1s8p8qt) — the reply assembly with the `textReset` rule, the
/// compactions the turn folded, and the closing usage all come back on its
/// `TurnOutcome`. What remains here is only what a person reading the
/// terminal wants to see live: the turn frame, tool traffic (both the live
/// invocation records and the diff-derived calls), any auto-compaction fold
/// the session's budget triggers, and a priming report.
@Sendable func printLiveEvent(_ event: SessionEvent) {
    switch event {
    case .turnStarted(let start):
        // The correlation frame every later event of this turn belongs to.
        // This turn's prompt came straight from the caller, so it names no
        // queued prompt.
        print("[turn] \(start.turnId) started")
    case .toolCall(let id, let name, let argumentsJSON):
        print("[tool] call \(name) (\(id)): \(argumentsJSON)")
    case .toolStatus(let id, let status, let summary):
        print("[tool] \(id) -> \(status)\(summary.map { ": \($0)" } ?? "")")
    case .toolInvocation(let record):
        // The live signal: the open record arrives while the tool still
        // runs, the close record when its call returned — before the
        // diff-derived `.toolCall`/`.toolStatus` above (see
        // `SessionEvent.toolInvocation(_:)`).
        let state = record.closedAt == nil ? "running" : "finished"
        print("[tool] \(record.tool) \(state) (run \(record.correlationID))")
    case .compaction(let result):
        print(
            """
            [auto-compact] tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) \
            stagesApplied=\(result.stagesApplied)
            """)
    case .discoveryPrimingFailed(let failure):
        print("[priming] could not seed this turn: \(failure)")
    case .textDelta, .textReset, .reasoningDelta, .entryRecorded, .turnEnded:
        // Already folded into the returned `TurnOutcome` (the reply text and
        // closing usage), or identity bookkeeping this demo does not print:
        // the recorded-entry closes exist for consumers (like
        // `SessionProjection`) that key rows on durable SDK entry ids.
        break
    }
}

// MARK: - Live router

let recordingsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("CompactionDemo-\(UUID().uuidString)", isDirectory: true)

let router = Router(
    recordingsDir: recordingsDir,
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader()
    )
)

// MARK: - Author a profile with a deliberately small working context

// A small `context` means the handful of scripted fixture turns below is
// enough to cross the 0.80 compaction trigger without needing enormous
// documents — the point here is the fold mechanics, not the size of what
// triggers it. `flash`/`embedding` are unused by this demo (compaction only
// ever runs against `standard`), but `Router.resolve` co-resides all three
// slots from one profile, so they're the same small placeholders
// `MultiModelGeneration` already uses.
// The deliberately small working context the section comment above explains.
let demoContextTokens = 2048

let demo = ProfileDefinition(
    name: "compaction-demo",
    description: "One resident model with a small working context, folded in place once scripted turns fill it.",
    standard: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    flash: ["mlx-community/SmolLM-135M-Instruct-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"],
    context: demoContextTokens
)

// MARK: - Resolve once, watching progress

// How long the progress poller sleeps between phase checks.
let progressPollMilliseconds = 200

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
            try? await Task.sleep(for: .milliseconds(progressPollMilliseconds))
        }
    }
}

let profile = try await router.resolve(profile: demo, reporting: progress)
progressTask.cancel()

print("Resolved \"\(profile.definitionName)\": standard = \(profile.standard.chosen.stringValue)")

// MARK: - 1. Resolve a profile; open a RoutedSession with tools + a tiny auto-compaction budget

// The sample tools (`SampleTools.swift`) this session can call: a document
// generator for on-demand context pressure, and a fact-store pair the model
// records into before the fold and recalls from after it.
let factStore = FactStore()
let tools: [any FoundationModels.Tool] = [
    DocumentGeneratorTool(), RecordFactTool(store: factStore), RecallFactTool(store: factStore),
]

// `budget.limit` mirrors the slot's own resolved working context (task
// 8213x39's convention: normally a profile's resolved `contextTokens`) so
// auto-compaction folds proactively, with no caller-side `compact()` call
// anywhere in this demo, once a turn's measured fill crosses `trigger`.

// The fill fraction at which the budget folds, and the fraction a fold aims
// to land under — the same 0.80 trigger the demo's own doc comment names.
let compactionTriggerFill = 0.80
let compactionTargetFill = 0.30

let budget = TokenBudget(
    limit: profile.standard.resolution.contextTokens,
    trigger: compactionTriggerFill,
    target: compactionTargetFill
)

let session = profile.standard.makeSession(
    instructions: "You are a terse assistant reviewing project documents one at a time. Use the tools you are given exactly when asked to.",
    tools: tools,
    budget: budget
)

// MARK: - 2. Plant a fact via a tool call, then generate on-demand pressure, then read fixture documents

let recordAck = try await session.respond(
    to: """
        Call the record_fact tool with key "project-codename" and value "CRIMSON-77" to remember this \
        project's internal code name, then reply with a one-sentence acknowledgement.
        """,
    observing: printLiveEvent
)
.reply
print("[turn] recorded fact via tool — reply=\"\(recordAck)\"")

var observedCompactions: [CompactionResult] = []

// Read by the `observedCompactions` accumulation and the print two lines down;
// periphery cannot see reads of top-level bindings in a script target.
// periphery:ignore
let docOutcome = try await session.respond(
    to: """
        Call the generate_document tool with topic "appendix" and paragraphs 6 to fetch some background \
        material, then reply with a one-sentence summary of it.
        """,
    observing: printLiveEvent
)
observedCompactions += docOutcome.compactions
print(
    "[turn] generated appendix document via tool — contextFill=\(String(format: "%.2f", docOutcome.contextFill ?? 0)) reply=\"\(docOutcome.reply)\""
)

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

for fixtureURL in fixtureURLs {
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    let outcome = try await session.respond(
        to: "Here is \(fixtureURL.lastPathComponent):\n\n\(contents)", observing: printLiveEvent)
    observedCompactions += outcome.compactions
    print(
        "[turn] read \(fixtureURL.lastPathComponent) — contextFill=\(String(format: "%.2f", outcome.contextFill ?? 0)) reply=\"\(outcome.reply)\""
    )
}

// MARK: - 3. The budget should have folded automatically by now; force it if not

// A demo run by hand isn't guaranteed to cross the trigger organically — real
// tokenization and fixture sizes vary — so force the fold here if the loop
// above never reached it, guaranteeing every run demonstrates steps 3-5
// regardless. This explicit fold is independent of the session's own
// auto-compaction budget (`RoutedSession/compact()` always uses its own
// default trigger/target), so it composes safely with whatever the budget
// already did above.
let result: CompactionResult
if let alreadyCompacted = observedCompactions.last {
    result = alreadyCompacted
} else {
    result = try await session.compact()
}

print(
    """
    [compact] tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) \
    stagesApplied=\(result.stagesApplied)
    [compact] summary:
    \(result.summary ?? "(no summarizer stage ran — the deterministic stages alone landed under target)")
    """
)

// MARK: - 4. Continue the conversation: pre-fold facts survive, both conversationally and via tool; session.id is unchanged

let sessionIdBeforeContinuation = session.id
let recall = try await session.respond(
    to: "Without re-reading anything, what is this project's internal code name?",
    observing: printLiveEvent
)
.reply
print("[post-compact] recall: \"\(recall)\"")

let toolRecall = try await session.respond(
    to: """
        Without re-reading anything, call the recall_fact tool with key "project-codename", then reply \
        with just its value.
        """,
    observing: printLiveEvent
)
.reply
print("[post-compact] recall via tool: \"\(toolRecall)\"")
print("[identity] session.id unchanged: \(session.id == sessionIdBeforeContinuation)")

// MARK: - 5. Restore from disk: the checkpointed live window, then the full history

let restoredTree = try await profile.standard.restoreSessionTree(root: session.id, tools: tools)
let restoredSession = restoredTree.root
print(
    "[restore] restored session id: \(restoredSession.id) (same as original: \(restoredSession.id == session.id))"
)

let routerDirectory = recordingsDir.appendingPathComponent(
    profile.standard.routerId.description, isDirectory: true)
let tree = try TranscriptTree.load(under: routerDirectory)

let checkpointedWindow = try tree.effectiveTranscript(forSession: session.id)
print("[restore] checkpointed live window entry count: \(checkpointedWindow.count)")

let fullHistory = try tree.effectiveTranscript(forSession: session.id, view: .fullHistory)
print("[restore] fullHistory entry count (nothing lost): \(fullHistory.count)")

// A live turn on the restored session, calling the same tool the original
// session used, proves it is genuinely usable — with its tools still
// wired — not just structurally reconstructed.
let restoredReply = try await restoredSession.respond(
    to: "Call the recall_fact tool with key \"project-codename\", then reply with just its value.")
print("[restore] live turn on the restored session: \"\(restoredReply)\"")

// MARK: - Release residency

await profile.release()
