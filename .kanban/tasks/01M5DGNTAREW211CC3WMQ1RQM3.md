---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dh1788205q7cme4kc6m1e6
  text: 'Research: the executor channel (LanguageModelExecutorGenerationChannel) is opaque in the macOS 27 SDK, and MLX''s generationObserver hook (with GenerateCompletionInfo prompt/generate times) is internal, so neither can timestamp the first token. The seam that works: a pass watch (SessionLanguageModelState.addPassWatch) on the MLX backend that reads liveSession.transcript with observation tracking inside each pass and reports the first growth of the output text (reasoning, response, tool-call arguments via WatchedText) to the GenerationPassObserver as a new phase. A pass is one generation call, and passStarted gives the call start. The session drains phases into the GenerationCallLedger; noteEndedCall then computes prefill = pass start -> first output, decode = first output -> call end, all on the observer''s clock. Limits: the MLX executor sends an updateMetadata event before prefill (no text, so ignored by measuring text); a call whose only output is a tool call shows its arguments only when the call ends, so its decode time is near 0. Per-submission TTFT metric keeps its name (dashboards), doc and Swift symbol now say per submission.'
  timestamp: 2026-10-20T20:46:17.864765+00:00
- actor: claude-code
  id: 01m5dhdv5nh8egg9s8fy0rjntp
  text: |-
    ### implement — changed
    - evidence: RED: GenerationCallUsageTests.eachCallReportsItsPrefillAndDecodeTimes failed (timeToFirstToken nil) and RouterMetricsTests.generationCallsRecordPrefillAndDecodeTimes failed (no timer). GREEN after the change. `swift build --build-tests` clean (no new warnings); `swift test`: 1924 tests in 237 suites passed with 9 known issues (+ 26 and 19 in the other targets).
    - what: GenerationCallPhase.firstOutput(at:) recorded by a permanent pass watch of MLXFoundationModelsSessionBackend (reads the transcript per pass, first growth of output text); GenerationCallLedger takes passStarted/firstOutput and computes GenerationCallTiming at the call end. New: GenerationCallUsage.timeToFirstToken / decodeTime (Duration?), TranscriptEvent.timeToFirstTokenMs / decodeMs, metrics FoundationModelsRouter.generation.call.time_to_first_token and .generation.call.decode_time (model.ref + slot). Per-submission metric keeps its name generation.time_to_first_token; Swift symbol renamed to MetricName.submissionTimeToFirstToken / recordSubmissionTimeToFirstToken with a doc saying it is one value per submission.
    - next: review
  timestamp: 2026-10-20T20:53:11.477878+00:00
- actor: claude-code
  id: 01m5ezt7e0k41c6ahapc6s1z14
  text: |-
    ### review — findings
    - evidence: review sha ab662cd6~1..ab662cd6 — 1 finding (1 confirmed, 0 refuted): Sources/FoundationModelsRouter/Tracing/RouterMetrics.swift:88 duplication/duplication (still present in current recordTiming). Tool rule code-hygiene/dead-code-swift did not run: build error at LiveModelLoader.swift:1030 (extra argument 'cacheDirectory').
    - next: extract the shared timer helper in RouterMetrics.recordTiming; re-review.
  timestamp: 2026-10-21T10:23:51.744214+00:00
- actor: claude-code
  id: 01m5f2dk17c6bdtkx6xz1e9cve
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Tracing/RouterMetrics.swift — recordTiming now calls one helper twice, `private func recordTimer(ifPresent duration: Duration?, label: String, dimensions: [(String, String)])`. The first argument carries a label (`ifPresent:`) instead of the finding's `_`, because swift/fluent-usage forbids an unlabeled non-conversion first argument. swift build --build-tests clean; swift test on main: 1941 tests / 242 suites passed with 9 known issues, plus 27/15 and 19/3 passed.
    - note: the build break at HEAD was a stale local Package.resolved (FoundationModelsExtras pinned at a63ddda); `swift package update FoundationModelsExtras` moved it to 6670bc0. Package.resolved is gitignored, so that fix has no commit.
    - next: /review
  timestamp: 2026-10-21T11:09:23.367228+00:00
position_column: done
position_ordinal: ffffffff9c80
title: Per-generation-call prefill and decode time (time to first token per call)
---
From foundationmodelsacpagent-a5, bench run telemetry-16 (django__django-13447, Qwen3.8-27B-mxfp4, router 4b6bcc9). generation.time_to_first_token has 6 points against 171 generation calls, because it is recorded once per submission (recordedTimeToFirstProgress). Record it for each generation call, together with the decode time, so a reader can work out prefill rate = (in − cached) / prefill time and decode rate = out / decode time.

- [x] Failing test first
- [x] Each generation call records its time to first token and its decode time (metrics, and GenerationCallUsage / journal)
- [x] The per-submission time-to-first-token metric is kept or renamed so its meaning is clear

## Review Findings (2026-10-21 05:18)

> Scope: `review sha ab662cd6~1..ab662cd6` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> Tool rule 'code-hygiene/dead-code-swift' failed — the tool judged nothing, so its findings are missing. The build failed: `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:1030:85: error: extra argument 'cacheDirectory' in call` (`MLXModelLoader(cacheDirectory: cacheDirectory)`).

> Judged against the current code (after d3d72dfa): the finding below still holds; the two blocks now sit in `RouterMetrics.recordTiming`.

- [x] `Sources/FoundationModelsRouter/Tracing/RouterMetrics.swift:88` `duplication/duplication` — The timer-recording blocks for timeToFirstToken (lines 88–92) and decodeTime (lines 94–98) are identical except for variable names and the metric label — these are one function with arguments waiting to be extracted. Extract a shared helper function `private func recordTimerIfPresent(_ duration: Duration?, label: String, dimensions: [(String, String)])` that wraps the if-let and Metrics.Timer call, then call it twice with the two different labels and optional durations.