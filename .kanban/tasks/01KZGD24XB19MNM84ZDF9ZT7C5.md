---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzgta0jva2y43pfqj5kyw27g
  text: |-
    Picked up. Research + first measurements.

    ## Research

    - `Sources/FoundationModelsRouter/Session/DiscoveryPriming.swift` holds `^s4405wc`'s machinery: `public struct DiscoveryPriming`, `public enum DiscoveryPrimingFailure`, and `internal enum DiscoveryPrimer.seededEntries(for:priming:mountedTools:)`.
    - The seeded call is run **host-side**: `DiscoveryPrimer.text(from:arguments:property:)` opens the `any Tool` existential and calls `textTool.call(arguments:)` directly, then `DiscoveryPrimer.entries(...)` splices `.prompt`/`.toolCalls`/`.toolOutput` into the transcript. Apple's `LanguageModelSession` tool dispatch is never involved.
    - Priming is only reachable through `RoutedSessionActor.primeDiscoveryIfConfigured(prompt:onEvent:)` (private, called from `runTurn`), configured via `RoutedModel.makeSession(... discoveryPriming:)`. This probe drives a **raw** `LanguageModelSession(model:tools:instructions:)`, so the opt-in is not reachable from it at all.
    - `RecordingHandleIntegrationTests` is the file this probe cites as proof its prompt shape drives a real tool call. It uses the same model (`RealModels.standard` = Qwen3.6-27B-mxfp4) and the same "you always respond by calling `<tool>`" instructions shape — but passes **no** `GenerationOptions`, i.e. no response-token cap. The probe added `maximumResponseTokens: 512`, which the reference shape never had.
    - `Transcript.Instructions.toolDefinitions` is readable from the live `session.transcript`, so "was the tool advertised to the model at all" is directly checkable rather than inferable.

    ## First measurements (this machine, today)

    New staged probe, gated, MLX test alone — **passes**, twice, with identical timing and identical transcript:

    ```
    recordedCallCount=1, transcript=[instructions, prompt, response, toolCalls, toolOutput, response]
    ToolContext.current != nil inside call(arguments:) == true
    observedCompletionToken == bound token
    12.908s / 12.908s
    ```

    Whole probe suite (both paths) also passes: system-model path `recordedCallCount=1`, `transcript=[instructions, prompt, toolCalls, toolOutput, response]`, 2.340s.

    So on this hardware the turn is **deterministic** in isolation — the model does call the tool. The card's recorded failure came from a full-suite `FM_ROUTER_INTEGRATION_TESTS=1 swift test` run, so the next step is to reproduce under that scope.

    Note on timing, which bears on the root cause: the passing turn is 12.9s; the recorded failure was 47.6s. A model that simply declines with a prose refusal or an announcement produces a *short* turn. 3.7x longer generation points at the turn running out to the 512-token cap without ever emitting the call — i.e. the cap, not a bare refusal, is what converted "calls the tool after a preamble" into "no tool call at all".
  timestamp: 2026-08-08T13:51:55.483096+00:00
