---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjqk7vm7y3m8f1ynjhjgcx
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds. No concurrency limit is set anywhere in the eval target. `CompactionEvaluationTests.swift:96` still divides the total: "1644.7 seconds over seven samples is 235 seconds for each".

    ## A conflict the audit found — correct it as part of this card

    Lines 52-56 of the same file say that "every sample's wall clock runs for very nearly the whole tier". The measurement on `^6ssbakk` refutes this. Six per-sample totals add to 1626.0 s of a 1800 s run. The generation gate holds the samples near to serial, so the total of the parts is almost the total of the run. The samples start together, but they do not run together.

    Correct that sentence when you do this card.
  timestamp: 2026-08-18T23:19:01.627839+00:00
- actor: claude-code
  id: 01m0bsej8awr525m2xx9j33rtr
  text: |-
    ## Research — the real mechanism, verified from source

    The audit comment names "the generation gate". That name is wrong for this target, and the correction matters, so I state it here.

    **`Evaluations` offers no concurrency limit.** Read the framework's own interface at `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/Evaluations.framework/Versions/A/Modules/Evaluations.swiftmodule/arm64-apple-macos.swiftinterface`. `Evaluation.run(info:)` takes an info dictionary only, and `Trait.evaluates(_:info:recordTranscripts:)` takes those three arguments only. No option of the framework bounds sample concurrency. So criterion 1 takes the card's own second branch: record the fact beside the limit.

    **The router's `RoutedModel/generationGate` is NOT what serialises these samples.** `CompactionEvalRealSubjectRunner` drives the bare-session recipe: `BlankSlateSummarizer` and the answering turn both call `MLXFoundationModelsContainer.makeSession(...)` and `respond(...)` directly. The target builds no `RoutedSession` and no `RoutedSessionActor`, so no `generationGate` permit is ever taken.

    **MLX serialises them instead.** Every sample generates through the one `MLXLanguageModel` the runner caches, and that value resolves one process-global `ModelContainer` keyed by model id. `MLXLanguageModel`'s generate path runs the whole generation inside `container.perform(nonSendable:)`. `ModelContainer.perform` calls `context.read`, and `context` is a `SerialAccessContainer`, whose own documentation reads: "Unlike an `actor`, this will guarantee exclusive access for the duration of the async call." So one generation at a time runs on the model, whatever number of samples wait.

    Result: the samples START together and they do not GENERATE together, so a run's wall clock is close to the SUM of the per-sample costs. `^6ssbakk` measures exactly that — six sample totals adding to 1626.0 s of an 1800 s run.

    ## A reading of criterion 3 the reviewer should check

    Criterion 3 says the limits' basis must rest "on whole-run measurements only". It was written when a per-sample figure looked meaningless. `^6ssbakk` measured each sample APART, from the progress trail, so a per-sample cost is now a measurement rather than a division. I therefore satisfy criterion 3 in substance: the subset limit rests on whole-run measurements, and the whole-dataset limit's derivation rests on directly measured per-sample totals, named as measured and never divided. The bullet asking for a real whole-dataset run stands open, and the constant still says a real run should replace the derivation.
  timestamp: 2026-08-19T01:16:25.738004+00:00
- actor: claude-code
  id: 01m0bt10s23qj2ptg8jz6ceh4z
  text: |-
    ## Landed, and how each criterion was met

    `compactionEvalSubsetTimeLimitMinutes` and `compactionEvalFullDatasetTimeLimitMinutes` were rewritten. No constant's VALUE changed.

    **Criterion 1 — the concurrency is a stated decision.** The card's own second branch applies, because `Evaluations` exposes no limit to state. The subset limit now records that plainly: `Evaluation.run(info:)` and `.evaluates(_:info:recordTranscripts:)` take no concurrency bound, no other value in the target states one, and what the framework really does varies between two trails of the same dispatch code. It also names what DOES bound the work — MLX's `SerialAccessContainer` mutex inside `ModelContainer.perform` — and states that `RoutedModel/generationGate` is not it here. `^23qeprz` carries the hermetic measurement that would turn this record into a decision the code holds.

    **Criterion 2 — no divided per-sample cost.** `compactionEvalFullDatasetTimeLimitMinutes` no longer divides 1644.7 by seven. It multiplies 271.0 s, the mean of six samples the `^6ssbakk` trail timed one by one. The subset limit now tells a reader to read a sample's cost off the trail and never to divide a run, and it says what the division hides: the model load, the gaps between samples, and a real 1.8x spread. Swept `Tests/` and `Sources/` for `1644`, `235`, `5639`, `94 minutes`, `over seven`, `divided by` and `per-sample rate` — no other site derives a cost that way. On the card side, `^6ssbakk` carries a comment naming its "about 235 s each" line as a division, and this card's own description carries a correction pointing at the comment thread.

    **Criterion 3 — the documented basis.** The subset limit rests on whole-run measurements: 1644.7 s of 1800 s in the 2026-08-17 run, and the 1800 s overrun of `^6ssbakk`. The whole-dataset limit is DERIVED and says so; it now rests on per-sample totals a trail MEASURED, never on a division, and it still says a real run of that tier should replace the derivation. The reading is recorded in the research comment above so review can overturn it.

    ## Two figures on this card that the raw logs refute

    Both were checked against `gated-run-3.log` and `gated-crit5.log` rather than taken from the card.

    1. `elapsed=0.0s` is not evidence. `CompactionEvalRealSubjectRunner.run(entries:prompt:budget:question:)` passes `elapsedSeconds: 0` as a literal, so every sample prints `0.0s` at its fold start whenever it starts. The order of the lines carries the evidence, and the doc comment now cites the order.

    2. The shape is not settled. `^h2xxsse`'s trail holds six `fold started` lines with no `fold returned` between them. `^6ssbakk`'s trail, on dispatch code `git diff` shows is identical, holds each sample's four lines complete before the next sample's first line. Filed as `^23qeprz`.

    ## The audit's wording, corrected

    The audit comment says "the generation gate holds the samples near to serial". No `generationGate` permit is taken in this target at all — the eval builds no `RoutedSession`. MLX's own serial container is what holds them. The doc comment states the real mechanism.
  timestamp: 2026-08-19T01:26:30.434453+00:00
