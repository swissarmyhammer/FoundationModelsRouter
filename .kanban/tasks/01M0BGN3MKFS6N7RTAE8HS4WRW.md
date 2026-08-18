---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjs6qc2nwajfq9sxdb82bb
  text: |-
    ## Audit at `dd55fcd2c` — the defect is REAL, but three parts of the account are wrong

    This card stays open, and it stays valuable. A peer session filed it from their CI, and the defect they found is genuine. But their reading of the evidence is wrong in three places, and one of their instructions would add a new defect. Read the corrections below before you start the work.

    ## Verified true

    `JointFit` subtracts each chosen candidate's margined footprint at two places, and neither of them knows about a ref it already reserved:

    - `Sources/FoundationModelsRouter/Resolution/JointFit.swift:167` — the fixed context
    - `Sources/FoundationModelsRouter/Resolution/JointFit.swift:316` and `:324` — each ladder rung

    The runtime does share one container. `Sources/FoundationModelsRouter/Router.swift:50-71` — `ResidencyKey` is `(ref, role)` with `role = .llm(context:)`, and there is no slot axis. `Router.swift:377-381` says it directly: each distinct key is preloaded one time at most, even if two slots in the same resolve share it. The closed card `^1zt7vyg` and its `generationGate` deadlock are more evidence of the same sharing.

    ## Wrong, point 1 — the two verdicts were not taken against the same number

    The sub-lines below `standard` are ladder rungs. The flag on a rung means "the whole trio co-fit at this rung". It does not mean "this candidate fit".

    `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:62` — "`fits`: Whether the full trio co-fit the budget at this rung". Line 243 renders `false` as the string `too large`.

    So the standard candidate DID fit its own budget at 4096. The trio did not.

    ## Wrong, point 2 — the card names the wrong slot

    `18578992248` is ALREADY margined (`JointFit.swift:262-264`). The table on this card misses that.

    Inside `attemptTrio` at 4096:

        26800603136 − 402356108  = 26398247028   budget for standard
        standard fits, and reserves
        26398247028 − 18578992248 =  7819254780   budget for flash
        the same 27B does not fit there

    So FLASH is the slot charged a second time for a container it shares. Standard was charged correctly.

    Flash shows as `chosen` only in the failure diagnostic (`JointFit.swift:579-585`), which re-resolves it at the budget before standard, because standard chose nothing and so reserved nothing (`JointFit.swift:571-578`).

    The inference on this card — that flash is last in allocation order and so has nothing left to reserve for — reverses cause and effect.

    ## Wrong, point 3 — "dedupe on resolved identity, not spelling" would add a new defect

    The pool keys on the `ModelRef` AS WRITTEN — the repo plus an optional pinned revision — not on a resolved commit. Two refs that resolve to one commit but have different spelling make two `ResidencyKey`s, and thus two resident containers.

    A dedupe on resolved identity would then reserve too little, and the box would accept a profile it cannot hold.

    The correct unit of sameness is `ResidencyKey` itself: `ModelRef` equality, plus the same `.llm(context:)` role.

    ## The arithmetic on this card is wrong, but the conclusion holds

    With the real margined figures, the deduped total is:

        402356108 + 18578992248 = 18981348356 bytes against 26800603136

    That is about 7.8 GB spare, not the 4 GB this card states.

    ## The smallest correct fix

    Do not reserve zero for a repeated ref. Reserve its KV term.

    `Footprint.footprint(context:) = weightBytes + kvBytes(context:)` (`Sources/FoundationModelsRouter/Sizing/Footprint.swift`). The KV cache is per session, so only the WEIGHTS are shared.

    The closure signature that `JointFit` already has gives you the KV term with no signature change:

        kvTerm = footprint(ref, context) − footprint(ref, 0)

    because `kvBytes(context: 0)` is zero.

    Apply `withMargin` one time to the deduped total, not to each part. Both subtracting call sites need the set of reserved refs: `JointFit.swift:167`, and `:316`/`:324`.

    At these sizes the KV term is about 268 MB against 15.2 GB of weights, so a plain dedupe would also make the profile fit. But a plain dedupe would drop a real cost without a word, which is the thing the third acceptance criterion on this card asks the code to state instead of conflate. So the third instruction on this card is CONFIRMED — KV is per session, and the code must say which half the dedupe covers — even while the first instruction is corrected.

    ## One acceptance criterion the dedupe alone cannot meet

    "A slot is never reported `too large` at a budget a later slot then accepts the identical candidate at" is a RENDERING problem as much as an arithmetic one. A rung line prints the standard candidate's own footprint next to a flag that is about the whole trio. Any other slot that blocks a trio makes the same misleading line.

    Fix the rendering too, or somebody will raise this again.
  timestamp: 2026-08-18T23:19:54.348092+00:00
