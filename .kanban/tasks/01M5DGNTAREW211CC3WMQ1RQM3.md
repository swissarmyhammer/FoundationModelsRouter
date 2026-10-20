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
position_column: review
position_ordinal: '80'
title: Per-generation-call prefill and decode time (time to first token per call)
---
From foundationmodelsacpagent-a5, bench run telemetry-16 (django__django-13447, Qwen3.8-27B-mxfp4, router 4b6bcc9). generation.time_to_first_token has 6 points against 171 generation calls, because it is recorded once per submission (recordedTimeToFirstProgress). Record it for each generation call, together with the decode time, so a reader can work out prefill rate = (in − cached) / prefill time and decode rate = out / decode time.

- [x] Failing test first
- [x] Each generation call records its time to first token and its decode time (metrics, and GenerationCallUsage / journal)
- [x] The per-submission time-to-first-token metric is kept or renamed so its meaning is clear