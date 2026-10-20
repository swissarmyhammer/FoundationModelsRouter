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
position_column: doing
position_ordinal: '80'
title: Carry mlx-swift-lm KV-cache reuse count (cachedTokenCount) through GenerationCallUsage, transcript, and metrics
---
Requested by the FoundationModelsACPAgent session (SWE-bench speed diagnosis).

mlx-swift-lm `stable` (1eb84ff) reports `usage.input.cachedTokenCount = promptCache.reusedTokenCount` (MLXLanguageModel.swift:592-599), with `totalTokenCount = fed + prefilled + reused`. The router reads only `totalTokenCount` (LiveModelLoader.swift ~505 InFlightResponse inputTokens, ~833 usageTokenCounts), so transcripts show "fed ≈ context" and look like ~2% cache reuse even though the cache is hitting.

- [ ] Failing test first
- [ ] Carry the per-call delta of `cachedTokenCount` into `GenerationCallUsage` as `tokensCached`, and into the transcript `generationCall` record
- [ ] Description text: "fed N tokens (M cached), generated ..." — uncached prefill derivable as tokensIn - tokensCached
- [ ] Metric `generation.tokens.cached` beside `generation.tokens.in`, same dimensions
- [ ] Reply to the ACPAgent session with the landing sha