---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky7w3qtqpa41ex2rf6q42aw4
  text: |-
    Implementation landed. Summary:

    - New Sources/FoundationModelsRouter/Compaction/TokenBudget.swift: `TokenBudget` (limit/trigger=0.80/target=0.50), `unknownContextFill = Double.nan` sentinel, internal `ContextUsageState` enum (.none/.measured(input:output:)/.unknown) with `.fill(contextTokens:)`, and `newestStampedUsage(in:)` helper scanning TranscriptEvents for the newest stamped `.response`.
    - RoutedSession.swift: added `var contextFill: Double { get async }` to the protocol; `RoutedSessionActor` gained `contextTokens: Int` + `usageState: ContextUsageState` stored props (both defaulted so 3 pre-existing direct-init test call sites needed no changes); `contextFill` computed property; `finishTurn` updates `usageState` only when the turn's SDK diff actually included a `.response` entry (`diffIncludedResponse`), so a turn that never touched the backend (e.g. pre-flight grammar validation failure) doesn't reset a known fill to a misleading zero delta; `fork()` inherits the parent's `contextTokens`/`usageState` (a fork's backend is seeded from the parent's accumulated transcript, so its fill state should start there too, not at zero).
    - RoutedLLM.swift: `makeSession` passes `contextTokens: resolution.contextTokens, usageState: .none` (fresh root -> fill 0 until first turn).
    - SessionTreeRestoration.swift: `restoreSessionTree` computes restored usage via `newestStampedUsage(in: tree.effectiveEntryEvents(forSession:))`, mapping to `.measured` or `.unknown`.
    - Tests: new TokenBudgetTests.swift (6 tests) + 2 tests appended to TokenUsageMeteringTests.swift (restored-fill-from-stamp, restored-unknown-fill). Followed TDD: watched all 8 fail to compile first (missing `contextFill`/`TokenBudget`), then implemented to green.

    Verification (all green, zero new warnings beyond the known pre-existing mlx-swift_Cmlx.bundle one):
    - `swift build` — clean
    - `swift build --build-tests` — clean
    - `swift test` — 427 tests in 46 suites passed (baseline was 419/45; +8 = exactly the new tests), 16 gated/skipped in 6 suites unchanged

    Design note: the protocol's `contextFill: Double` is literally non-optional per the card's own "What" section; "unknown" is represented via the `Double.nan` sentinel per the card's suggested "documented sentinel" option (rather than making it Optional, which would contradict the literal signature given).

    Scope left as a seam per the card: checkpoint-aware restored fill (deriving from a future `CompactionSegment.tokensAfter` when a compaction checkpoint is the newest thing) is explicitly a later task — `newestStampedUsage` just reads the newest stamp in the effective event stream today.

    Spawned the `double-check` adversarial reviewer per really-done; awaiting its verdict before final hand-off.
  timestamp: 2026-07-23T16:14:35.351799+00:00
- actor: claude-code
  id: 01ky7xdyjrrcxztkrezmxd6r36
  text: |-
    Double-check round 1 returned REVISE with two findings, both addressed:

    1. (High, real bug) `newestStampedUsage` treated a failed turn's synthetic bodyless-close event (`.response`-kind but `entry == nil`, stamped from a usage delta taken around a turn that never touched the backend) as a valid usage stamp — this could corrupt restored `contextFill` with a bogus zero. Fixed by also requiring `entry != nil` in the predicate (mirroring the existing `TranscriptTree.isFailedTurnBodylessClose` convention). Verified red->green: manually removed the guard, confirmed `restoredFillIgnoresFailedTurnSyntheticCloseStamp` fails, restored the guard, confirmed it passes.
    2. (Low/Medium, documentation + test gap) Restore's `newestStampedUsage` scope is ancestor-inclusive (a fork inherits its parent's stamp up to the cut point), not scoped to "that session's own transcript.jsonl" per the card's literal wording. Kept the ancestor-inclusive behavior (it mirrors live `fork()`'s own already-existing choice to inherit `usageState` rather than reset to zero/unknown) but made the decision explicit in a doc comment and added `restoredForkInheritsParentStamp` covering it.

    Added 2 new regression tests (now 10 new tests total across both files, up from the original 8). Full re-verification green: 429 tests in 46 suites (baseline 419/45 + 10), 16 gated/skipped in 6 suites unchanged, zero new warnings.

    Spawned a second (bounded, final per really-done) double-check pass to confirm the fixes; awaiting its verdict.
  timestamp: 2026-07-23T16:37:38.520733+00:00
