# Plan: Compaction — folding long transcripts inside FoundationModelsRouter

Give any `RoutedSession` — and any bare `LanguageModelSession` over a
`RecordingLanguageModel` handle — a context-window lifecycle: measure how full
the transcript is, and when it approaches the resolved context size, fold the
older conversation into a summary so the session keeps going instead of dying
with `exceededContextWindowSize`. On-device models run at host-budget-fitted
contexts (8k–32k is normal), so agentic sessions hit the ceiling routinely.

This lives **in Router, not a peer package**, because everything compaction
needs is already here: the resolved working context (the budget), measured
token usage from the live backend and the recorded event stamps (the fill —
§1.5), the recording pipeline (persistence), and transcript reconstruction
(restore). Putting it anywhere else would mean injecting all four through
seams; putting it here makes every default real.

Hard requirements:

1. **Compaction is invoked on a `RoutedSession`** with a passed-in compaction
   prompt that has a sensible default (below).
2. **The recorded transcript stays complete.** Recording is append-only;
   compaction never rewrites or discards prior events. Full history remains
   browsable forever.
3. **The compaction entry is a restore checkpoint.** When a session is
   restored from disk, reconstruction treats the newest compaction entry as
   the fold point: the restored live window is the checkpoint's window plus
   everything after it — never the full pre-compaction history.
4. **Compaction never changes the session id.** Same `RoutedSession.id`, same
   transcript directory, same `sessions.jsonl` identity, before and after.

---

## 1. Design

### 1.1 The mechanism: rewrite the window, checkpoint the log

Sessions are stateless over transcripts (verified: every executor call carries
the full transcript), so compaction is a pure function `Transcript →
Transcript` — instructions verbatim, a synthesized summary entry, the recent
tail untouched — after which the owner rebuilds its inner Apple session from
the result. `RoutedSessionActor` **owns** its backend, so `compact()` is an
isolated actor method that swaps the inner session in place: same actor, same
nonisolated `id: ULID`, same recorder — requirement 4 by construction.

### 1.2 `CompactionSegment` — the fold lives in the transcript

The synthesized summary entry carries two segments: a text segment the model
reads as prior context, and a **`CompactionSegment: PersistableCustomSegment`**
whose `Codable` content is the fold metadata:

- the ordered **live-window entry ids** (Apple's `Transcript.Entry.id`s that
  constitute the compacted window),
- the folded entry ids (what the window replaced),
- tokens before/after, the stages applied, and the prompt used (name only).

Because Router's on-disk format mirrors native entries 1:1 — including
`.custom` segments via `SegmentPayload.custom` — recording the fold requires
**zero schema work**: the summary entry appends to the same `transcript.jsonl`
like any other entry. Router registers `CompactionSegment` in its own
`CustomSegmentRegistry` by default, so round-trip needs no consumer setup.

### 1.3 The compactor pipeline

Deterministic first, model-assisted last; stages run in order until the
transcript is under target:

1. **`ToolOutputElision(keepRecentTurns: 4)`** — replace `toolOutput` payloads
   older than the recency window with a one-line placeholder naming the tool.
   Tool traffic is the bulk of an agentic transcript and old outputs are stale
   anyway; this is the near-free win. `toolCalls`/`toolOutput` pairing is
   preserved — only payloads shrink.
2. **`TurnTruncation(keepRecentTurns: 4)`** — drop the oldest complete turns,
   never splitting a turn or orphaning a tool pair. Alone, this is the
   model-free fallback.
3. **`Summarization`** — render the folded span to text, summarize it with the
   compaction prompt (§2), synthesize the summary entry with its
   `CompactionSegment`. Long spans summarize in chunks, then summarize the
   summaries (map-reduce), so the summarizer never overflows its own context.

Invariants, asserted in tests: instructions never modified or dropped; tool
pairs kept/elided/dropped together; the recency window survives verbatim;
deterministic stages are pure; a transcript whose tail alone exceeds target is
returned unchanged with the shortfall reported.

### 1.4 API

