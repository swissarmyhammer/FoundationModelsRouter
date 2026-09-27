---
assignees:
- claude-code
depends_on:
- 01M3HNZ864SKTGZG92VMVM7ZJY
position_column: todo
position_ordinal: a880
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