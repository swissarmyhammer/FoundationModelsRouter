---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dhyt2hj0g0m1essj4mzw9e
  text: 'Step record: RED tests RouterMetricsTests.tokensPerSecondDividesByTheDecodeTime and WatchStopUsageTests.reasoningStopSpanCarriesTheStoppedCallTokens (failed 4202 vs 4160, 0 vs 150). RouterMetrics.recordGenerationCall now takes timing and records out / decodeTime only. endSubmission puts the submission usage on the span; measuredRender param removed. tokens.out 0 answer: a bug, see the card body. swift build --build-tests clean; swift test 1929 passed, 9 known issues; 26 and 19 in the other targets.'
  timestamp: 2026-10-20T21:02:27.409703+00:00
- actor: claude-code
  id: 01m5f020ss5pebkk6qgs5yk5vr
  text: |-
    ### review — stuck
    - evidence: review sha e6aff13b~1..e6aff13b — 0 findings (14 attempted, 0 failed); tool rule code-hygiene/dead-code-swift could not run: build fails at HEAD, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:1030 "extra argument 'cacheDirectory' in call"
    - next: a person fixes the HEAD build (later commit 9ef5750b), then re-runs the review; task stays in review
  timestamp: 2026-10-21T10:28:07.097070+00:00
- actor: claude-code
  id: 01m5f2jrpg6v4p2eef37y5hjva
  text: |-
    ### review — clean
    - evidence: `review sha e6aff13b~1..e6aff13b` with validators [code-hygiene] gave findings 0, attempted 7, failed 0. code-hygiene/dead-code-swift ran and judged the change. The blocker was a stale local Package.resolved that pinned FoundationModelsExtras at a63ddda, which has no MLXModelLoader(cacheDirectory:). `swift package update FoundationModelsExtras` moved it to 6670bc0. Package.resolved is gitignored (c5bd4d69), so this fix needs no commit. No code change on this card.
    - next: card can move on from review
  timestamp: 2026-10-21T11:12:13.008436+00:00
position_column: review
position_ordinal: '8280'
title: generation.tokens_per_second divides by decode time only
---
From foundationmodelsacpagent-a5, bench run telemetry-16. generation.tokens_per_second goes from 0.56 to 51.8. The low values look like out / (prefill + decode), or a time that includes tool time. Make it out / decode time, or rename it to say what it divides by. Also check: the first submission span (submission.id 1, 155.8 s) has tokens.in 5077 and tokens.out 0 — is 0 correct?

- [x] Failing test first
- [x] tokens_per_second = out / decode time (or the name says what it divides by)
- [x] Explain or fix tokens.out 0 on the first submission span

## Answer: tokens.out 0

A bug. The submission span took tokens.in / tokens.out from the render measure of the context fill, not from the submission usage. After a watch stop (reasoning or repetition stop) that measure is the counted size of the rebuilt render for the next pass, with output fixed at 0. In other cases it was the newest call only. The 155.8 s span with in 5077 / out 0 is a reasoning stop: the stopped call's reasoning tokens were in SubmissionEnd usage and in the generationCall row, but not on the span. Fix: the span carries the submission usage (sum of its calls, the counted stopped call with them).

Old tokens_per_second was out / (ledger callStartedAt to call end). callStartedAt is the ledger open (before the queue wait), the previous call end, or the last tool close. So the low values had prefill and, for a first call, the queue wait in them. Now it is out / decodeTime, and a call with no observed first token records no rate. Limit: a call whose only output is a tool call shows its arguments in the transcript only at its end, so its decode time is near 0.

## Review Findings (2026-10-21 05:19)

> Scope: `review sha e6aff13b~1..e6aff13b` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> Tool rule 'code-hygiene/dead-code-swift' failed — the tool judged nothing, so its findings are missing. The package does not build at HEAD:
> `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:1030:85: error: extra argument 'cacheDirectory' in call` (`MLXModelLoader(cacheDirectory: cacheDirectory)`), then `error: Build failed`.

No findings from the validators that ran (counts: findings 0, confirmed 0, refuted 0, attempted 14, failed 0).

- [x] Blocker: HEAD does not compile (`LiveModelLoader.swift` passes `cacheDirectory:` to `MLXModelLoader`, which has no such argument; introduced after this change, by 9ef5750b). Fix the build, then re-run `/review ^e5kyhwb e6aff13b~1..e6aff13b` so `code-hygiene/dead-code-swift` judges this change.

## Review Findings (2026-10-21 06:09)

> Scope: `review sha e6aff13b~1..e6aff13b`, validators `code-hygiene` only (the validator whose tool rule failed before). 10 file(s) reviewed, 2 not reviewed (`.kanban/`, from .reviewignore).

No findings (counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0). `code-hygiene/dead-code-swift` ran this time, because the build compiles again with FoundationModelsExtras resolved at 6670bc0.