```swift
// The session-level entry point — requirement 1.
public protocol RoutedSession {
    // ... existing respond/streamResponse/fork ...

    /// Context fill, 0...1 — measured token usage (§1.5) against the
    /// profile's resolved working context.
    var contextFill: Double { get async }

    /// Folds this session's transcript in place: same id, same recording,
    /// shorter live window. Returns what happened.
    @discardableResult
    func compact(prompt: CompactionPrompt = .default,
                 budget: TokenBudget? = nil) async throws -> CompactionResult
}

public struct CompactionPrompt: Sendable {
    public var name: String            // recorded in the CompactionSegment
    public var text: String
    public static let `default`: CompactionPrompt   // §2
}

public struct TokenBudget: Sendable {
    public var limit: Int              // default: the profile's resolved context
    public var trigger: Double = 0.80  // compact when fill ≥ trigger
    public var target: Double = 0.50   // compact down to ≤ target
}

public struct CompactionResult: Sendable {
    public let summary: String?
    public let tokensBefore: Int
    public let tokensAfter: Int
    public let stagesApplied: [String]
}
```

Defaults are real because this is Router: `budget: nil` means the profile's
resolved working context; the fill numerator is *measured* usage, not an
estimate (§1.5); the summarizer is the session's own model by default, with
the profile's `flash` slot as the recommended override for consumers that
have one resident.

### 1.5 Token accounting — measured, not estimated

Three questions decide whether `contextFill` is real. The precise artifact
throughout is the session's own **`<sessionId>/transcript.jsonl`** — never
"the log" loosely: `sessions.jsonl`, `session.json` sidecars, and
`manifest.json` carry identity and configuration, but the token facts live
(or fail to live) on the `TranscriptEvent` lines of the per-session file, as
the `tokensIn`/`tokensOut` fields of `.response`-kind events.

- **How does a live session know its current token count?** The runtime tells
  it. Apple's `LanguageModelSession` exposes `usage`;
  `LanguageModelSessionBackend.usageTokenCounts()` reads it
  (`usage.input.totalTokenCount` / `usage.output.totalTokenCount`). Because
  models are stateless over transcripts, **the newest turn's input count *is*
  the whole transcript tokenized by the actual model — chat template
  included** — something no external tokenizer pass can match. Current size =
  newest turn's `tokensIn + tokensOut`. Both entry points can measure live:
  `RoutedSessionActor` through its backend, a bare-session owner by reading
  `session.usage` directly.
- **How does it know its total?** The resolved **working context** from
  `JointFit` (caller-fixed `ProfileDefinition.context`, or ladder-derived —
  the sizing already prices KV cache against it). Today that number informs
  sizing and lands in `manifest.json`; this plan exposes it as a property on
  the resolved slot so sessions can read their own denominator.
- **How does it know after restore?** *Only* from stamps persisted in that
  session's `transcript.jsonl` — and here today's two recording paths
  differ, verified against source:
  - `RoutedSessionActor` **does** stamp: it computes per-turn usage deltas
    and writes them as `tokensIn`/`tokensOut` on the diff's `.response`
    events (`recordTranscriptDelta(grammar:since:usage:)`).
  - The `RecordingLanguageModel` handle **does not**: `TranscriptDiffer` is
    deliberately narrow — its doc states turn-specific stamps
    (`grammar`, `ms`, `tokensIn`/`tokensOut`) are *the caller's concern* —
    and no caller on the handle path supplies them, so handle-recorded
    events carry `tokensIn: nil`. The handle also cannot fix this itself:
    it sits below the session and cannot read `session.usage` (the spike
    established its channel view is write-only).

  **The fix is part of this plan**: extend the handle's existing turn-end
  hook to `sync(_ transcript: Transcript, usage: (input: Int, output: Int)?)`.
  The turn owner *does* hold the session and can read `session.usage` — the
  same call site that already syncs the turn-final response now carries the
  turn's usage, and the handle stamps it onto the synced `.response` event.
  With that, both paths persist stamps, and restored fill is: the newest
  stamped `.response` event **after the newest checkpoint** in
  `transcript.jsonl`; if the compaction entry is the newest thing, the
  `CompactionSegment`'s `tokensAfter`; if neither exists (recorded before
  this change, or metadata-stripped), fill is *unknown* — reported as such,
  never guessed — until the restored session's first turn measures it
  exactly.

The only other unmeasured moments: a brand-new session before its first turn
(instructions only — fill ≈ 0), and the *prospective* check that a planned
fold will land under target, where the pipeline uses a character-ratio
estimate calibrated by the measured pre-fold count — safe because the next
real turn re-measures exactly.

