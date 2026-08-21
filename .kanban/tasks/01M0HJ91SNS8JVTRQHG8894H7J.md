---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0jws6fwfrcqkt6swah3256f
  text: |-
    ### Research
    - Script: extract each token that starts with `Tests/`, `IntegrationTests/` or `Sources/` and ends in `.swift` from `plan.md` and `compaction_plan.md`; test each with `test -f`.
    - Before the change: 7 distinct paths, 2 missing.
      - `plan.md`: `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` — missing. `rg --files` finds the file at `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` (moved, not deleted). The two methods the paragraph names, `makeForkSeedsFromParentTranscript` and `secondTurnReusesFirstTurnsKVCache`, are in that file.
      - `compaction_plan.md`: `Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift` — missing. Found at `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift` (moved, not deleted).
      - The other 5 paths resolve: `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`, `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`, `Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift`, `Tests/FoundationModelsRouterTests/MultiTurnSessionTests.swift`, `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift`.
    - No path in the two documents points at a deleted file. No file was renamed inside the same prefix.
    - No `Tests/FoundationModelsRouterEvalIntegrationTests/` citation is in either document.
    - `dump validators` for `.md` returns zero rules.
  timestamp: 2026-08-21T19:29:20.892589+00:00
- actor: claude-code
  id: 01m0jwsqve76acr5q4a1tw4scc
  text: |-
    ### implement — changed
    - evidence: 2 files — `plan.md` (1 path corrected), `compaction_plan.md` (1 path corrected). Before → after:
      - `plan.md`: `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` → `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`
      - `compaction_plan.md`: `Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift` → `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift`
    - `git diff -U0` on the two documents shows exactly one changed line each; only the path text differs. The extract-and-check script reports 0 missing paths after the change (7 paths, all resolve).
    - root `swift test`: FoundationModelsRouterTests 1032 tests in 98 suites passed (2 known issues, pre-existing `withKnownIssue`); FoundationModelsRouterEvals 80 tests in 10 suites passed. No code changed. The one `warning: missing creator for mutated node` line is the pre-existing mlx-swift bundle build notice, not from this change.
    - No deleted-file citation found; nothing left out of scope.
    - next: /review
  timestamp: 2026-08-21T19:29:38.670086+00:00
- actor: claude-code
  id: 01m0jwz1m1pangzky8ewnrmvwv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 306f935). 0 files reviewed, 0 findings. The engine has no validator for markdown (`plan.md`, `compaction_plan.md`); `.kanban/` is excluded by `.reviewignore`. All acceptance criteria are checked.
    - next: none. The task moved to done.
  timestamp: 2026-08-21T19:32:32.513605+00:00
- actor: claude-code
  id: 01m0jwzen9r8p6n26hg79c8wfa
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — plan.md 1 path, compaction_plan.md 1 path; check script 0 missing of 7
    - test: green — root swift test 1032 + 80 passed
    - commit: 306f935
    - review: clean — 0 findings on HEAD~1..HEAD (no markdown validator); task moved to done
  timestamp: 2026-08-21T19:32:45.865242+00:00
position_column: done
position_ordinal: ffe780
title: plan.md points at a path the gated integration test no longer has
---
Found while card ^rzr6ez5 corrected the stale prompt-cache text in the same paragraph. Out of that card's scope, thus filed on its own.

`plan.md`, section "Sessions & KV cache", cites the gated file as:

```
(`Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`'s
`makeForkSeedsFromParentTranscript`)
```

That path does not exist. The file sits in the nested package, at
`IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`.
The same document writes the correct prefix in its milestone list, so the two disagree.

Sweep for the cause, not the sample: every `Tests/FoundationModelsRouter*Tests/` path
in `plan.md` and `compaction_plan.md` moved when the integration and eval targets went
into the nested package (commit `1db2b56`). Check each cited path against the tree.

## Acceptance Criteria

- [x] Every test path `plan.md` cites resolves to a file that exists
- [x] Every test path `compaction_plan.md` cites resolves to a file that exists
- [x] No text is changed except the paths #docs #test-debt