- actor: claude-code
  id: 01m0bkehg56v7p5b4k2tf0d35y
  text: |-
    ## Picked up. Research done at `94ca5e9`, and the verification comment is confirmed in the source

    Read the correction comment first, as instructed. Everything it states is true in the tree:

    - `JointFit.resolveAtFixedContext` subtracts `reservedBytes(resolution)` per slot with no memory of a ref it already reserved; `attemptTrio` does the same twice.
    - `Footprint.footprint(context:) = weightBytes + kvBytes(context:)`, and `kvBytes(context:)` multiplies by `Int64(context)`, so `kvBytes(context: 0)` is exactly `0`. The identity `footprint(ref, context) − footprint(ref, 0) = kvBytes` holds.
    - `Router.ResidencyKey` is `(ref, role)` with `role` of `.llm(context:)` or `.embedding`, and `Router` preloads each distinct key one time even when two slots share it.

    ### Two facts the correction comment does not carry, and they shape the fix

    1. **The unit of sameness has a ROLE axis, not only a ref axis.** `standard` and `flash` both load `.llm(context:)`, so they share one container. The `embedding` slot loads `.embedding`, which is a different key and a different container type (`LoadedEmbeddingContainer` against `LoadedLLMContainer`). A ref named by the embedding slot AND a generation slot is two containers, so it must stay reserved twice. A dedupe on the ref alone would under-reserve there. `ResolveTests.mergeKeepsLargerSuccessfulFootprintAcrossSlots` pins that exact profile shape.

    2. **The router's own footprint closure can report a SMALLER figure at `context` than at `0`.** `Router.footprintBytes` returns `0` for a ref whose `ResidencyKey` is already pool-resident, and the key at a context of `0` is never resident, so `footprint(ref, context) − footprint(ref, 0)` goes negative for an already-resident ref. The KV term has to be clamped at zero. Zero is also the right answer there: a resident model costs nothing marginal.

    ### The reconstructed multitool figures are exact

    Working back from the transcript on the card, the 27B is `weightBytes 15214058084, layers 64, kvHeads 8, headDim 32`. That fixture reproduces every rung the transcript printed, to the byte:

        262144 -> 38872712722    32768 -> 20833850079
        131072 -> 28564791212    16384 -> 19545359890
         65536 -> 23410830456     8192 -> 18901114796
                                  4096 -> 18578992248

    The embedding is `weightBytes 335296756` as an embedder, which margins to `402356108`. So acceptance criterion 5 is testable with real numbers rather than a stand-in. Against `26800603136`, the deduped ladder settles at a context of `32768`, and `65536` is the first rung where flash is what blocks the trio.

    ### One item found that this card does not cover

    `Router` records a fresh pool entry's `footprintBytes` as the chosen candidate's whole footprint, and sums those entries to compute the budget a later resolve sees. When two slots share one entry, that sum counts one KV cache while joint fit now reserves two. The gap is one KV term for each shared ref. It is a `Router` accounting question, not a `JointFit` one, so it gets its own card.
  timestamp: 2026-08-18T23:31:33.509594+00:00