- actor: claude-code
  id: 01kzgvw6kyz3b49zmsjmjnht8x
  text: |-
    Correction to my earlier note, and the resolution.

    ## The token-cap hypothesis was WRONG — measured, not assumed

    I predicted the 47.6s failure meant the turn ran out to the 512-token cap. Reproducing it disproved that: the failing turn is **short** (9.8s, then 65.1s in a run where it waited on the gate permit) and the transcript is `[instructions, prompt, response]` with one brief sentence. Not a ramble. `probeMaxTokens = 512` is untouched and irrelevant. Recording this so nobody re-tests it.

    ## `GenerationOptions.toolCallingMode = .required` — a dead end worth knowing

    The macOS 27 SDK does expose `GenerationOptions.toolCallingMode` with `.allowed` / `.required` / `.disallowed` (`arm64e-apple-macos.swiftinterface`), which would be the ideal deterministic lever. The mlx-swift-lm fork **never reads it** — `grep -rn 'toolCallingMode' .build/checkouts/mlx-swift-lm` returns nothing — so it is a no-op on the MLX path. Honouring it needs a fork change, which by standing project rule belongs on the fork's own board, not here. Do not reach for `.required` on the MLX path until that lands.

    ## The actual cause

    `MLXLanguageModel` holds a process-global container cache keyed by model id plus a per-model `PromptCache` whose KV state is sliced into content-addressed chunks **shared across every conversation on that model**. Every gated suite here drives the same `RealModels.standard`, so the probe's turn resolved against chunks other suites' tool-calling conversations left behind — and the model behaved as though a tool call had already happened, narrating `"I have called the context_probe tool with the note 'ping'."`

    Evidence, all on this machine today:

    | scope | probe outcome |
    |---|---|
    | probe test alone, x2 | passes, `recordedCallCount=1`, identical 12.908s both times |
    | probe suite alone (both paths) | passes |
    | full gated suite, before fix, x2 | fails stage 2, identical message both times |
    | full gated suite, after fix, x2 | passes, both paths, `recordedCallCount=1` |

    ## The fix

    `makeUncontaminatedContainer()` loads the model, calls `MLXLanguageModel.evict()` on it (which drops the container **and** purges that model's prompt cache), then reloads. The probe already evicted at the end of its turn; this is the same instrument moved to the front as well, so the probe both leaves a clean cache behind and requires a clean one in front.

    Deliberately **not** `MLXLanguageModel.evictAll()`, which I tried first: it also evicts models this suite never touches. That run is the one where `RecordingHandleIntegrationTests` newly failed, so the broad form perturbs siblings — the narrow per-model form is the one that shipped.

    No retry loop anywhere. The turn is driven exactly once.

    ## Not fixed here, and why

    Remaining full-gated-run failures are other cards:
    - `CompactionRoundTripIntegrationTests` (4 issues) — failed in **all six** runs today, including before any edit of mine. Fill-threshold half is `^5m97h14`.
    - `RecordingHandleIntegrationTests` / `CompactionSpikeIntegrationTests` — one or the other fails intermittently with the same zero-tool-call / lost-recall signatures. Filed as **`^pw807cp`**, which also flags that this card's mid-run eviction perturbs what later suites inherit and must be measured rather than assumed.

    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift. Ungated `swift test` green (757 + 20 + 12 tests, 0 failures). Gated `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter FoundationModelsRouterIntegrationTests`: propagation probe suite passes, both paths, `recordedCallCount=1`, `observedCompletionToken == bound`.
    - next: `/review`. Follow-up `^pw807cp` filed for the sibling suites.
  timestamp: 2026-08-08T14:19:20.062816+00:00
- actor: claude-code
  id: 01kzgw7yxvs01m3t1wx27e2hdr
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 4e158c3) — 0 findings, 0 confirmed, 0 refuted; 9 validators attempted, 0 failed, 0 skipped. Zero new findings. Engine note: tool rule 'code-hygiene/missing-docs-swift' unavailable (tool missing), prompt rule 'missing-docs' ran instead.
    - next: task moved to done; all prior acceptance criteria already checked and no prior Review Findings sections were open.
  timestamp: 2026-08-08T14:25:45.403943+00:00
- actor: claude-code
  id: 01kzgw8fyrspwjtmntct9ad7bs
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 file, Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift
    - test: green — swift test, 789 passed (757+20+12), 0 failures, 0 warnings, 37 skips all in FM_ROUTER_INTEGRATION_TESTS-gated suites
    - commit: 4e158c3
    - review: clean — zero new findings, 9 validators, task advanced to done
    - next: none — task done
  timestamp: 2026-08-08T14:26:02.840680+00:00
position_column: done
position_ordinal: f680
title: Gated ToolContext propagation probe records zero tool calls on the MLX path
---
Discovered by `^ce4hb6n`, which removed the `default.metallib` abort and so let this probe execute against real hardware for the FIRST time. Not a regression — never observable before.

Measured 2026-08-08, `FM_ROUTER_INTEGRATION_TESTS=1 swift test`, model `mlx-community/Qwen3.6-27B-mxfp4`:

`Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift:216` — test "MLX path: whether the ToolContext bound around respond() arrives inside call(arguments:)" fails on `#expect(observations.first)` after 47.6s. `observations` is empty, so `call(arguments:)` never ran at all.

