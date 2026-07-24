---
comments:
- actor: claude-code
  id: 01kya90r9bcp2pnx36dhs8ayhg
  text: |-
    Implemented. Research: confirmed Apple's `LanguageModelSession` calls each `Tool.call(arguments:)` directly and Router's own transcript-diff pipeline only observes the result afterward (`RoutedSessionActor.emitSessionEvents`, `SessionEvent.toolStatus`) — so the only seam that truly sees a tool's result "before the model does" is the tool-instancing pipeline itself (`RoutedModel.makeSession` / `RoutedSessionActor.fork`), the same seam `EventEmittingTool`/`ForkableTool` already hook into.

    Changes:
    - `TokenBudget.toolOutputLimit: Int?` added (Sources/FoundationModelsRouter/Compaction/TokenBudget.swift), nil by default, mirroring `hardCeiling`'s style.
    - New Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift: `ToolOutputCapping.capped(_:toTokenLimit:)` (truncation + "… [truncated: N of M tokens]" marker, N=limit, M=original estimated tokens) and `ToolOutputCapping.wrapping(_:toTokenLimit:)` (dynamic wrap discovered via existential cast `tool as? any Tool<T.Arguments, String>` inside a generic `open<T: Tool>` helper — no per-tool opt-in needed, mirrors how `EventEmittingTool`/`ForkableTool` declare no associated types so they cast against `any Tool`). `TokenCappingTool<Arguments>: Tool` wraps `any Tool<Arguments, String>`, forwards all other Tool requirements, caps only `call(arguments:)`'s return.
    - Wired into `RoutedModel.makeSession` (RoutedLLM.swift) and `RoutedSessionActor.fork` (RoutedSession.swift), applied outermost — after `EventEmittingTool.connecting`/`ForkableTool.forked` — so the SDK's own call and the recorded `.toolOutput` transcript entry (hence `SessionEvent.toolStatus`'s `summary`) both see the capped text automatically, with zero changes needed to SessionEvent.swift/emitSessionEvents.
    - Added `Compactor.estimatedTokenCount(of: String)` overload reusing `charsPerTokenEstimate`, consistent with the existing transcript-level estimate.
    - `SessionTreeRestoration.swift` intentionally untouched: restored sessions always vend `autoCompactionBudget: nil` per existing doc comments, so there is no `toolOutputLimit` to apply there.

    Tests: 2 new TokenBudgetTests cases (default nil, override), 14 new ToolOutputCappingTests cases (truncation boundaries incl. exactly-at-limit, wrapping String vs non-String Output tools, makeSession wiring with/without toolOutputLimit, composition with EventEmittingTool, fork() inheritance with/without toolOutputLimit).

    Verification: `swift build` clean, `swift test` full suite green — 526+18+5 = 549 tests passing, 0 failures, 0 new warnings (one pre-existing unrelated mlx-swift bundle warning only). Adversarial double-check launched.

    Note: the local `diagnostics`/sourcekit-lsp MCP tool returned stale phantom errors (flagging even pre-existing `hardCeiling`/`SessionEvent` symbols as missing) — disregarded in favor of the real `swift build`/`swift test` compiler runs, which are authoritative and clean.
  timestamp: 2026-07-24T14:38:37.867934+00:00
