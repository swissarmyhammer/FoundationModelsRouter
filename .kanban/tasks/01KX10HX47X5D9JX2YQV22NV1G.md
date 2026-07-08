---
assignees:
- claude-code
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
- 01KX100VJZ64Q7M3E5VQB9P7GS
position_column: todo
position_ordinal: 8b80
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