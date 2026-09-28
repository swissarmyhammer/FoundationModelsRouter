---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mnrphx4tbeh6ve74vf131p
  text: |-
    Implementation notes:
    - `RoutedSessionActor` has no `summarization` property now. `init` and `makeRoutedSessionActor` have no `summarization:` parameter. The fork, `RoutedLLM.makeSession(grammar:...)` and `SessionTreeRestoration` pass no `summarization:` argument.
    - `Compactor.compact` has no `summarization:` parameter. It calls `Summarization().plan(...)`.
    - The DocC link to `Compactor/compact(_:prompt:budget:counter:summarizers:pendingRuns:protection:abandoning:)` is updated in `RoutedSessionActorCompaction.swift`, `RoutedSessionCompactTests.swift`, `TranscriptCompaction.swift` (RealModelSupport) and `IntegrationTests/.../CompactionSmokeIntegrationTests.swift`.
    - `SessionTreeRestorationTests` had one `#expect(restoredRoot.summarization == Summarization())`. The property does not exist now, so that one line is removed. No other expectation changed.
    - The cancellation constructs are not touched: `abandonCompactionIfCancelled` stays non-async, and `runAnswerWork` is not changed.
    - `rg -n -w summarization Sources` now finds only prose, and the doc comment about old sidecars in `SessionConfiguration.swift`.
    - SwiftPM prints "failed loading cached manifest ... disk I/O error" for each package. The disk has 227 GB free. This comes from the SwiftPM user cache, not from repo code.

    ### implement — changed
    - evidence: 10 files. Sources: RoutedSessionActor.swift, RoutedSessionActorForking.swift, RoutedSessionActorCompaction.swift, Compactor.swift, RoutedLLM.swift, SessionTreeRestoration.swift. Tests: SessionTreeRestorationTests.swift, RoutedSessionCompactTests.swift, RealModelSupport/TranscriptCompaction.swift, IntegrationTests CompactionSmokeIntegrationTests.swift. `swift test --filter 'OneCallCompactionTests|RoutedSessionCompactTests|AutoCompactionTests|SessionTreeRestorationTests|CompactionTracingTests'`: 74 tests in 5 suites passed. Clean `swift build --build-tests` (separate scratch path): no warning in repo code (Examples and Tools are targets and compile). `swift build --build-tests --package-path IntegrationTests` passes.
    - next: /test
  timestamp: 2026-09-28T18:52:18.877472+00:00
depends_on:
- 01M3HNZ864SKTGZG92VMVM7ZJY
position_column: doing
position_ordinal: '80'
title: Remove the stored Summarization from the session actor and the Compactor
---
## What

After card ^mvm7zjy removes `Summarization` from the public API, the session actor still stores a `Summarization` value and passes it through fork and compaction. The value has no settings, so this plumbing does nothing. Remove it. `Compactor` then uses `Summarization()` directly.

Files:
- `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift` — remove `nonisolated let summarization: Summarization` (line ~545), the `summarization:` parameters of `init` (line ~607) and of `makeRoutedSessionActor` (line ~196), and the assignments.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift` (line ~217) — stop passing `summarization:` to the fork.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift` (line ~350) — stop passing `summarization:` to `Compactor.compact`. Update the DocC link in the doc comment of `runCompaction` that names `Compactor/compact(_:prompt:budget:counter:summarizers:summarization:pendingRuns:protection:abandoning:)`.
- `Sources/FoundationModelsRouter/Compaction/Compactor.swift` (line ~237) — remove the `summarization:` parameter; call `Summarization().plan(...)`.
- `Sources/FoundationModelsRouter/RoutedLLM.swift` and `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift` — remove the `summarization: Summarization()` arguments that card ^mvm7zjy left.

Update each test that passes `summarization:` to `Compactor.compact` or to the actor factory, and each DocC link in `Tests/` that names the old `Compactor.compact` signature.

## Acceptance Criteria
- [ ] `rg -n -w summarization Sources` finds no stored property, parameter or argument. Only prose and the `Persistable` decode compatibility of card ^mvm7zjy remain.
- [ ] Compaction, fork and restore behave as before: the existing compaction, fork and restore suites pass without a change to their expectations.
- [ ] `swift build --build-tests` has no new warning, and `swift build --package-path IntegrationTests --build-tests` passes.

## Tests
- [ ] No new behavior. The existing suites `OneCallCompactionTests`, `RoutedSessionCompactTests`, `AutoCompactionTests`, `SessionTreeRestorationTests` and `CompactionTracingTests` (in `Tests/FoundationModelsRouterTests/`) cover it. Update only their call sites.
- [ ] `swift test --filter 'OneCallCompactionTests|RoutedSessionCompactTests|AutoCompactionTests|SessionTreeRestorationTests|CompactionTracingTests'` — each suite name appears in the output and all pass. Use type names: a display-name filter matches nothing and exits 0.
- [ ] `swift test` — all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.

#compaction