## Why this matters, and why it is subtle

The probe is written to answer "does the `ToolContext` task-local survive `respond()`?" It cannot answer that question when the model never calls the tool: an empty `observations` array is indistinguishable from "the task local was lost" if you only read the assertion. The failure is therefore two problems at once:

1. **A probe-design gap.** The test conflates "no tool call happened" with "the context did not propagate". It needs to separate them — assert first that a tool call occurred, then assert what the context looked like inside it — so a future run reports which of the two failed.
2. **A likely instance of the zero-tool-call class.** A first assistant turn containing no tool calls is precisely the failure class card `^s4405wc` ("[Router] Pre-discovery seeding: deterministic first tool call via transcript construction") exists to make structurally impossible. That card records the measured finding that upfront prose cannot eliminate the class. If pre-discovery seeding lands, this probe may become deterministic for free.

Investigate whether this is the same class before designing a bespoke fix. Check the recorded transcript for the probe's turn to confirm the model produced prose instead of a tool call, rather than the tool being mis-mounted (a mounting bug would look identical from the assertion alone).

## Acceptance Criteria
- [x] Determined and recorded which it is: model declined to call the tool, or the tool was never correctly mounted/visible
- [x] The probe distinguishes "no tool call occurred" from "ToolContext did not propagate" — a failure names which happened
- [x] The probe answers its actual question on real hardware: a tool call is observed, and the `ToolContext` assertion evaluates for real
- [x] Relationship to `^s4405wc` recorded — either this is fixed by pre-discovery seeding (note the dependency) or it is independent (say why)
- [x] Ungated `swift test` stays green

## Tests
- [x] The gated run is the proof. Gated runs: one at a time, one shell command per run.

## Outcome

**AC1 — the model declined; the tool was correctly mounted.** Measured directly, not inferred. The rewritten probe reads the live `session.transcript` and its `.instructions` entry's `toolDefinitions`, so mounting and model choice are separate assertions. Under a full gated run the probe reported, reproducibly (twice):

```
MLX: stage 2 — the tool was advertised, but the turn's transcript records no
context_probe call, so the model answered without calling it. ... Transcript:
[instructions, prompt, response]. Final answer: "I have called the context_probe
tool with the note 'ping'."
```

Stage 1 passed, so `context_probe` was advertised to the model. The model narrated a call it never made — the zero-tool-call class in its purest form.

**Root cause — an inherited prompt cache, not the prompt.** `MLXLanguageModel` keeps a process-global container cache keyed by model id plus a per-model `PromptCache` whose KV chunks are shared across every conversation on that model. Every gated suite here drives the same `RealModels.standard`, so the probe's turn resolved against chunks other suites' (often tool-calling) conversations left behind — and the model behaved as though a tool call had already happened. Run alone the same turn called the tool every time (3/3, byte-identical timings). Dropping the model first (`MLXLanguageModel.evict()`, which purges that model's prompt cache) restores a real dispatched call under the full gated run.

Two hypotheses were tested and **rejected**: `maximumResponseTokens: 512` truncating a thinking model (the failing turn was short, ~9.8s, with a brief prose answer — not a 512-token ramble), and `GenerationOptions.toolCallingMode = .required` (the SDK exposes it on macOS 27, but the mlx-swift-lm fork never reads it, so it is a no-op on the MLX path and would need a fork change).

**AC4 — independent of `^s4405wc`, and seeding must never be used here.** `DiscoveryPrimer` runs the designated tool **host-side** and splices the finished pair into the transcript; Apple's dispatch never runs. A seeded call would fill this probe's observation log from a direct same-task call — which propagates a task local trivially — so the probe would report `true` while testing nothing about `LanguageModelSession`. Seeding defeats this probe rather than fixing it. The opt-in is also unreachable: it lives on `RoutedModel.makeSession(...)`, and this probe drives a raw `LanguageModelSession` deliberately. What `^s4405wc` did contribute is the diagnosis of the class.

Follow-up filed as `^pw807cp`: sibling gated suites (`RecordingHandleIntegrationTests`, `CompactionSpikeIntegrationTests`, and the recall half of `CompactionRoundTripIntegrationTests`) show the same two signatures and are not yet protected. #phase-1