**The bare-session path** (a caller not using `RoutedSession` — e.g. the ACP
bridge — drives bare `LanguageModelSession`s over the recording handle
instead; the collapsed `FoundationModelsAgentHarness` loop itself now runs
directly over `RoutedSession`, per §1.6/§1.7 and plan.md's collapse
decision): the
pipeline is exposed as `Compactor.compact(_ transcript:prompt:budget:) ->
CompactionResult` plus **`RecordingLanguageModel.noteCompaction(_ compacted:
Transcript)`** — the handle's differ is count-based append-only, so
`noteCompaction` appends the never-before-recorded entries (by
`Transcript.Entry.id`; payloads already carry `entryId`, so unseen-ness is a
set lookup — this is how the summary entry reaches disk) and resets the diff
baseline. The caller then rebuilds
`LanguageModelSession(model: same handle, tools:, transcript:)`.
`RoutedSessionActor.compact` is implemented on top of exactly these two
primitives — one mechanism, two entry points.

Proactive use (check `contextFill` ≥ `trigger` between turns — turns never
die) is preferred; reactive use (catch `exceededContextWindowSize`, compact
with a lowered target, retry once) is the documented recovery path.

### 1.6 Loop policy: the auto-compaction opt-in (harness plan §5 absorbed)

§1.4/§1.5 above document the proactive/reactive *pattern* as something a
caller drives by hand. `FoundationModelsAgentHarness`'s plan §5 asked for a
loop that owns that policy itself — check fill at each turn, fold
automatically, retry once on overflow — so an agent loop never has to
remember to call `compact()`. At the 2026-07-23 collapse (plan.md's
"Guiding principle: constructor-fed, zero configuration"), that policy
landed directly on `RoutedSession` instead of in a peer package, as an
opt-in per session:

```swift
let session = profile.standard.makeSession(
    tools: myTools,
    budget: TokenBudget(limit: profile.standard.resolution.contextTokens),
    compactionPrompt: .default   // or a domain-specific prompt
)
```

When `budget` is set, every turn (`respond`/`streamResponse`/
`streamEvents`) checks measured `contextFill` against `budget.trigger`
**before** submitting its generate call and folds proactively if it is
already over; if the call still fails with
`LanguageModelError.contextSizeExceeded` (or the mid-turn
`ContextBudgetError.hardCeilingExceeded` from §1.7 below), the session
folds with a lowered target and **retries exactly once** before surfacing
the error — never looping. The retry re-runs the turn's own tool calls, so
non-idempotent side effects can happen twice; the recorded transcript
keeps both attempts, exactly as harness plan §5.1 called out. A session
with no `budget` set never auto-compacts; `compact()` remains the manual,
always-available entry point (e.g. for a `/compact` command upstairs).

### 1.7 Mid-turn strategy: the two in-loop seams (harness plan §5.1 absorbed)

The hard case harness plan §5.1 identified stands regardless of who owns
the loop: Apple's `LanguageModelSession` runs the whole model → tool →
model cycle inside one `respond`/`streamResponse` call, and nothing outside
it regains control until the turn ends — a tool-heavy turn can blow the
window in the middle, where a between-turns check can't reach. Router
guards at the same two seams the harness plan identified, both directly in
`RoutedSessionActor` rather than in an external wrapper a caller would
otherwise have to maintain:

1. **The generate boundary.** Every inner generate call this package
   submits measures fill first; the mid-turn events on `streamEvents`
   report it live, and `TokenBudget.hardCeiling`, when set, fails the call
   fast with `ContextBudgetError.hardCeilingExceeded` instead of submitting
   a doomed generate — deterministic, and folded into the same
   retry-once recovery as a real `contextSizeExceeded`.
2. **Tool outputs**, not prompts, are what blow a turn's window mid-turn.
   `TokenBudget.toolOutputLimit`, when set, caps any single tool's own
   result before it ever reaches the model or gets recorded
   (`ToolOutputCapping`), truncating with an explicit
   `"… [truncated: N of M tokens]"` marker — never silent — and reflecting
   the truncation on `SessionEvent/toolStatus(id:status:summary:)`. This
   replaces the harness's own external `ObservedTool` capping job with a
   seam Router's own tool-instancing pipeline already owns.

Fold-below-the-session — rewriting the transcript forwarded to the model so
it sees a folded window while the session keeps its full one — remains the
parked research question harness plan §5.1 recorded: still not attempted,
because the session's and model's views of history would diverge.

## 2. The default compaction prompt

Researched against the strongest prior art: Claude Code's conversation
summarization prompt (structured numbered sections; exact paths and
identifiers; security-relevant instructions preserved verbatim) and the Claude
platform compaction guidance (completed / in-progress / next steps /
constraints / critical context; summarize before quality degrades — hence the
0.80 trigger). The default:

