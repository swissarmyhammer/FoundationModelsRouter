import Foundation
import FoundationModels
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # Runnable demo: the compaction loop, end to end (compaction_plan.md §4).
///
/// Proves the whole fold-and-restore loop against a real, resident model:
/// resolve a profile, open a `RoutedSession`, drive scripted turns that read
/// fixture documents into the conversation while `contextFill` climbs, fold
/// the transcript with `session.compact()` once it crosses the 0.80 trigger,
/// keep talking to the same session — same `id`, and it still recalls a fact
/// planted only in the folded span, from the compaction summary — then
/// restore the session from disk and show the restored transcript is the
/// checkpointed live window, followed by the `fullHistory` view proving
/// nothing was actually lost.
///
/// This is a human-run demo, not a test: nothing here is asserted, only
/// printed for a person reading the terminal. The gated
/// `CompactionRoundTripIntegrationTests` (`FM_ROUTER_INTEGRATION_TESTS`)
/// asserts the same five steps mechanically, with real measured token
/// counts, against a real model.
///
/// Run with `swift run CompactionDemo`. It downloads real weights on first
/// run and needs Apple silicon + network — see `README.md`.

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

// MARK: - 1. Resolve a profile; open a RoutedSession

let session = profile.standard.makeSession(
    instructions: "You are a terse assistant reviewing project documents one at a time."
)

// MARK: - 2. Drive scripted long turns, reading fixture files into the conversation

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

var compactionResult: CompactionResult?

for fixtureURL in fixtureURLs {
    let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
    let reply = try await session.respond(
        to: "Here is \(fixtureURL.lastPathComponent):\n\n\(contents)"
    )
    let fill = await session.contextFill
    print(
        "[turn] read \(fixtureURL.lastPathComponent) — contextFill=\(String(format: "%.2f", fill)) reply=\"\(reply)\""
    )

    // MARK: - 3. At the 0.80 trigger, fold the transcript in place
    if compactionResult == nil, fill >= 0.80 {
        compactionResult = try await session.compact()
    }
}

// A demo run by hand isn't guaranteed to cross the trigger organically — real
// tokenization and fixture sizes vary — so force the fold here if the loop
// above never reached it, guaranteeing every run demonstrates steps 3-5
// regardless.
let result: CompactionResult
if let alreadyCompacted = compactionResult {
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

// MARK: - 4. Continue the conversation: pre-fold facts survive; session.id is unchanged

let sessionIdBeforeContinuation = session.id
let recall = try await session.respond(
    to: "Without re-reading anything, what is this project's internal code name?"
)
print("[post-compact] recall: \"\(recall)\"")
print("[identity] session.id unchanged: \(session.id == sessionIdBeforeContinuation)")

// MARK: - 5. Restore from disk: the checkpointed live window, then the full history

let restoredTree = try await profile.standard.restoreSessionTree(root: session.id)
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

// A live turn on the restored session proves it is genuinely usable, not
// just structurally reconstructed.
let restoredReply = try await restoredSession.respond(to: "Reply with just the word \"restored\".")
print("[restore] live turn on the restored session: \"\(restoredReply)\"")

// MARK: - Release residency

await profile.release()