- actor: claude-code
  id: 01kya9jka3ghf4rf2j9q5cywty
  text: |-
    Adversarial double-check (via the double-check agent) found a real bug: `ToolOutputCapping.capped(_:toTokenLimit:)` computed the total-size estimate in UTF-8 bytes (`Compactor.estimatedTokenCount(of:)`) but truncated the kept prefix by `Character` count (`text.prefix(keepCharacters)`). For any non-ASCII tool output (emoji, CJK, accented text, smart quotes, etc. — more bytes per character than ASCII) this mismatch meant `text.prefix(keepCharacters)` could return the ENTIRE original text while the code still appended "… [truncated: N of M tokens]" on top — producing a result both larger than the original and falsely claiming truncation. All 14 original tests used only ASCII fixtures (`String(repeating: "<letter>", count: N)`) so this was untested and undetected by the green `swift test` run.

    Fix: added a TDD regression test first (`cappedTruncatesMultiByteTextConsistentlyWithItsByteEstimate`, 10 emoji, confirmed RED against the buggy code — result was the full original + marker, byte count 71 > 40), then fixed `ToolOutputCapping.capped` to truncate on UTF-8 byte count via a new private `prefix(of:keepingAtMostUTF8Bytes:)` helper that walks whole `Character`s (never splitting mid-scalar/mid-emoji) up to the same byte budget the total estimate uses. Also added a non-positive-limit test (`toolOutputLimit: 0` -> empty kept prefix, marker still emitted) per the double-check's minor/non-blocking suggestion.

    Re-verified GREEN after the fix: `swift test --filter ToolOutputCappingTests` — 16/16 pass (was 14, now 16 with the two new regression tests). Full suite: `swift build` clean, `swift test` — 528+18+5 = 551 tests passing, 0 failures, 0 new warnings.

    Double-check otherwise confirmed: the `tool as? any Tool<T.Arguments, String>` existential-cast discrimination is correct against the real `FoundationModels.swiftinterface` protocol declaration (`public protocol Tool<Arguments, Output>`); both wiring sites (RoutedLLM.swift makeSession, RoutedSession.swift fork) apply capping outermost after connect/fork, correctly; SessionTreeRestoration.swift's "always budget: nil for restored sessions" claim is confirmed correct in the actual code; the marker text matches the task's literal spec; and the file's placement under Session/ (vs Compaction/) is right given it hooks the live Tool-calling seam rather than post-hoc transcript compaction.
  timestamp: 2026-07-24T14:48:22.595678+00:00
- actor: claude-code
  id: 01kyaafaaf9sjh848d0q6nf7de
  text: |-
    Addressed all 4 review findings:

    1. Compactor.swift: extracted private `estimatedTokenCount(bytes: Int) -> Int` helper; both `estimatedTokenCount(of: Transcript)` and `estimatedTokenCount(of: String)` now call it with their respective byte counts instead of duplicating the `Int((Double(bytes) / charsPerTokenEstimate).rounded(.up))` expression.

    2 & 3. Added `ToolOutputCapping.optionallyCapped(_ tool: any Tool, toTokenLimit limit: Int?) -> any Tool` to ToolOutputCapping.swift (natural home — where `wrapping(_:toTokenLimit:)` already lives). It does the `guard let limit else { return tool }; return wrapping(...)` that was duplicated between RoutedLLM.swift's `makeSession` and RoutedSession.swift's `fork`. Both call sites now just call the shared helper with their own optional limit (`budget?.toolOutputLimit` / `autoCompactionBudget?.toolOutputLimit`) instead of repeating the guard-and-wrap. Updated the doc comments at both call sites to reference the new helper name.

    4. Added a doc comment above `ToolCapturingLLMContainer` in ToolOutputCappingTests.swift, matching the pattern of `ConfiguredLLMContainer`'s comment in TokenBudgetTests.swift: explains `lastTools`/`lastBackend` are written synchronously inside `makeSession(instructions:tools:)` (no `await` between call and write, called synchronously from non-actor-isolated `RoutedModel.makeSession`), and read only from the same `@MainActor` test method after `makeSession` returns, so no lock is needed.

    Verification: `swift build` clean (zero new warnings — only the pre-existing unrelated mlx-swift bundle warning), `swift test` full suite green: 528+18+5 = 551 tests passing, 0 failures — matches baseline exactly, no test count change (pure refactor + one doc comment as expected). Adversarial double-check launched to confirm no behavior drift.
  timestamp: 2026-07-24T15:04:03.663873+00:00
- actor: claude-code
  id: 01kyaaxyt650z4x4dpredw5vbk
  text: |-
    First double-check pass (adversarial review of the refactor) returned REVISE: the finding-4 doc comment on `ToolCapturingLLMContainer` only accounted for `makeSession(instructions:tools:)` writing `lastTools`/`lastBackend`, but missed that the class's other required `LoadedLLMContainer` overload, `makeSession(instructions: String?)`, also writes `lastBackend` — and in production that overload is called from `RoutedSessionActor`'s actor-isolated `performAutoCompaction` (via `profile.flash.container.makeSession(instructions: nil)` for the flash-tier compaction summarizer). Since this suite's `StubModelLoader` returns the same container instance for every slot, that path exists and is real, even though no current test in this suite exercises `.compact()`/auto-compaction against the container.

    Rewrote the doc comment to: enumerate both write sites, name the real production caller and its actor-isolation context, and state explicitly that the invariant here only holds because no test in this suite drives that path — flagging that a future `.compact()` test against this container must revisit the annotation.

    Re-ran build + full suite green (528+18+5=551, no drift), then re-spawned double-check narrowly on the corrected doc comment — verdict PASS, confirming it accurately reflects both write sites, the real caller/isolation context, and that no test in the file currently exercises the compact/auto-compaction path.

    All 4 checklist items now checked off. Task remains in `doing`, green, ready for `/review`.
  timestamp: 2026-07-24T15:12:03.398778+00:00
