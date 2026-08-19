---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0dd3d65z11j8v9v44td19qr
  text: |-
    Research findings, before implementation:

    - The two slow tiers load `CompactionEvalRealModel` (`mlx-community/Muse-Glimmer-30B-4bit`, context 8192) through `CompactionEvalRealModelContainer.load`. One model constant controls all three eval suites.
    - The fact-retention recipe makes 2+ generations per sample: the fold's summarizer call(s) and one answering turn. The model is the whole cost. A change of `CompactionEvalRealModel.ref` to the small model converts both fact-retention tiers at one point.
    - The continuity recipe drives 12 to 14 real turns per task, times 10 tasks. The filler steps only consume context toward the 1638-token trigger of `compactionContinuityDefaultBudget`. A synthetic trigger makes the filler unnecessary.
    - The recording-boot route from the card body is not available for the continuity tier in this pass: `restoreSessionTree` refuses a model mismatch (the checked-in recording is stamped `Muse-Glimmer-30B-4bit`), and the recording's sidecar carries no `budget`, so a restored session does not auto-fold. New recordings per task would be necessary. The fast route that stays available is the proven `AutoCompactionTriggerIntegrationTests` shape: one substantial opening turn, a synthetic trigger, one fold in the final turn.
    - `Compactor.compact` summarizes the ORIGINAL transcript, never the truncated one, so planted facts reach the summarizer even after `TurnTruncation` runs. `stagesApplied` accumulates all three stage names on the summarization path.
    - The continuity runner counts EVERY `SessionEvent.compaction`, discarded folds included. `FoldOccurred` can therefore pass on a fold that changed nothing. The fast tier must count applied folds only (`stagesApplied` not empty), as `AutoCompactionTriggerIntegrationTests` does.
    - `GatedEvalResidencyTrait.provideScope` wraps the whole suite run, so it is the one place a per-suite wall clock can be printed for `.evaluates(...)` suites (the trait runs the evaluation before the test body).
  timestamp: 2026-08-19T16:19:06.053713+00:00
- actor: claude-code
  id: 01m0dfytj9ty2k9yvnjt5b85ab
  text: |-
    step: implement — the eval target is done; the integration target is not.

    What changed:
    - The three gated eval tiers now run mlx-community/Llama-3.2-1B-Instruct-4bit (680 MB, in the local cache) in place of the 30B model. CompactionEvalRealModel records what the swap no longer proves.
    - The continuity tier is redesigned: one large opening brief, a synthetic trigger (0.02) and target (0.06), keepRecentTurns 1, and exactly one applied fold. Hermetic guards in CompactionContinuityEvaluationTests hold the structure.
    - Each gated summarizer call is bounded by compactionEvalReasoningTokenHeadroom = 128. The default of 4096 let the small model generate 20485-byte summaries at 28.5 s each.
    - The gated tiers no longer compute the judged Faithfulness/Continuability dimensions (CompactionEvaluation.includesJudgedDimensions = false). No assertion read them, and the judge cost about 2.7 s for each sample. The gated tiers measure less than a judged run, and the doc comments say so.
    - The fact-retention floors are measured baselines minus one sample: summary 0.65, answer 0.5 (whole-dataset run measured 17 of 24 summaries and 13 of 24 answers).
    - GatedEvalResidencyTrait prints each suite's wall clock, and each suite FAILS on its .timeLimit: subset 1 minute, whole dataset and continuity 2 minutes.

    Measured (run of 2026-08-19, all green, printed by the suites):
    - CompactionEvaluationIntegrationTests: 17.6 s against a 60 s limit.
    - CompactionEvalFullDatasetIntegrationTests: 52.5 s against a 120 s limit.
    - CompactionContinuityEvaluationIntegrationTests: 28.6 s against a 120 s limit.

    Verification: Scripts/swift-test.sh --skip IntegrationTests is green (1008 tests in 93 suites, plus 75 in 8), and swift build --build-tests -Xswiftc -warnings-as-errors builds with 0 warnings.

    What remains, and why:
    - Nine suites in FoundationModelsRouterIntegrationTests stay over the budget: CompactionRoundTrip (20 min), CompactionSpike (15), RecordingHandle (15), SessionTreeRestoration (20), TranscriptReconstruction (15), PropagationProbe (15), LanguageModelSessionBackend (15), IntegrationTests (30), RealToolTurnComparison (30). Several need tool calls from a small model or new recordings, and a sanctioned long run must produce those recordings first.
    - The checked-in recording cannot boot the continuity tier: its stamp names the Muse 30B model, so restore refuses the small model, and its sidecar holds no budget, so no fold triggers on restore.
  timestamp: 2026-08-19T17:09:01.641848+00:00