- actor: claude-code
  id: 01ky7xv6901b1jqs1gx7h4a7q6
  text: |-
    Double-check round 2 (bounded, final per really-done) returned PASS — both prior findings confirmed fixed with no remaining issues, and it independently re-verified the red/green cycle and full test counts itself.

    Final fresh verification (this message): `swift build` clean, `swift build --build-tests` clean (only the known pre-existing mlx-swift_Cmlx.bundle warning), `swift test` — 429 tests in 46 suites passed, 16 gated/skipped in 6 suites unchanged, zero failures.

    Leaving this task in `doing`, green, ready for `/review`.
  timestamp: 2026-07-23T16:44:52.384978+00:00
- actor: claude-code
  id: 01ky7z14shzx00jwtp4kwadrax
  text: |-
    Resolved both review findings (@unchecked Sendable synchronization invariant on ConfiguredLLMContainer.lastBackend) in TokenBudgetTests.swift and TokenUsageMeteringTests.swift.

    Investigation before fixing: confirmed both ConfiguredLLMContainer types are genuinely single-threaded, not just "probably fine":
    - lastBackend is written synchronously inside makeSession(instructions:), which is called synchronously (no await between call and write) from RoutedModel.makeSession (RoutedLLM.swift) — a plain, non-async, non-actor-isolated function that never hops threads.
    - Every test in both files reads lastBackend from the same @MainActor test method that made the synchronous makeSession call chain, after it returns — never concurrently.
    - restoreSessionTree (SessionTreeRestoration.swift) walks the tree with a plain sequential `for child in node.children { _ = try restore(child) }` — no TaskGroup/concurrent Tasks — and its makeSession(transcript:) overload doesn't touch lastBackend anyway.
    - Grepped both test files for TaskGroup/async let/Task{} — none found.

    Since no concurrent access is possible, added a documented synchronization-invariant comment (no lock needed) above each ConfiguredLLMContainer class declaration, matching the established convention in this repo (ToolCapturingLLMContainer/lastTools in SessionOutboxToolWiringTests.swift) rather than inventing a new comment style.

    Verification (all fresh, this pass):
    - swift build — clean (only the known pre-existing mlx-swift_Cmlx.bundle warning)
    - swift build --build-tests — clean
    - swift test — 429 tests in 46 suites passed, 16 gated/skipped in 6 suites unchanged, zero failures (matches the prior verified baseline exactly)
    - Spawned double-check (adversarial) per really-done: PASS, no findings — independently re-verified the call-chain synchronicity claim, the absence of concurrent access, the restoration path, convention match, and re-ran build/build-tests/full test suite twice, all green.

    No production code changed — doc comments only, in the two named test files. Leaving task in `doing`, green, ready for /review.
  timestamp: 2026-07-23T17:05:36.049066+00:00
depends_on: []
position_column: done
position_ordinal: cc80
title: 'TokenBudget + contextFill: measured token accounting'
---
## What
Implement the token-accounting layer of compaction_plan.md §1.4–1.5 in `Sources/FoundationModelsRouter/Compaction/TokenBudget.swift` and `Sources/FoundationModelsRouter/Session/RoutedSession.swift`:

- `public struct TokenBudget: Sendable { var limit: Int; var trigger: Double = 0.80; var target: Double = 0.50 }`
- `var contextFill: Double { get async }` added to the `RoutedSession` protocol and implemented on `RoutedSessionActor`:
  - **Numerator (live)**: the *last turn's usage delta* — NEVER the cumulative value. `LanguageModelSessionBackend.usageTokenCounts()` (`Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`) returns **cumulative** counts; the actor already derives per-turn usage by delta (`Self.usageDelta(before:after:)` in `RoutedSession.swift`). Current size = newest turn's per-turn `tokensIn + tokensOut` (the newest turn's input delta IS the whole transcript tokenized by the actual model). Retain the delta `recordTranscriptDelta` already computes, or snapshot-diff `usageTokenCounts()` per turn. Using the raw cumulative value would overestimate fill monotonically and trip the 0.80 trigger far too early.
  - **Denominator**: the profile's resolved working context — `SlotResolution.contextTokens` (`Sources/FoundationModelsRouter/Resolution/SlotResolution.swift`; note there is no `ResolvedSlot` type). Plumbing partially exists: `Router.swift` (~line 683) already passes `context: resolution.contextTokens` into session construction — verify the actor can reach it and finish the wiring if it currently stops short.
  - **Restored (pre-first-turn)**: newest stamped `.response` event (`tokensIn`/`tokensOut`) in that session's `transcript.jsonl`. Actor-path recordings already carry stamps today (`recordTranscriptDelta(grammar:since:usage:)`), so this is testable without the handle-stamping task. If no stamp exists, fill is *unknown* — never guessed. Represent unknown explicitly (e.g. optional or documented sentinel — pick one and document it) until the first turn re-measures.
  - Brand-new session before first turn: fill ≈ 0.

Update any `RoutedSession` conformers/stubs in `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift` and friends. Checkpoint-aware restored fill (using `CompactionSegment.tokensAfter`) is a later task (reconstruction) — leave a seam, not an implementation.

## Acceptance Criteria
- [x] `contextFill` on a live session = last-turn usage delta / resolved `SlotResolution.contextTokens`
- [x] After multiple turns, fill reflects only the newest turn's delta — a test that would fail under the cumulative reading passes
- [x] After restore with stamped events, fill derives from the newest stamp; with no stamps, fill reports unknown (never a guess)
- [x] New session before first turn reports ≈ 0
- [x] `TokenBudget` defaults: trigger 0.80, target 0.50; `limit` defaultable from the profile's resolved context

## Tests
- [x] `Tests/FoundationModelsRouterTests/TokenBudgetTests.swift` — budget defaults and fill math with a stub backend returning scripted cumulative `usageTokenCounts()`, including the multi-turn delta-vs-cumulative case
- [x] Extend `Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift` — restored-fill-from-stamps and unknown-fill cases
- [x] `swift test --filter 'TokenBudget|TokenUsageMetering'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction

## Review Findings (2026-07-23 11:47)

- [x] `Tests/FoundationModelsRouterTests/TokenBudgetTests.swift:17` — @unchecked Sendable conformance requires a documented synchronization invariant when there is no lock/isolation mechanism. ConfiguredLLMContainer holds a mutable property `lastBackend` that is accessed and modified without synchronization protection. Add a comment above or inside the class explaining the synchronization invariant (e.g., '// MARK: @unchecked Sendable: This class is used only in single-threaded test contexts and is not shared across concurrent tasks.') or add a lock/actor-based synchronization mechanism.
- [x] `Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift:21` — @unchecked Sendable conformance requires a documented synchronization invariant when there is no lock/isolation mechanism. ConfiguredLLMContainer holds a mutable property `lastBackend` that is accessed and modified without synchronization protection. Add a comment above or inside the class explaining the synchronization invariant (e.g., '// MARK: @unchecked Sendable: This class is used only in single-threaded test contexts and is not shared across concurrent tasks.') or add a lock/actor-based synchronization mechanism.