- actor: claude-code
  id: 01m0bm4h0bywz9ytt7dgzxhmhj
  text: |-
    ## Implemented. Red first, then green

    ### The tests were red before the fix, and the red output reproduced the field report exactly

    Four assertions failed against the tree at `94ca5e9`, and one of them printed the reported contradiction back:

        standard (remaining 26398247028 bytes, context 4096 tokens): no viable candidate
          - org/Qwen3.8-27B-mxfp4 — unsized: too large
              context 4096 tokens — 18578992248 bytes: too large
        flash (remaining 26398247028 bytes, context 4096 tokens): chose org/Qwen3.8-27B-mxfp4
          - org/Qwen3.8-27B-mxfp4 — 18578992248 bytes: chosen

    The contradiction assertion also fired with the pair named: `standard reported org/shared-standard-flash too large at 500000 bytes, and flash chose it at 500000 bytes`.

    ### What landed

    **`JointFit`** now carries the shared budget as one value rather than a bare `Int64`.

    - `ResidentRole` maps a slot to what the router loads for it: `standard` and `flash` both load a generation container, `embedding` loads an embedder.
    - `ReservationKey` is `(ModelRef as written, ResidentRole)` — the pool's own key. Its doc states why a resolved commit identity would under-reserve.
    - `SharedBudget` holds what remains beside the keys already charged.
    - `sessionBytes(_:context:residentBytes:footprint:)` reads the KV term as `footprint(ref, context) − footprint(ref, 0)`, clamped at zero, so a repeated slot pays its own cache and nothing else. The clamp is load-bearing: the router's closure reports zero for an already-resident key while reporting real weights at a context of zero.
    - `attemptTrio` is now the one body every path runs through — the explicit-context path passes the whole standard list, a ladder rung passes one candidate. `allocationOrder` and `chosen(in:for:)` went away with the duplicate.

    **The reporting**, which the dedupe alone could not fix.

    - `LadderAttempt` stores `blockedSlot` and computes `fits` from it. The standard slot answers first: a rung prints that candidate's own footprint, so `too large` now means "this candidate did not fit", and any other slot's failure renders as `trio blocked by <slot>`.
    - `Verdict.trioBlocked(ModelSlot)` is the same distinction at the candidate level, for a candidate whose ladder won no rung while the candidate itself fit.
    - `CandidateReport.chargedBytes` sits beside `estimatedFootprintBytes`, so a reused container renders as `18578992248 bytes (322122548 bytes charged; an earlier slot already reserved the weights): chosen` and the arithmetic of the report adds up again.

    ### The acceptance criteria, one at a time

    1. **A ref named by two slots is reserved once** — `SharedBudget.chargedKeys`. Test: at the deduped budget the trio resolves; one byte below it does not.
    2. **The unit of sameness** — `ReservationKey`, not a resolved commit, per the verification comment above, which the card's own instruction is corrected by. The code states why, and a test pins that `org/x` and `org/x@abc123` still cost two containers.
    3. **Weights and KV distinguished, not conflated** — `sessionBytes` is the whole of the distinction, and `chargedBytes` against `estimatedFootprintBytes` carries it into the report. Test asserts standard is charged `withMargin(weights + kv)`, flash `withMargin(kv)`, and the two together are `withMargin(weights + 2 × kv)`.
    4. **Never `too large` where a later slot accepts the same candidate** — `expectNoContradictoryVerdicts` walks every slot pair of a failure and records an issue on any such pair. It fired before the fix and is silent after.
    5. **`multitool-cli-demo` co-fits `26800603136`** — it resolves, at a derived context of `32768`.

    ### Two judgment calls worth review

    - **`blockedSlot` puts the standard slot ahead of allocation order.** My first rule took the first blocker in allocation order, and the existing 1-byte-budget test caught it: with the embedding candidate also unfittable, a standard candidate that was genuinely too large got reported as `trio blocked by embedding`. Standard-first is the honest reading, and it left that pre-existing test passing unchanged.
    - **`CandidateReport.init` gained a required `chargedBytes`.** A defaulted `nil` would have silently charged zero. Nothing outside `JointFit` constructs the type.

    ### Green

    `swift test` — 1081 tests over 114 suites, 0 failures, 0 new warnings. The one build warning (`missing creator for mutated node`, the mlx-swift bundle) predates this change. The one known issue is a pre-existing `withKnownIssue`.

    ### Not mine to do

    FoundationModelsMultitool re-running its gated CI is the last item on this card, and it belongs to them.

    ### Filed

    `^pq5w87d` — `Router` records one KV cache for a pool entry two slots share, while joint fit now reserves two. That is the pool half of the same accounting and it is about 2.1 GB on the reported shape.

    ### implement — changed
    - evidence: 3 files — `Sources/FoundationModelsRouter/Resolution/JointFit.swift`, `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift`, `Tests/FoundationModelsRouterTests/JointFitTests.swift`. `swift test`: 1081 passed, 0 failed.
    - next: `/review`
  timestamp: 2026-08-18T23:43:33.899836+00:00
position_column: doing
position_ordinal: '8380'
title: '[Router] JointFit double-counts a ModelRef named in two slots; the runtime shares one container'
---
Filed from the FoundationModelsMultitool session at their user's direction, 2026-08-18. Router-native: it edits only `Sources/FoundationModelsRouter/Resolution/JointFit.swift` and its tests.

## The defect

`JointFit` allocates the three slots in order (embedding, standard, flash), subtracting each chosen candidate's margined footprint from the shared budget. When two slots name the **same** `ModelRef`, it reserves for that model twice — but the runtime only ever allocates it once.