- actor: claude-code
  id: 01kyabgzb5ag1r430jdn2py5rz
  text: |-
    Addressed the 2026-07-24 10:14 review finding: added an `@unchecked Sendable` invariant doc comment above `EmittingStringTool` in ToolOutputCappingTests.swift, mirroring the style of the existing `ToolCapturingLLMContainer` comment in the same file. Verified all four stored properties (name, description, output, sink) are `let`, assigned once in init, never mutated in connecting(_:)/call(arguments:)/postEvent(_:) — the invariant claim is accurate.

    Build: clean, zero warnings in the touched file (only pre-existing unrelated mlx-swift_Cmlx bundle build-system warning).
    Tests: 551 total (528 + 18 + 5 across bundles), 0 failures — matches stated baseline, no test count change (pure doc comment).

    Adversarial double-check spawned to confirm the comment's accuracy and style match before final handoff.

    Leaving task in `doing`, ready for next /review pass.
  timestamp: 2026-07-24T15:22:26.533439+00:00
depends_on:
- 01KY7E2TP9DBGFV8RJJJKDAE4B
position_column: doing
position_ordinal: '80'
title: Tool-output capping in the interop tool loop (TokenBudget.toolOutputLimit)
---
Harness plan §5.1 seam 2 absorbed — better here than any wrapper: tool OUTPUTS are what blow windows mid-turn, and Router's interop tool loop sees each result before the model does. Add toolOutputLimit to TokenBudget; oversized results truncate with an explicit marker ('… [truncated: N of M tokens]') and the truncation reflects in the toolStatus stream event — never silent. Replaces the harness's ObservedTool capping job (the event-emission job is the rich-stream task).

## Review Findings (2026-07-24 09:51)

- [x] `Sources/FoundationModelsRouter/Compaction/Compactor.swift:95` — The token-count calculation `Int((Double(bytes) / charsPerTokenEstimate).rounded(.up))` is identical in both `estimatedTokenCount` overloads. The logic is duplicated; only the byte-source differs. Extract a shared helper function parameterized by byte count. Extract a private helper `estimatedTokenCount(bytes: Int) -> Int` that performs the division and rounding, then call it from both public overloads with their respective byte counts.
- [x] `Sources/FoundationModelsRouter/RoutedLLM.swift:245` — Tool output capping logic is duplicated in RoutedSession.fork(). Both locations contain identical guard-and-wrap pattern: checking toolOutputLimit and wrapping with ToolOutputCapping.wrapping(). This could be extracted into a shared static helper method that both call, rather than maintaining parallel copies. Extract the capping logic into a static helper like `static func optionallyCap(_ tool: any Tool, with limit: Int?) -> any Tool` and call it from both makeSession and fork locations.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:998` — Tool output capping logic is duplicated from RoutedLLM.makeSession(). Both locations contain identical guard-and-wrap pattern. This should be extracted into a shared helper rather than maintaining this parallel copy. Extract the capping logic into a shared static helper and call it from both makeSession and fork locations.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift:282` — @unchecked Sendable requires a documented synchronization invariant. ToolCapturingLLMContainer uses @unchecked Sendable but provides no comment explaining how its mutable fields (lastTools, lastBackend) avoid data races. Add a doc comment above ToolCapturingLLMContainer explaining the synchronization invariant, similar to ConfiguredLLMContainer: explain that writes happen synchronously during test setup from @MainActor test methods, and reads happen from the same thread, so no lock is needed.

## Review Findings (2026-07-24 10:14)

- [x] `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift:38` — `EmittingStringTool` is marked `@unchecked Sendable` without a documented synchronization invariant. The concurrency rule requires documentation of the invariant when using `@unchecked Sendable` without an explicit lock or actor. Add a comment documenting the Sendable synchronization invariant above the class definition. Since all fields (`name`, `description`, `output`, `sink`) are immutable `let` declarations, document: `/// @unchecked Sendable invariant: all fields are immutable `let` declarations, so concurrent access is safe.`.