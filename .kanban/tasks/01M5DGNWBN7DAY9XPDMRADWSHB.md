---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dhpfcqj84e6ac5c632ae9t
  text: |-
    ### implement — changed
    - evidence: RED: GenerationCallTracingTests (3 tests) failed with no FoundationModelsRouter.generation_call spans. GREEN after the change. `swift build --build-tests` clean; `swift test`: 1927 tests in 238 suites passed with 9 known issues (+26, +19 in the other targets).
    - what: new span FoundationModelsRouter.generation_call (kind internal), child of the running submission span, written when the ledger reports a call (takeGenerationCall / takeStoppedGenerationCall). The session knows the counts only at the call end, so the span is opened with an explicit start instant (now minus the call duration: prefill + decode when seen, else the ledger callStartedAt span) and ended now. Attributes: tokens.in, tokens.cached, tokens.out, generation.time_to_first_token_ms, generation.decode_ms, generation.finish_reason (FinishReason case name), generation.tool_call_count. New file Session/RoutedSessionActorGenerationCallSpans.swift; takeStoppedGenerationCall gains toolCallCount (from the stopped pass output).
    - next: review
  timestamp: 2026-10-20T20:57:54.327285+00:00
position_column: review
position_ordinal: '8180'
title: Span for each generation call under the submission span
---
From foundationmodelsacpagent-a5, bench run telemetry-16. The trace has 9 FoundationModelsRouter.submission spans and no child span for the 171 generation calls, so a call cannot be matched to its tool calls or its duration. Add a child span for each generation call, with the attributes tokens.in, tokens.cached, tokens.out, time to first token, and the stop reason / tool-call count.

- [x] Failing test first
- [x] One child span per generation call, parented to the submission span
- [x] Attributes: tokens.in, tokens.cached, tokens.out, time to first token, stop reason, tool-call count