## Evidence 1: the resolver contradicts itself in its own report

From FoundationModelsMultitool's self-hosted macOS CI runner, where every gated suite has failed since at least 2026-08-08:

    ResolutionFailure: profile "multitool-cli-demo" cannot co-fit a budget of 26800603136 bytes.
      embedding (remaining 26800603136, context 4096): chose Qwen3-Embedding-0.6B-4bit-DWQ
        - Qwen3-Embedding-0.6B-4bit-DWQ — 402356108 bytes: chosen
      standard (remaining 26398247028, context 4096): no viable candidate
        - Qwen3.8-27B-mxfp4 — unsized: too large
            context 262144 tokens — 38872712722 bytes: too large
            context 131072 tokens — 28564791212 bytes: too large
            context  65536 tokens — 23410830456 bytes: too large
            context  32768 tokens — 20833850079 bytes: too large
            context  16384 tokens — 19545359890 bytes: too large
            context   8192 tokens — 18901114796 bytes: too large
            context   4096 tokens — 18578992248 bytes: too large
      flash (remaining 26398247028, context 4096): chose Qwen3.8-27B-mxfp4
        - Qwen3.8-27B-mxfp4 — 18578992248 bytes: chosen

Read the last two blocks together. **The same model, at the same reported byte figure, against the same reported remaining budget, is `too large` for `standard` and `chosen` for `flash`.** One of those two verdicts is wrong. The asymmetry points at `standard` being charged for a copy that costs nothing extra — `flash` is last in allocation order and so has nothing left to reserve for.

Note also that `flash`'s remaining equals `standard`'s exactly, which confirms `standard` reserved nothing when it chose nothing. The two verdicts really were taken against the same number.

## Evidence 2: the runtime shares one container, and a bug you already fixed proves it

This is not an assumption. The `generationGate` deadlock — Router's own `^1zt7vyg` — happened **because** `standard` and `flash` resolve to one resident container carrying one `AsyncSemaphore(value: 1)`. `searchTools` generating on `flash` from inside a `standard` turn parked on the same permit, measured at `permits=0 waiters=1` across 33 samples. Two separate containers would each have had their own gate and there would have been no deadlock at all.

So the sharing is the documented cause of a real bug that cost both repos several days. `JointFit` reserves for a second copy `RoutedModel` never allocates.

## What the fix buys

Reserve a ref's footprint once; a later slot naming an already-reserved ref costs zero:

    embedding   0.402 x 1.2 =  0.48 GB    remaining 26.32 GB
    standard   18.579 x 1.2 = 22.29 GB    remaining  4.02 GB   <- fits
    flash      same ref, already reserved =  0 GB              <- fits

22.8 GB against a 26.8 GB budget, 4 GB spare. It is the single thing standing between FoundationModelsMultitool's gated suite and real CI coverage — 11 failing suites today, all with this one error.

It also widens what Router can host generally: any profile reusing one model across slots is currently sized as if it were two or three models, so boxes reject configurations they could comfortably run. The "one reference means one resident container" property is something Router already advertises to consumers.

## Care needed

- Dedupe on the resolved identity, not the spelling. Two `ModelRef`s that resolve to the same repo and revision are the same resident container; two that differ only by `@revision` are not.
- KV cache is per-session, not per-container, so context budgeting may legitimately still need per-slot accounting even when weights are shared. Weights are the ~18.6 GB here; say explicitly in the code which part is shared and which is not, rather than letting the dedupe quietly cover both.
- The `x 1.2` margin should be applied to the deduped total, not per slot.

## Acceptance Criteria

- [ ] A `ModelRef` named by two or more slots is reserved once against the shared budget
- [ ] The unit that decides sameness is the resolved identity, and the code states why `@revision` differences are not the same container
- [ ] Weight sharing and per-session KV accounting are distinguished in the code, not conflated by the dedupe
- [ ] A slot is never reported `too large` at a budget that a later slot then accepts the identical candidate at — this asymmetry is itself worth an assertion
- [ ] `FoundationModelsMultitool`'s `multitool-cli-demo` profile (one 27B in `standard` and `flash`, plus a 0.6B embedding) resolves against a 26800603136-byte budget

## Tests

- [ ] Ungated `swift test` green
- [ ] A test pinning the deduped arithmetic: same ref in two slots reserves once; different refs reserve twice
- [ ] A regression test for the reported asymmetry above
- [ ] FoundationModelsMultitool re-runs its CI and reports the per-suite result back — they have offered to do this the moment it lands
#router #defect