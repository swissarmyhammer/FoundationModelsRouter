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
- actor: claude-code
  id: 01m5f0cb4rchqfmfxgxpgvdhey
  text: |-
    ### review — findings
    - evidence: review sha a6d1466d~1..a6d1466d — 5 findings (5 confirmed, 0 refuted), all still present at HEAD f055e696: RoutedSessionActorGenerationCallSpans.swift:12, :42, :60, :76 (describe, now :78); GenerationCallTracingTests.swift:69. Tool rule code-hygiene/dead-code-swift failed because the build broke at LiveModelLoader.swift:1030 (extra argument 'cacheDirectory'), so its findings are missing.
    - next: implement the five swift/fluent-usage findings, renaming at every call site (including GenerationCallFirstTokenTests.swift and RoutedSessionActorWatchStopUsage.swift); fix the LiveModelLoader build break, then review again.
  timestamp: 2026-10-21T10:33:45.368903+00:00
- actor: claude-code
  id: 01m5f2dny03x3zt5mtjctahsdd
  text: |-
    ### implement — changed
    - evidence: RoutedSessionActorGenerationCallSpans.swift — `toolCallCount(of:)`, `traceGenerationCall(for:duration:toolCallCount:)`, `instant(goingBack:from:)`, `describe(usage:duration:toolCallCount:on:)`; GenerationCallTracingTests.swift — `ints(for:of:)`. Call sites renamed in RoutedSessionActorGenerationCalls.swift (two calls and a DocC link), RoutedSessionActorWatchStopUsage.swift, GenerationCallFirstTokenTests.swift. swift test on main: 1941 tests / 242 suites passed with 9 known issues, plus 27/15 and 19/3 passed.
    - note: `GenerationCallEntryKind.init(leftBy:)` is a separate initializer that no finding named, so it was left as is.
    - next: /review
  timestamp: 2026-10-21T11:09:26.336293+00:00
position_column: done
position_ordinal: ffffffff9d80
title: Span for each generation call under the submission span
---
From foundationmodelsacpagent-a5, bench run telemetry-16. The trace has 9 FoundationModelsRouter.submission spans and no child span for the 171 generation calls, so a call cannot be matched to its tool calls or its duration. Add a child span for each generation call, with the attributes tokens.in, tokens.cached, tokens.out, time to first token, and the stop reason / tool-call count.

- [x] Failing test first
- [x] One child span per generation call, parented to the submission span
- [x] Attributes: tokens.in, tokens.cached, tokens.out, time to first token, stop reason, tool-call count

## Review Findings (2026-10-21 05:19)

> Scope: `review sha a6d1466d~1..a6d1466d` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> tool rule 'code-hygiene/dead-code-swift' failed — the tool judged nothing, so its findings are missing: the build failed at `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:1030:85: error: extra argument 'cacheDirectory' in call`.

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGenerationCallSpans.swift:12` `swift/fluent-usage` — Parameter label `leftBy` does not form a natural grammatical phrase at the call site. When invoked as `toolCallCount(leftBy: entries)`, this reads awkwardly as "tool call count left by entries" rather than a fluent phrase like "tool call count of entries". Change parameter label from `leftBy:` to `of:` (or `in:`), so the call reads naturally: `static func toolCallCount(of entries: [Transcript.Entry]) -> Int`. Update all call sites correspondingly (lines 226 in RoutedSessionActorGenerationCalls.swift and line 42 in RoutedSessionActorWatchStopUsage.swift).
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGenerationCallSpans.swift:42` `swift/fluent-usage` — The first parameter lacks a label, which violates the rule requiring labeled parameters except for value-preserving conversions. The call `traceGenerationCall(usage, duration: ..., toolCallCount: ...)` reads unclearly as "trace generation call usage, duration, tool call count" without a preposition connecting the first argument to the base name. Add a label to the first parameter, such as `func traceGenerationCall(for usage: GenerationCallUsage, duration: Duration, toolCallCount: Int)`, so the call reads as 'trace generation call for usage, with duration and tool call count.'.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGenerationCallSpans.swift:60` `swift/fluent-usage` — The first parameter lacks a label, which violates the rule requiring labeled parameters except for value-preserving conversions. `instant(_ duration: Duration, before instant: ...)` omits a label on a non-value-preserving parameter. Add a label to the first parameter, such as `private static func instant(goingBack duration: Duration, from instant: DefaultTracerClock.Instant)` or similar to clarify the parameter's role.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorGenerationCallSpans.swift:76` `swift/fluent-usage` — The first parameter lacks a label, which violates the rule requiring labeled parameters except for value-preserving conversions. `describe(_ usage: ..., toolCallCount: ..., on span: ...)` omits a label on a non-value-preserving parameter. Add a label to the first parameter, such as `private static func describe(usage: GenerationCallUsage, toolCallCount: Int, on span: any Span)` or similar.
- [x] `Tests/FoundationModelsRouterTests/GenerationCallTracingTests.swift:69` `swift/fluent-usage` — The first parameter lacks a label, violating the rule requiring labeled parameters except for value-preserving conversions. The call `ints(key, of: spans)` omits a label on a non-value-preserving parameter. Add a label to the first parameter, such as `private static func ints(for key: String, of spans: [FinishedInMemorySpan])` so the call reads as 'ints for key of spans.'.