```
You are compacting an agent conversation into a continuation summary. The
summary will REPLACE the older conversation: whoever continues has no other
memory of it, so anything you omit is lost. Be precise and dense. State only
facts from the conversation — never invent, never infer beyond it.

Structure the summary exactly as:

1. Intent — the user's request(s) and overall goal, in order given.
2. Constraints & decisions — instructions, preferences, and decisions still
   in force. Preserve safety- or security-relevant instructions VERBATIM
   (files or data to avoid, operations not to perform, secret handling).
3. Completed — work finished so far, with concrete outcomes.
4. In progress — what is being worked on right now, and its exact state.
5. Files & code — every file path touched or discussed, with the symbols,
   commands, and short code fragments that matter. Exact paths and names.
6. Errors & fixes — problems encountered and how they were (or were not)
   resolved. Keep failed approaches so they are not repeated.
7. Next steps — the immediate next actions, in order, detailed enough to
   resume without re-deriving them.

No praise, no padding, no meta-commentary. Omit a section only if truly
empty.
```

Consumers pass their own `CompactionPrompt` to specialize (a coding harness
might add "always list test commands"); the prompt's `name` is recorded in the
`CompactionSegment` so evals and browsers can attribute quality to prompts.

## 3. Recording and restore semantics

- **Append-only, complete** (requirement 2): compaction appends the summary
  entry (with its `CompactionSegment`) to the *same* `transcript.jsonl`.
  Nothing before it is touched. Full history is always reconstructable.
- **Checkpoint on restore** (requirement 3): `effectiveTranscript` — which
  already interprets events (it skips failed-turn bodyless closes) — learns
  the segment: the default (restore) view finds the **newest** compaction
  entry and rebuilds the live window from its ordered entry ids plus every
  entry recorded after it. `restoreSessionTree` therefore hands back a
  session that is compacted and under budget. A `fullHistory` option keeps
  every entry in `seq` order for browsers, rendering the compaction entry as
  a fold marker rather than duplicating the summary against what it replaced.
  Repeated compactions nest naturally: only the newest checkpoint governs
  restore; earlier ones are historical markers.
- **Identity** (requirement 4): same `sessionId` on every event, same
  directory, same sidecar. `SessionSidecar` gains an optional compaction
  count so browsers can badge folded sessions.
- The differ baseline reset (`noteCompaction`) keeps post-fold turns recording
  as ordinary appends — no divergence, no double-recording (retained tail
  entries keep their entry ids, so they are recognized as already recorded).

## 4. Example — `Examples/CompactionDemo`

A small executable beside `MultiModelGeneration` proving the loop end to end:

1. Resolve a profile; open a `RoutedSession`.
2. Drive scripted long turns (reading fixture files into the conversation)
   while printing `contextFill` after each — watch it climb.
3. At the 0.80 trigger, call `session.compact()` — print the
   `CompactionResult` (tokens before/after, stages) and the summary text.
4. Continue the conversation; show the model still answers questions about
   pre-fold facts (from the summary) and that `session.id` is unchanged.
5. Restore the session from disk with `restoreSessionTree`; show the restored
   transcript is the checkpointed live window, then print the `fullHistory`
   view to show nothing was lost.

## 5. Testing

Family conventions: swift-testing, hermetic unit tests, real-model tests
gated (`FM_ROUTER_INTEGRATION_TESTS`).

- **Stage unit tests** — fixture transcripts covering every §1.3 invariant,
  plus: compaction entry round-trips through the recording mirror and the
  registry; `noteCompaction` appends exactly the unseen entries and resets
  the baseline; restore view applies the newest checkpoint; full-history view
  retains every event; repeated compactions; session id stable throughout.
- **Fake-model summarization** — scripted model returns canned summaries;
  asserts chunking, prompt assembly (default and custom), and segment
  contents.
- **Gated round-trip** — real model: fill, compact, continue, restore,
  continue again.
