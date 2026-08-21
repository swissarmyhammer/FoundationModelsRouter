---
assignees:
- claude-code
position_column: todo
position_ordinal: 8a80
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

- [ ] Every test path `plan.md` cites resolves to a file that exists
- [ ] Every test path `compaction_plan.md` cites resolves to a file that exists
- [ ] No text is changed except the paths #docs #test-debt