- actor: claude-code
  id: 01m0dg51yhc8dg0kbdffd7nzpk
  text: |-
    ### test — green
    - evidence: `Scripts/swift-test.sh --skip IntegrationTests` gave 1008 tests in 93 suites OK, and 75 tests in 8 suites OK. 1 known issue in BoundedWaitTests. This is a known issue. It counts as green.
    - evidence: `Scripts/swift-test.sh --filter \"CompactionEvaluationIntegrationTests|CompactionEvalFullDatasetIntegrationTests|CompactionContinuityEvaluationIntegrationTests\"` gave 3 tests in 3 suites OK, in 99.585 seconds.
    - evidence: `swift build --build-tests -Xswiftc -warnings-as-errors` gave a clean build. No errors. No warnings.
    - next: none. All checks are green.
  timestamp: 2026-08-19T17:12:25.809151+00:00
- actor: claude-code
  id: 01m0dgk3g89p7zchgydd1q7bkm
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` gave 1 finding — Tests/FoundationModelsRouterEvalSupport/CompactionContinuityDataset.swift:511 (code-hygiene/magic-numbers-swift)
    - note: nine suites in FoundationModelsRouterIntegrationTests stay over the 2-minute budget. They wait for a sanctioned recording run. The first acceptance criterion covers them, so the card cannot go to done in this pass.
    - next: replace the magic numbers with named constants in the whole file, then run the review again
  timestamp: 2026-08-19T17:20:06.152299+00:00
- actor: claude-code
  id: 01m0dh7rzv1k6nq7he7tjvcwdg
  text: |-
    Work on the review finding `code-hygiene/magic-numbers-swift` at CompactionContinuityDataset.swift:511.

    What I did:
    - I read the rule text. The rule runs swiftlint's `no_magic_numbers` with `allowed_numbers: [0, 1, -1, 100]`. A named declaration is exempt. A literal in a call argument or in an arithmetic expression is not exempt.
    - I ran swiftlint with the rule's exact configuration on all Swift files that commit efd3b58 touched. Only line 511 was in code from efd3b58. The same file held 12 more sites from older commits: ten `fillerStepCount:` literals and the `* 2` at the seed builder.
    - I swept the whole file. I added four named constants with doc comments: `compactionContinuityShortFillerStepCount` (10), `compactionContinuityMediumFillerStepCount` (11), `compactionContinuityLongFillerStepCount` (12), and `compactionContinuityRecordedEntriesPerStep` (2). All 13 sites now use the constants. No value changed. swiftlint now reports 0 findings on the file.
    - Sites in CompactionEvaluation.swift (lines 31-33, 99) and CompactionContinuityEvaluation.swift (line 90) come from older commits, not from efd3b58. They are outside this sweep's scope.
    - The first full hermetic run showed 12 issues in the DetachingTool and Generation-stall suites. These suites do not read the dataset file. A direct run of those suites passed, and a full rerun passed. The issues were timing flake under load, not an effect of this change.
  timestamp: 2026-08-19T17:31:23.515161+00:00
- actor: claude-code
  id: 01m0dh84jrpn2nvasy7zrah7yz
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterEvalSupport/CompactionContinuityDataset.swift (13 magic-number sites now use 4 named constants); `Scripts/swift-test.sh --skip IntegrationTests` green — 1008 tests in 93 suites pass (1 known issue) and 75 tests in 8 suites pass, 0 failures, 0 warnings; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; swiftlint `no_magic_numbers` reports 0 findings on the file
    - next: /review
  timestamp: 2026-08-19T17:31:35.384292+00:00
- actor: claude-code
  id: 01m0dhc9tedem2zgwqv77mdm0c
  text: |-
    ### test — green
    - evidence: `Scripts/swift-test.sh --skip IntegrationTests` — target 1: 1008 tests, 93 suites, pass, 1 known issue (pre-existing BoundedWaitTests item, accepted as green). Target 2: 75 tests, 8 suites, pass, 0 issues. No FAIL lines. No skipped tests.
    - evidence: `swift build --build-tests -Xswiftc -warnings-as-errors` — exit 0, "Build complete!" with no warning or error lines.
    - No env vars set. FoundationModelsRouterIntegrationTests target was not run.
    - next: none. Suite is clean.
  timestamp: 2026-08-19T17:33:51.822436+00:00
- actor: claude-code
  id: 01m0dhhjsdwdwt9djszbx8mg2w
  text: |-
    ### review — clean (card held in review)
    - evidence: `review sha HEAD~1..HEAD` (commit c93c4ff). The engine found 0 new findings (7 attempted, 0 confirmed, 0 refuted). The prior finding at `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityDataset.swift:511` is corrected and checked.
    - hold: the card does not move to `done`. The first acceptance criterion is open. Nine suites in `FoundationModelsRouterIntegrationTests` stay above the 2-minute budget. They wait for a sanctioned recording run, as the card records.
    - next: do the sanctioned recording run, make the nine slow suites obey the budget, then review again.
  timestamp: 2026-08-19T17:36:44.845287+00:00
- actor: claude-code
  id: 01m0dhjw41zxh033ce02ezsvnv
  text: |-
    ### finish iteration 2 — stuck
    - implement: changed — the magic-number finding fixed and swept: 4 named constants over 13 sites in `CompactionContinuityDataset.swift`
    - test: green — `Scripts/swift-test.sh --skip IntegrationTests`, 1008 + 75 tests passed; warnings-as-errors build clean
    - commit: c93c4ff (iteration 1 landed as efd3b58)
    - review: clean — 0 findings; the card is HELD in `review`
    - blocker: the first acceptance criterion covers the nine 30B suites in `FoundationModelsRouterIntegrationTests` that stay over the 2-minute budget. They need recordings, and only a person can sanction the 30B recording run that produces them.
    - next: a person sanctions the recording run (`swift run RecordCompactionFixture` and the harness runs the card names), then the nine suites move onto recordings and the card re-reviews
  timestamp: 2026-08-19T17:37:27.169296+00:00
position_column: review
position_ordinal: '8580'
title: Every integration test must run in under 2 minutes — boot from a recording, or make the test smarter
---
From the user, 2026-08-19:

> yeah your integration tests need to target < 2 min each -- do this by starting from a pre-record, or just being smarter about the test

## The budget

**Under 2 minutes per test.** Not per suite, not per tier — per test.

## Where things stand against it

Measured, not estimated:

| suite | measured | over budget |
|---|---|---|
| `CompactionContinuityEvaluationIntegrationTests` | 1 sample of 10 used the whole 1200 s limit; single steps up to 280.7 s | ~10x on ONE sample; ~100x for the tier |
| `CompactionEvaluationIntegrationTests` subset | 271.0 s mean per sample, dearest 352.0 s | ~3x per sample |
| `CompactionSmokeIntegrationTests` | 4.1 s | under |
| `AutoCompactionTriggerIntegrationTests` | 5.0 s | under |
| `RecordedTranscriptCompactionIntegrationTests` | 10.2 s | under |

The three that pass the budget are the three built on 2026-08-18/19. The technique is already proven in this repository; the slow tiers simply predate it.

## The three techniques that already work here

1. **Boot from a recorded transcript.** `^pfdrppj` folds real 30B traffic in 10.2 s by loading `Fixtures/CompactionRecording/` with `TranscriptTree.load(under:)` and folding it. No session, no turn, no driving.
2. **A synthetic trigger threshold.** `^d02ryqj` trips auto-compaction in 5.0 s by passing a small `TokenBudget` through the public `makeSession(budget:)`. No fixture has to be grown to reach a real threshold.
3. **A small model.** `mlx-community/Llama-3.2-1B-Instruct-4bit` loads in about 2 s where the 30B takes 3.4 s and generates far slower. `RealModelContainer.load(ref:context:samplingMode:)` already takes the reference.

## What is actually slow, and why

The continuity tier drives 13 real generation steps per task to push a live session past its trigger, then asks a final instruction. The steps exist only to consume context. That is paying a 30B model for filler.

The same continuity property is reachable inside the budget: boot a recorded transcript already near the trigger, drive ONE real turn, and assert the fold happened and the answer still carries the planted fact. That is techniques 1 and 2 together, which is what the two fast tests already do separately.

## This supersedes two cards' direction

`^6ssbakk` raised the fact-retention subset limit to 42 minutes, and `^mmrzhe0` was about to do the same for the continuity tier's 20. Both were correct as measurements of the tests as written. Both become unnecessary if the tests fit 2 minutes. Do NOT spend more effort deriving larger limits — state on each card that the budget replaces that direction, and leave the derived constants in place until the tests are fast, so nothing regresses in the meantime.

## Acceptance Criteria

- [ ] Every test in the integration and eval targets runs in under 2 minutes, measured and recorded
- [ ] The measurement is printed by the test itself, as the three fast suites already do, so a regression is visible without a stopwatch
- [ ] A test that exceeds the budget fails rather than merely being slow
- [ ] What each converted test proves, and what it no longer proves, is stated in its doc comment — a faster test that measures less must say so
- [ ] `^6ssbakk` and `^mmrzhe0` record that this budget replaces their limit-raising direction

## Care needed

A cheaper test that quietly measures less is a worse test, not a better one. `^pfdrppj`'s doc comment is the standard to match: it states plainly that booting from a recording proves the fold applies to real traffic and does NOT prove the automatic path fires. Every conversion here owes the same sentence.



## Review Findings (2026-08-19 12:13)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 12 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

- [x] `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityDataset.swift:511` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants. #compaction #eval #test-debt