- **Evals — Apple's Evaluations framework (WWDC26)**, in a gated
  `FoundationModelsRouterEvals` target. Compaction quality is exactly the
  probabilistic property unit tests cannot pin down: *does the model still
  know what happened before the fold?*

  `CompactionEvaluation` plants facts in the head of long seed transcripts
  ("the API key lives in `.env.example`", "we chose tabs over spaces"),
  compacts with the prompt under test, then asks questions answerable only
  from folded content:

  ```swift
  import Evaluations

  struct CompactionEvaluation: Evaluation {
      // Subject: compact the sample's transcript, resume a session over the
      // result, ask the sample's question — return answer + CompactionResult.
      func subject(from sample: ModelSample<PlantedFacts>) async throws
          -> CompactionOutcome { ... }

      // Dataset: 20–30 hand-written seed transcripts (varied lengths, tool
      // traffic, multiple planted facts), scaled later with SampleGenerator.
      var dataset: ArrayLoader<PlantedFacts> { ... }

      var evaluators: Evaluators {
          let retention = Metric("FactRetention")
          Evaluator { sample, subject in           // quantitative: mechanical
              subject.value.answer.contains(sample.expected.fact)
                  ? retention.passing(rationale: "fact survived the fold")
                  : retention.failing(rationale: subject.value.answer)
          }
          let budget = Metric("UnderTarget")
          Evaluator { _, subject in                // quantitative: mechanical
              subject.value.result.tokensAfter <= subject.value.targetTokens
                  ? budget.passing() : budget.failing()
          }
          ModelJudgeEvaluator(                     // qualitative: judged
              judge: judgeModel,                   // ≥ as capable as subject
              dimensions: [
                  ScoreDimension(description: "Faithfulness — the summary states only facts present in the original conversation", scale: .numeric(fourPoint)),
                  ScoreDimension(description: "Continuability — next steps and constraints survive well enough to resume work", scale: .numeric(fourPoint)),
              ])
      }
  }

  @Test("Compaction retains pre-fold facts", .evaluates(evaluation, info: info))
  func evaluateCompaction() async throws {
      let result = EvaluationContext.current.result
      #expect(result.aggregateValue(.mean(of: factRetention)) >= 0.9)
  }
  ```

  The same evaluation pointed at different `CompactionPrompt`s (the segment
  records the prompt name) is the hill-climbing loop for the default prompt
  itself.

## 6. Build order

