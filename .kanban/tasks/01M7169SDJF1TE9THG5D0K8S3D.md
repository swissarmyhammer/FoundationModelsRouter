---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m72q704wrdxy9gcyf0v1nc7p
  text: |-
    Implementation notes:
    - The worktree branch started before the GGUF sizing work, so I fast-forwarded it to main (6422ad77) first.
    - `swift package update FoundationModelsLlamaCpp` resolves to 0541b99ee900f59991c9ea02077baba8f161caee. Package.resolved is in .gitignore here (line 17), so there is nothing to commit for it. A fresh resolve of the `main` branch picks up 0541b99 on its own.
    - GGUFCacheSizing now stores `hasDFlashTargetLayers` (from `GGUFHeader.dflashTargetLayers != nil`). It replaces `isUnloadableDFlashDrafter` with `unloadableDFlashDrafter: UnloadableDFlashDrafter?`, which has two cases, `.forkArchitecture` and `.noTargetLayers`, each with a `cause` string.
    - Router.warnIfDrafterWillNotLoad uses the same logger and metadata, and the message reads "a GGUF drafter has <cause>, which llama.cpp does not load as a DFlash drafter; the model decodes with no drafter and no speedup". The dflash-draft text is unchanged, byte for byte.
    - Decisions note for ^7k8wtq6: the check that ^7k8wtq6 skipped (a `dflash` architecture with no `dflash.target_layers`) is now covered by ^d0k8s3d. The old doc line saying "is not detected: GGUFHeader does not read that key" has been removed.
    - Tests: GGUFHeaderFixtures gains GGUF array encoding, `dflashDrafterBytes` and `noTargetLayersDFlashDrafterBytes`. GGUFResolveTests checks the exact warning text for dflash-draft and for dflash without target layers, and checks that no warning is logged for dflash with target layers or for a dense drafter.

    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Sizing/GGUFCacheSizing.swift, Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift, Tests/FoundationModelsRouterTests/GGUFResolveTests.swift
    - next: test
  timestamp: 2026-11-10T12:34:03.548867+00:00
- actor: claude-code
  id: 01m72q7208k09jyr3r9x31g7t1
  text: |-
    ### test — green
    - evidence: swift test — 2512 tests in 293 suites passed, plus 38 and 19; 0 failed; no warnings from project sources (the only warnings are C++17-extension warnings inside .build/checkouts/mlx-swift)
    - next: commit, review
  timestamp: 2026-11-10T12:34:05.448015+00:00
- actor: claude-code
  id: 01m72qa8v7hgdvfpv5ytdpkj17
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (05402602) — 4 files reviewed, 0 findings (1 candidate refuted, 7 validators attempted, 0 failed); there are no prior findings sections
    - next: none; the orchestrator commits the kanban state in the main checkout
  timestamp: 2026-11-10T12:35:50.759709+00:00
position_column: done
position_ordinal: fffffffff580
title: 'GGUF: warn before download when a DFlash drafter has no dflash.target_layers'
---
## What
GGUF sizing (^7k8wtq6) already warns when a GGUF drafter has architecture `dflash-draft`, which mainline llama.cpp won't load. It could not catch the second unloadable case, an old converter that writes architecture `dflash` with no `dflash.target_layers` key, because GGUFHeader didn't expose that key.

FoundationModelsLlamaCpp 0541b99 (pushed) adds `public let dflashTargetLayers: [Int]?` to GGUFHeader. It is nil when the key is absent and is parsed from the same prefix.

Warn (same logger and message shape as the dflash-draft warning) when either holds:
- architecture == "dflash-draft"
- architecture == "dflash" && dflashTargetLayers == nil

Real headers: Anbeeld/Qwen3.5-4B-DFlash-GGUF has 8 target layers and loads. lym00/Qwen3-4B-DFlash-GGUF-Test has none, so it falls back with drafterNotLoaded.

Update the `## Decisions` text on ^7k8wtq6, or note it here, so the skipped check is now covered. Bump the FoundationModelsLlamaCpp resolution to 0541b99 or later.

## Acceptance
- [ ] A hermetic test: a `dflash` drafter header without target layers logs the warning, a header with them does not, and `dflash-draft` still warns. #gguf