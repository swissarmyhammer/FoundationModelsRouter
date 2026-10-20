---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5d2ws9capqnyg3gd945pcjt
  text: |-
    Implementation landed in the working tree (not committed, per orchestrator).
    - TranscriptEvent + Partial gain optional `tokensCached` (synthesized Codable, nil omitted, old JSONL decodes); threaded through both inits, `with(...)`, `stamped(seq:ts:)`; `stampingUsage` keeps it. `makePartialEvent(tokensCached:)` added. No other field-by-field copies of TranscriptEvent exist under Sources/FoundationModelsRouter/Recording.
    - DocC link fixed: RouterMetrics/recordGenerationCall(tokensIn:tokensCached:tokensOut:duration:model:slot:). The .docc catalog lists no GenerationCallUsage/TranscriptEvent members.
    - cachedInputTokenCount() forwarded in all 18 delegating test backends (HookLayeredLLMContainer + 17 test helpers).
    - journalHoldsEachCall: its first expectation built a GenerationCallUsage without tokensCached and conflicted with the new "(0 cached)" text; passed tokensCached: 0.
    - Discovery: with the scripted executor's per-call updateUsage(cachedTokenCount: 0/130/250), the SDK cumulative `usage.input.cachedTokenCount` sums per-call values, so the ledger delta yields exactly [0,130,250].
    - Open: "Reply to the ACPAgent session with the landing sha" needs a commit; not done here.

    ### implement — changed
    - evidence: swift build --build-tests (0 errors, only the pre-existing SwiftPM "missing creator for mutated node" mlx bundle warning); focused filter 80 tests/8 suites passed; full swift test 1922 tests/237 suites passed (9 pre-existing known issues), plus 26 and 19 test runs passed.
    - next: /review
  timestamp: 2026-10-20T16:39:12.428979+00:00
- actor: claude-code
  id: 01m5d5b808gcm9ta1q5tsfz66r
  text: |-
    ### commit — changed
    - evidence: 5d0b1fa5 pushed to origin/main; sha sent to the ACPAgent session
    - next: review; confirm on the next real MLX bench run
  timestamp: 2026-10-20T17:22:03.400385+00:00
- actor: claude-code
  id: 01m5d9yeacy0dx6qgtnfhbrqb5
  text: |-
    ### review — findings
    - evidence: review sha 5d0b1fa5~1..5d0b1fa5 — 1 finding (1 confirmed, 1 refuted) — Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:323
    - next: add `tokensCached: Int?? = nil` to `TranscriptEvent.with` and use `tokensCached ?? self.tokensCached`; re-review
  timestamp: 2026-10-20T18:42:26.764163+00:00
position_column: done
position_ordinal: ffffffff9b80
title: Carry mlx-swift-lm KV-cache reuse count (cachedTokenCount) through GenerationCallUsage, transcript, and metrics
---
Requested by the FoundationModelsACPAgent session (SWE-bench speed diagnosis).

mlx-swift-lm `stable` (1eb84ff) reports `usage.input.cachedTokenCount = promptCache.reusedTokenCount` (MLXLanguageModel.swift:592-599), with `totalTokenCount = fed + prefilled + reused`. The router reads only `totalTokenCount` (LiveModelLoader.swift ~505 InFlightResponse inputTokens, ~833 usageTokenCounts), so transcripts show "fed ≈ context" and look like ~2% cache reuse even though the cache is hitting.

- [x] Failing test first
- [x] Carry the per-call delta of `cachedTokenCount` into `GenerationCallUsage` as `tokensCached`, and into the transcript `generationCall` record
- [x] Description text: "fed N tokens (M cached), generated ..." — uncached prefill derivable as tokensIn - tokensCached
- [x] Metric `generation.tokens.cached` beside `generation.tokens.in`, same dimensions
- [x] Reply to the ACPAgent session with the landing sha

## Review Findings (2026-10-20 13:31)

> Scope: `review sha 5d0b1fa5~1..5d0b1fa5` — reviewed the diffs only — lines this change added or modified. 26 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:323` `code-hygiene/data-driven` — The `with` function uses `tokensCached` variable without declaring it as a parameter. The function signature (lines 307-311) lists text, tokensIn, tokensOut, and entry as doubly-optional parameters but omits tokensCached, yet line 323 references it in the return statement. Add `tokensCached: Int?? = nil,` as a parameter to the `with` function signature, and change line 323 to `tokensCached: tokensCached ?? self.tokensCached,` to match the pattern used by tokensIn, tokensOut, and text. — **No change needed:** `tokensCached` here is the stored property read through implicit `self`, the same as `routerId`, `ms` and `agentSpawn` in that initializer, so `with` copies it unchanged. No caller overrides it, so it needs no parameter.