1. **Spike**: synthesized `Transcript.Entry` values (summary entry, elision
   placeholders) round-trip through a live session and the recording mirror;
   confirm whether WWDC26 FM ships any native condensing to defer to.

   ### 6.1 Spike findings (task dws80ms)

   **Verdict — native condensing: BUILD, not defer.** Searched the installed
   macOS 27 SDK's `FoundationModels.framework` public interface
   (`.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`) for
   any compaction/condensing primitive:
   `grep -inE "compact|condens|summar|trim|prune|fold|truncat" "$F"` — zero
   matches anywhere in the framework. The only context-window-related surface
   the SDK exposes at all is `LanguageModelSession.contextSize` (a read-only
   `Int`) and the `LanguageModelError.contextSizeExceeded` / deprecated
   `GenerationError.exceededContextWindowSize` failure cases — nothing that
   folds, summarizes, elides, or trims a transcript. There is nothing native
   to defer to or build on top of: this plan's from-scratch design (§1) is
   the only option.

   **Verdict — entry ids: fully controllable at synthesis, and preserved
   through the recording mirror.** The same `.swiftinterface` shows every
   `Transcript.Entry` case's `id` is a settable `var String` supplied at
   construction — `init(id: String = UUID().uuidString, ...)` for
   `.instructions`/`.prompt`/`.response`/`.reasoning`, and a *required*
   no-default `id:` for `.toolCalls`/`.toolOutput`. A synthesized entry can
   therefore carry whatever id the compactor wants — a fresh id for a new
   summary entry, or, deliberately, the *same* id an old `.toolOutput`
   carried, to mark an elision placeholder as replacing it in place rather
   than being an unrelated new entry — exactly what `CompactionSegment`
   (§1.2) depends on, since it references live-window and folded entries *by
   id*. `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift` proves
   the disk half of that dependency: a synthesized summary `.response` entry
   and a synthesized elision-placeholder `.toolOutput` entry (reusing an old
   entry's id) both survive `TranscriptEntryMapper` → `TranscriptEntryPayload`
   → JSONL → `TranscriptTree.effectiveTranscript(forSession:)` with identical
   structure and ids, using nothing beyond the mapper/reconstruction code
   already in place — no production changes were needed for this half.
   `Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift`
   (gated, `FM_ROUTER_INTEGRATION_TESTS`) covers the live-session half: it
   rebuilds a real `LanguageModelSession` via
   `MLXFoundationModelsContainer.makeSession(transcript:)` — the exact factory
   `compact()`/restore will rebuild through — over a transcript containing
   the same synthesized shape, and asserts the turn completes, the model
   recalls a fact planted only in the synthesized summary entry, and the
   synthesized ids are unchanged both immediately after ingest and after the
   turn. (Not executed in the authoring sandbox — a pre-existing MLX
   `default.metallib` load failure blocks *every* gated integration suite
   there, reproduced identically against the already-passing
   `TranscriptReconstructionIntegrationTests`; this is an environment
   limitation of that sandbox, not something this task introduced. The
   hermetic suite above fully covers the recording-mirror half without this
   dependency.)

   **Gotcha for `CompactionSegment` (§1.2) implementers:** none found on the
   hermetic (disk) half. Both synthesis directions (fresh id, reused id)
   round-trip cleanly; there is no observed id-reassignment or collision
   hazard synthesizing entries outside of a real model turn. The live-session
   half of this verdict (whether `LanguageModelSession(transcript:)` itself
   preserves ids on ingest) remains to be empirically confirmed by running
   `CompactionSpikeIntegrationTests` in an environment with working MLX/Metal
   (e.g. CI, which already runs this target's other gated suites).

2. **`CompactionSegment` + registry default registration**; recording
   round-trip tests.
3. **Budget + accounting** (§1.5): expose the resolved working context on the
   resolved slot; `TokenBudget`; `contextFill` from measured usage (live
   backend counts, recorded stamps + `tokensAfter` on restore).
4. **Deterministic stages + `Compactor` pipeline**; invariant tests.
5. **Summarization stage + `CompactionPrompt.default`**; fake-model tests.
6. **`noteCompaction` on the handle; `RoutedSession.compact` on the actor.**
7. **Checkpoint-aware reconstruction**: restore view + `fullHistory` view;
   sidecar compaction count.
8. **`Examples/CompactionDemo`** (§4) + gated round-trip test.
9. **Evals** (§5): `CompactionEvaluation`, prompt hill-climb.
10. **DocC**: the proactive/reactive patterns as the inline example.

## 7. Decisions

- **Harness plan §5/§5.1 loop policy absorbed (2026-07-23 collapse)** — the
  proactive-check/reactive-retry-once policy and the two mid-turn guard
  seams (generate-boundary hard ceiling, tool-output capping) that
  `FoundationModelsAgentHarness` would have implemented over `RoutedSession`
  are implemented directly on it instead (§1.6, §1.7):
  `makeSession(budget:compactionPrompt:)`'s auto-compaction opt-in,
  `TokenBudget.hardCeiling`, and `TokenBudget.toolOutputLimit`. See plan.md's
  "Guiding principle: constructor-fed, zero configuration" for the collapse
  decision itself.
- **In Router, not a peer package** — the budget (resolved working context),
  the fill (measured usage: live backend counts and recorded stamps), the
  persistence (recording mirror), and the restore path (reconstruction) all
  live here; a peer package would inject all four through seams to end up
  with worse defaults.
- **Measured over tokenized** (§1.5) — the runtime's own usage accounting is
  the source of truth for fill (the newest turn's input count is the whole
  transcript, chat template included); recorded `tokensIn`/`tokensOut` stamps
  and the segment's `tokensAfter` carry that truth across restore. External
  tokenizer passes are never load-bearing.
- **One mechanism, two entry points** — `RoutedSession.compact()` (and its
  auto-compaction opt-in, §1.6) for routed sessions (in-place swap inside the
  actor; id unchanged by construction) and `Compactor` + `noteCompaction` for
  bare sessions over the handle (a caller not using `RoutedSession`, e.g. the
  ACP bridge). The routed path is implemented on the bare primitives.
- **The fold lives in the transcript** — `CompactionSegment` makes compaction
  self-describing; the recording mirror persists it with zero schema work,
  and restore reads the checkpoint from data the transcript itself carries.
- **Append-only history, checkpointed restore** — full history is never
  rewritten; only reconstruction's *view* changes. Deleting nothing is what
  makes the session id safe to keep.
- **Deterministic stages before summarization** — tool-output elision does
  most of the work at zero model cost; the model-free pipeline is the
  fallback when no summarizer is available.
- **Prompt is data, recorded by name** — passed-in `CompactionPrompt` with a
  research-backed default; the segment records which prompt produced each
  fold so evals can compare prompts across recorded sessions.
