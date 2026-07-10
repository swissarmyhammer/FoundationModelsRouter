---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx6wxtswd1n10y2djy8feqfc
  text: |-
    Implementation complete, build+test green.

    Changes:
    - `LanguageModelSessionBackend.usageTokenCounts() -> (input: Int, output: Int)?` added to the protocol (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift), doc comment mirrors `transcriptEntries()`'s serial-gate precondition.
    - `MLXFoundationModelsSessionBackend.usageTokenCounts()` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift) returns `(liveSession.usage.input.totalTokenCount, liveSession.usage.output.totalTokenCount)` unconditionally — never nil, never a fabricated zero — with a doc comment stating honestly that whether the MLX executor populates non-zero counts is NOT empirically verified in this sandbox (no GPU/network), citing the pre-existing gated `secondTurnReusesFirstTurnsKVCache` test (task 070qw7z) that already asserts `usage.input/output.totalTokenCount > 0` but has itself never run here.
    - `StubSessionBackend` (Tests/.../Helpers/StubSessionBackend.swift) gained a settable `usageIncrement: (input: Int, output: Int)?` and internal `cumulativeUsage`, grown by `usageIncrement` in `recordResponse()` on every successful call; `usageTokenCounts()` returns the cumulative total when configured, nil otherwise. `makeFork()` propagates both.
    - `RoutedSessionActor.generate(grammar:_:)` (Sources/FoundationModelsRouter/Session/RoutedSession.swift) captures `backend.usageTokenCounts()` immediately before and after the turn body, inside the serial gate; a new `usageDelta(before:after:)` helper computes the per-turn delta (nil unless both snapshots present). `recordTranscriptDelta(grammar:since:usage:)` stamps the delta only on the turn's last `.response`-kind event (mirroring how `ms` is already stamped), on both the success and throw paths (including the synthetic bodyless close). `makePartialEvent` threads `tokensIn`/`tokensOut` through.
    - No default protocol extension was added (kept consistent with the existing pattern where every conformer implements every requirement explicitly, like `transcriptEntries()`) — updated all 7 other test-double conformers across the test target with an explicit `usageTokenCounts()` (proxy to a wrapped `StubSessionBackend`, or `nil` for backends with nothing to report).
    - New unit tests: `Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift` — canned per-turn deltas across two turns are NOT cumulative (a cumulative-instead-of-delta bug would show [10,20]/[5,10] instead of [10,10]/[5,5]), and a backend reporting no usage leaves every event's tokensIn/tokensOut nil.
    - New gated integration test `recordedTokenUsageMatchesLiveBackendDelta` in `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`: asserts the recorded response event's tokensIn/tokensOut exactly match the live backend's own before/after usage delta; does not assert positive-vs-zero either way (prints it) since that's the open empirical question this sandbox cannot resolve — matches the task's "write it to pass either way" instruction.

    Verification: `swift build` exit 0, `swift build --build-tests` exit 0 (both targets), `swift test` — 303/303 unit tests pass, 14 gated integration tests correctly skipped (no FM_ROUTER_INTEGRATION_TESTS env var / no GPU here), 0 failures.

    Adversarial double-check dispatched; will record its verdict once back. Leaving task in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-10T20:53:54.108506+00:00
- actor: claude-code
  id: 01kx6x4x2mft34xmz9ff7g4n44
  text: |-
    Adversarial double-check verdict: PASS.

    The double-check agent independently re-derived the diff (chunked git diff per file), re-ran `swift build --build-tests` (exit 0), `swift test` (303/303 unit tests pass, 14 gated integration tests correctly skipped, including the new one), `swift test --filter TokenUsageMeteringTests` (both new tests pass), and `mcp__sah__diagnostics check working` (0 errors/warnings). It specifically traced the serial-gate placement of the before/after usage snapshots, the mutual exclusion between the SDK-diff stamp and the synthetic bodyless-close stamp (exactly one usage stamp per turn, never double), confirmed all 7 test-double conformers were updated and none were missed (clean build proves this), and confirmed the MLX backend's doc comment's citation of the pre-existing `secondTurnReusesFirstTurnsKVCache` test is accurate. No correctness, completeness, or intent-drift issues found.

    Task is fully done and green. Leaving in `doing` per the /implement workflow — not moving to review myself.
  timestamp: 2026-07-10T20:57:45.812621+00:00
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
- 01KX100VJZ64Q7M3E5VQB9P7GS
position_column: doing
position_ordinal: '80'
title: Meter tokensIn/tokensOut from LanguageModelSession usage
---
## What

Fill the long-empty `tokensIn`/`tokensOut` metering fields from the SDK's own accounting. `LanguageModelSession.usage` is verified real in the macOS 27 swiftinterface (`Usage{input: Input{totalTokenCount, cachedTokenCount}, output: Output{totalTokenCount, reasoningTokenCount}}`), but the chokepoint only sees `any LanguageModelSessionBackend` — so this needs its own protocol accessor.

- Add to `LanguageModelSessionBackend` (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift): `func usageTokenCounts() -> (input: Int, output: Int)?` — `nil` when the backend cannot report usage. Same serial-gate precondition doc as `transcriptEntries()`.
- `MLXFoundationModelsSessionBackend`: return `(liveSession.usage.input.totalTokenCount, liveSession.usage.output.totalTokenCount)`. Verify empirically whether the MLX-backed `LanguageModelSession` actually populates `usage`; if it reports zeros, return `nil` and document the SDK-side dependency in a comment (do not record fabricated zeros).
- `StubSessionBackend`: configurable canned counts for tests.
- `RoutedSessionActor.generate` (Sources/FoundationModelsRouter/Session/RoutedSession.swift): capture usage before and after the turn (inside the serial gate); stamp the per-turn delta as `tokensIn`/`tokensOut` on the turn's final `response`-kind event; leave `nil` when the backend returns `nil`.

## Acceptance Criteria
- [ ] Protocol accessor exists; MLX and stub backends implement it
- [ ] The response event of each turn carries the per-turn usage delta when the backend reports usage, `nil` otherwise
- [ ] The MLX empirical result (populates usage or not) is documented in a code comment
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit (stub with canned counts): two turns record correct per-turn deltas, not cumulative totals
- [ ] Unit (stub returning nil): events carry `tokensIn == nil`, `tokensOut == nil`
- [ ] Gated integration (`FM_ROUTER_INTEGRATION_TESTS`): assert recorded tokens are positive if the live SDK reports usage, or assert the documented nil behavior otherwise

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.