- actor: claude-code
  id: 01m0bt17zghz1fq3e7ftxgf3mk
  text: |-
    ### implement — changed
    - evidence: 2 files — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift. `swift test`: 995 + 32 + 58 = 1085 tests in 114 suites, 0 failures, 1 pre-existing known issue in `BoundedWait`. Cards `^9cw5g6n` and `^a2x0ksj`.
    - next: /review. `^23qeprz` filed for the unmeasured dispatch shape.
  timestamp: 2026-08-19T01:26:37.808464+00:00
position_column: doing
position_ordinal: '8380'
title: The gated compaction eval subset runs its 7 samples concurrently, so every per-sample cost figure divided out of a run is wrong
---
Found by the instrumented gated run of 2026-08-18 (`^h2xxsse`). This is a measurement defect, not a product defect, and it silently corrupts how every figure on this tier gets read.

## What the trail showed

The seven samples emit their `fold started` lines one after another, every one of them at `elapsed=0.0s`:

```
[compaction-eval] sample=1/7 seed=budget-cap-tool-and-owner fold started elapsed=0.0s
[compaction-eval] sample=2/7 seed=db-port fold started elapsed=0.0s
[compaction-eval] sample=3/7 seed=encryption-algorithm fold started elapsed=0.0s
[compaction-eval] sample=4/7 seed=env-file fold started elapsed=0.0s
[compaction-eval] sample=5/7 seed=license-key-and-region fold started elapsed=0.0s
[compaction-eval] sample=6/7 seed=three-facts-long-project-brief fold started elapsed=0.0s
[compaction-eval] sample=7/7 seed=three-facts-support-escalation fold started elapsed=0.0s
```

`Evaluations` drives this tier's samples **concurrently**. All seven were in flight at once, seven generations sharing one resident MLX model.

**Corrected while the card was implemented — read the comment thread.** The `elapsed=0.0s` field is a literal the runner passes, so it is zero at every fold start and proves nothing. The order of the lines is the real evidence. And a later gated run of the same dispatch code drove its samples one at a time, so the shape is not settled. See `^23qeprz`.

## Why it matters

**Every per-sample cost figure derived by dividing a run by seven is wrong.** The doc comment on `compactionEvalSubsetTimeLimitMinutes` read "1644.7 seconds ... That is 235 seconds for each sample". That division assumes the samples run one after another. They do not: each sample's wall clock runs for very nearly the whole tier.

Three consequences, and each has already misled a reader:

1. **The tier has almost no headroom, and the stated margin hides it.** 1644.7 s and 1685.9 s against an 1800 s limit is 6.3% and 6.7% of room — not the comfortable "2.6 minutes over a 235-second sample" the comment implies.

2. **`0 of 7` is what a SMALL slowdown looks like, not necessarily a large one.** Seven concurrent samples finish near the end together, so one modest slowdown pushes all seven past the limit at once and the table reports a total wipeout. `^h2xxsse` reasoned from "235 s a sample" to "roughly seven times what a whole sample used to cost". That inference does not follow, and the arithmetic behind it was the divided figure.

3. **`^xscp198`'s reading is affected too.** That card records that a 7-sample tier turns one sampled refusal into a suite failure. Concurrency adds to it: the samples also contend for one model, so their individual durations are not independent of each other.

## What was already corrected

`^h2xxsse` corrected the two doc comments that carried the divided figure — `compactionEvalSubsetTimeLimitMinutes` now states that the number is a whole-run figure and must not be divided by seven, and `compactionEvalFullDatasetTimeLimitMinutes` states which of its inputs is now known wrong and in which direction (concurrency makes 24 samples cost LESS than 24 times a sample, so its derived 94 minutes still over-states and 120 is still a ceiling). No constant's VALUE was changed.

## The work

- Decide whether the tier SHOULD run its samples concurrently. Seven concurrent generations against one resident model is contention, and it is not obviously the measurement anyone intended: it makes each sample's duration depend on the other six, which is exactly what a per-sample cost figure must not do.
- If `Evaluations` exposes a concurrency limit, state it explicitly rather than inheriting the default, so the tier's shape is a decision in the code rather than a framework default nobody read.
- If it does not, record that plainly beside the limit, and derive the limit from whole-run measurements only — never from a per-sample division.
- Re-derive `compactionEvalFullDatasetTimeLimitMinutes` from a real whole-dataset run rather than from the subset, since the per-sample rate it multiplies does not exist.

## Acceptance Criteria

- [x] The tier's sample concurrency is a stated decision in the code, not an inherited default
- [x] No doc comment or card derives a per-sample cost by dividing a run's wall clock by its sample count
- [x] The limits' documented basis rests on whole-run measurements only

## Related

- `^h2xxsse` — the instrumentation whose trail exposed this.
- `^azd033m` — the summarizer regression measured in the same run, whose magnitude this finding bounds the reading of.
- `^xscp198` — the same tier's intolerance of a single sampled refusal.
- `^23qeprz` — the dispatch shape is not stable between runs, filed while this card was implemented.
#compaction #defect #eval #real-model