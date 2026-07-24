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

// MARK: - Event-driven turn helper

/// Drives one turn through `session.streamEvents(to:)`, printing tool calls
/// and any auto-compaction folds the session's budget triggers along the
/// way, and returning the assembled reply text, the resulting `contextFill`,
/// and every `CompactionResult` this turn's fold(s) produced.
///
/// A plain `session.respond(to:)` can't observe this: auto-compaction folds
/// silently *inside* a turn (task 8213x39) rather than returning a
/// `CompactionResult` its caller can inspect directly — `streamEvents`'s
/// `SessionEvent/compaction(_:)` case is the only way to see it happen live.
///
/// - Parameters:
///   - session: The session to drive.
///   - prompt: The user turn to send.
/// - Returns: The assembled reply text, the contextFill measured as this
///   turn closed, and every compaction this turn's own fold(s) produced (in
///   order; empty if the budget never triggered during this turn).
func runTurn(
    _ session: RoutedSession, prompt: String
) async throws -> (reply: String, fill: Double, compactions: [CompactionResult]) {
    var reply = ""
    var fill: Double = 0
    var compactions: [CompactionResult] = []
    let stream = await session.streamEvents(to: prompt)
    for try await event in stream {
        switch event {
        case .textDelta(let fragment):
            reply += fragment
        case .toolCall(let id, let name, let argumentsJSON):
            print("[tool] call \(name) (\(id)): \(argumentsJSON)")
        case .toolStatus(let id, let status, let summary):
            print("[tool] \(id) -> \(status)\(summary.map { ": \($0)" } ?? "")")
        case .compaction(let result):
            compactions.append(result)
            print(
                """
                [auto-compact] tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) \
                stagesApplied=\(result.stagesApplied)
                """)
        case .reasoningDelta:
            break
        case .turnEnded(let usage):
            fill = usage.contextFill
        }
    }
    return (reply, fill, compactions)
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
let demo = ProfileDefinition(
    name: "compaction-demo",
    description: "One resident model with a small working context, folded in place once scripted turns fill it.",
    standard: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    flash: ["mlx-community/SmolLM-135M-Instruct-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"],
    context: 2048
)

// MARK: - Resolve once, watching progress

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
let budget = TokenBudget(limit: profile.standard.resolution.contextTokens, trigger: 0.80, target: 0.30)

let session = profile.standard.makeSession(
    instructions: "You are a terse assistant reviewing project documents one at a time. Use the tools you are given exactly when asked to.",
    tools: tools,
    budget: budget
)

// MARK: - 2. Plant a fact via a tool call, then generate on-demand pressure, then read fixture documents

let (recordAck, _, _) = try await runTurn(
    session,
    prompt: """
        Call the record_fact tool with key "project-codename" and value "CRIMSON-77" to remember this \
        project's internal code name, then reply with a one-sentence acknowledgement.
        """
)
print("[turn] recorded fact via tool — reply=\"\(recordAck)\"")

var observedCompactions: [CompactionResult] = []

let (docReply, docFill, docCompactions) = try await runTurn(
    session,
    prompt: """
        Call the generate_document tool with topic "appendix" and paragraphs 6 to fetch some background \
        material, then reply with a one-sentence summary of it.
        """
)
observedCompactions += docCompactions
print("[turn] generated appendix document via tool — contextFill=\(String(format: "%.2f", docFill)) reply=\"\(docReply)\"")

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
    let (reply, fill, compactions) = try await runTurn(
        session, prompt: "Here is \(fixtureURL.lastPathComponent):\n\n\(contents)")
    observedCompactions += compactions
    print(
        "[turn] read \(fixtureURL.lastPathComponent) — contextFill=\(String(format: "%.2f", fill)) reply=\"\(reply)\""
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
let (recall, _, _) = try await runTurn(
    session,
    prompt: "Without re-reading anything, what is this project's internal code name?"
)
print("[post-compact] recall: \"\(recall)\"")

let (toolRecall, _, _) = try await runTurn(
    session,
    prompt: """
        Without re-reading anything, call the recall_fact tool with key "project-codename", then reply \
        with just its value.
        """
)
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
