---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dhyt2hj0g0m1essj4mzw9e
  text: 'Step record: RED tests RouterMetricsTests.tokensPerSecondDividesByTheDecodeTime and WatchStopUsageTests.reasoningStopSpanCarriesTheStoppedCallTokens (failed 4202 vs 4160, 0 vs 150). RouterMetrics.recordGenerationCall now takes timing and records out / decodeTime only. endSubmission puts the submission usage on the span; measuredRender param removed. tokens.out 0 answer: a bug, see the card body. swift build --build-tests clean; swift test 1929 passed, 9 known issues; 26 and 19 in the other targets.'
  timestamp: 2026-10-20T21:02:27.409703+00:00
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