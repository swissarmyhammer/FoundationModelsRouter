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
- actor: claude-code
  id: 01m0bmxnfs3zkze3bqy2c72hsv
  text: |
    ### review — findings

    - evidence: `review sha 6bb2947~1..6bb2947` — 2 findings, 2 confirmed, 2 refuted, 7 attempted. Sources/FoundationModelsRouter/Resolution/JointFit.swift:160, Sources/FoundationModelsRouter/Resolution/JointFit.swift:163
    - next: Both findings are on `ReservationKey`. Periphery cannot see the synthesized `Hashable` conformance that reads `ref` and `role`, and that conformance is exactly what makes the struct a set key. Do NOT delete either property. Mark each with `// periphery:ignore` and a comment, the same way `ResidencyKey` in Sources/FoundationModelsRouter/Router.swift already does for its identical `ref` and `role` pair. Apply the cause to the whole file, not only the two reported lines.
  timestamp: 2026-08-18T23:57:17.689277+00:00
- actor: claude-code
  id: 01m0bnfyt19enratwdbk24s427
  text: |
    ### review — findings (directed verification pass)

    - evidence: 4 open items. Engine: Sources/FoundationModelsRouter/Resolution/JointFit.swift:160, :163. Directed verification: `sessionBytes` clamp under-reserves one KV cache on the pool-resident path; the embedding-versus-generation role axis has no charging test.
    - next: The clamp item is the one that matters. `Router.footprintBytes` answers 0 for a key resident at the real rung, while `footprint(ref, 0)` builds key `.llm(context: 0)` which is never resident and so answers real weights. The subtraction goes negative and the clamp turns a positive true cost into a zero charge, so a resident model named by both generation slots is charged nothing. This is the under-reserve direction — the box accepts a profile it cannot hold. Distinguish "already resident, weights committed" from "second session on that container, KV not committed" rather than letting one clamp cover both.
  timestamp: 2026-08-19T00:07:17.057109+00:00
- actor: claude-code
  id: 01m0bq6t4wvpzt2v5kw2pb038p
  text: |
    ## All four open findings closed. The under-reserve needed a signature change, and here is why

    ### Finding 3 is real, and the clamp was not the whole cause

    The verification comment is exactly right about the symptom, and the red test reproduced it before any code changed:

        flash.considered[0].chargedBytes → 0
        JointFit.withMargin(Self.sharedSessionRawBytes) → 2400

    At a budget of 3000 the whole trio charged 600, not 3000. Both generation slots charged zero for a pool-resident 27B-shaped model.

    **The clamp could not be repaired in place.** `sessionBytes` derived the KV term by subtraction — `footprint(ref, context) − footprint(ref, 0)` — and the first term is the figure the router *discounts*. For a resident key `footprint(ref, context)` answers `0`, so no arithmetic over that closure can recover a positive cache. Removing the clamp only turns a zero charge into a negative one. Raising the charge to the whole footprint would over-reserve by the weights. Neither is the honest figure.

    So `JointFit.resolve` now takes a THIRD injected closure:

        sessionBytes: (ModelRef, Int) -> Result<Int64, RepoMetadataError>

    It answers the **absolute** KV cache of ONE session at a working context, and it is never discounted for residency, because a cache is materialised per session and is never shared. `Router.sessionBytes(for:context:metadataByRef:)` implements it as `metadata.footprint.kvBytes(context:)` — no `residentKeys` in sight, and its doc states that the omission is the point.

    `evaluateCandidate` now reads: a key no earlier slot charged pays its whole footprint; a key an earlier slot already charged pays `sessionBytes` and nothing else. `weightsOnlyContext`, the subtraction and the clamp are all gone.

    Charges for a shared key are now, whether or not the model is resident:

    | | first generation slot | second generation slot |
    |---|---|---|
    | not resident | `withMargin(weights + kv)` | `withMargin(kv)` |
    | pool-resident | `0` | `withMargin(kv)` |

    The resident row is the one that was wrong.

    ### Finding 4 — the role axis now has two tests, and one of them catches a collapse directly

    `crossRoleReferenceIsChargedForTwoContainers` names one reference in the embedding slot AND the standard slot, and asserts both slots charge the whole `withMargin(12_000)`. `crossRoleReferenceDoesNotFitOnOneContainerBudget` takes one byte off the two-container budget and requires the throw.

    Both pass `sessionBytes: Self.neverCalledSessionBytes`, which records an issue when invoked. If `ResidentRole` were ever collapsed onto the ref alone, the standard slot would take the shared path, call that closure, and the test would fail by name rather than by an arithmetic surprise.

    ### Findings 1 and 2 — marked, not deleted

    `ReservationKey.ref` and `.role` each carry `// periphery:ignore` with the reason on its own line above the marker, the shape `dead-code-swift`'s staging contract requires and the shape `ResidencyKey` in `Router.swift` already uses. The marker line carries no trailing text, which the rule measures as the difference between suppressed and still reported.

    Swept the whole file for the same cause: `TrioAttempt`, `LadderWinner`, `LadderWalkResult` and `SharedBudget` all read their stored properties by name, so `ReservationKey`'s pair is the only site.

    ### The two recorded items that were not findings

    - **"One context per resolution" is now stated where it is load-bearing.** `ReservationKey`'s doc says the key carries no context while the pool key does, that the two agree only because `resolveAtFixedContext` writes one context onto all three slot resolutions, and that per-slot contexts would make this key coarser than the pool key and leave a whole set of weights unreserved — add the context to the key in the same change.
    - **`^pq5w87d` does cover the `Router.residentFootprint` under-record.** Read it: its "The gap" section states the same thing, and its acceptance criteria already bind the pool figure to the joint-fit figure. No extension was needed. Said so on that card, and `^8hs4wrw`'s triage line now names it.

    ### Two things a reviewer should weigh

    - **`JointFit.resolve` is public and gained a parameter.** Both in-repo callers are updated (`Router.runJointFit` and 26 test call sites). No safe default exists: a default that answers zero is the defect this card exists to remove, so the parameter is required on purpose.
    - **A stale DocC symbol link was found and fixed.** `JointFitTests.neverCalledNativeMaxContext` still named `resolve(profile:budgetBytes:footprint:nativeMaxContext:)`, which no longer exists.

    ### Green

    `swift test` — 1085 tests over 114 suites (32 + 58 + 995), 0 failures. One known issue, pre-existing (`withKnownIssue`). One build warning, pre-existing (`missing creator for mutated node`, the mlx-swift bundle).
  timestamp: 2026-08-19T00:37:14.524039+00:00
- actor: claude-code
  id: 01m0bq6yadkvehjg9nmdbqctq9
  text: |
    ### implement — changed
    - evidence: 3 files — `Sources/FoundationModelsRouter/Resolution/JointFit.swift`, `Sources/FoundationModelsRouter/Router.swift`, `Tests/FoundationModelsRouterTests/JointFitTests.swift`. `swift test`: 1085 passed over 114 suites, 0 failed, 1 pre-existing known issue.
    - next: `/review`
  timestamp: 2026-08-19T00:37:18.797305+00:00
- actor: claude-code
  id: 01m0bqxc04c81tdmpde7jbtmy5
  text: |-
    ### review — clean

    - evidence: `review sha HEAD~1..HEAD` on 0f4b274 — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. Directed source check of the four round-one items: all four are fixed, not moved. `swift test --filter JointFit` — 24 tests, 0 failures.
    - The under-reserve is gone. `evaluateCandidate` charges a repeated key `withMargin(sessionBytes(ref, context))`. `Router.sessionBytes(for:context:metadataByRef:)` reads `metadataByRef` only. It has no `residentKeys` parameter, so the resident discount cannot reach it. The subtraction, the `weightsOnlyContext` term and the `max(0, ...)` clamp are all deleted.
    - The role axis is pinned. A change of `ResidentRole(slot: .embedding)` to `.generation` makes both cross-role tests fail with 3 issues. The change was reverted at once.
    - `ReservationKey.ref` and `ReservationKey.role` are still stored properties. Each carries `// periphery:ignore` with the reason, as `ResidencyKey` does in Router.swift.
    - `JointFit.resolve` gained a required `sessionBytes` parameter. Both in-repo callers are updated — Router.swift and JointFitTests.swift. The whole package builds. The change is source-breaking for an out-of-repo caller.
    - The DocC link `JointFit/resolve(profile:budgetBytes:footprint:sessionBytes:nativeMaxContext:)` in the test helper agrees with the signature.
    - next: card moves to done.
  timestamp: 2026-08-19T00:49:33.700591+00:00
position_column: done
position_ordinal: ffb880
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

## Review Findings (2026-08-18 18:47)

> Scope: `review sha 6bb2947~1..6bb2947` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 0 not reviewed.

- [x] `Sources/FoundationModelsRouter/Resolution/JointFit.swift:160` `code-hygiene/dead-code-swift` — var.instance `ref` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Resolution/JointFit.swift:163` `code-hygiene/dead-code-swift` — var.instance `role` is assignOnlyProperty.

## Directed Source Verification (2026-08-18 19:05)

Six points checked from source at the user's direction, in addition to the engine pass. Points 1, 4, 5 and 6 hold. Points 2 and 3 do not.

- [x] `Sources/FoundationModelsRouter/Resolution/JointFit.swift` `sessionBytes` — the `max(0, residentBytes - weightBytes)` clamp under-reserves one KV cache when the model is already pool-resident. `Router.footprintBytes` keys residency as `ResidencyKey(ref:, role: .llm(context: context))` and returns `0` for a resident key. `sessionBytes` asks for `footprint(ref, weightsOnlyContext)` with `weightsOnlyContext = 0`, which builds key `.llm(context: 0)`; the pool only ever holds real rungs (8192, or ladder rungs floored at 4096), so that key is never resident and the call returns the real weights `W`. The resident path is therefore `residentBytes = 0`, `weightBytes = W`, giving `max(0, 0 - W) = 0`. The first generation slot also charges `withMargin(0) = 0`, so a resident model named by both `standard` and `flash` is charged nothing at all. The pool entry's recorded footprint covers the container plus ONE session's KV; the second slot opens its own session and materialises its own cache, so the true marginal cost is a whole KV cache and the charge is zero. The docstring's justification — "Zero is the right charge there as well: reusing a resident model costs nothing" — is true of the weights and false of the KV half, which is the exact distinction this task exists to draw. Reachable in production: `residentKeys` is `Set(pool.keys)`, so any resolve that happens while another profile is resident takes this path. Magnitude on this repo's own `multitoolGenerationFootprint` (`layers: 64, kvHeads: 8, headDim: 32`) at a 32768 rung is `2 x 64 x 32768 x 8 x 32 x 2` = 2147483648 raw, about 2.6 GB margined, charged as 0. This is the under-reserve direction: a box accepts a profile it cannot hold, and it fails at load time on a user's machine.
- [x] `Tests/FoundationModelsRouterTests/JointFitTests.swift` — the embedding-versus-generation role axis has no test on the charging side. `ResidentRole(slot:)` correctly maps `.embedding` to `.embedding` and `.standard`/`.flash` to `.generation`, so a ref named in both an embedding slot and a generation slot yields two `ReservationKey`s and pays twice. Nothing pins it: every `embedding:` list in this file names a dedicated embedding ref (`embBge`, `ladderEmb`, `sharedEmbedding`, `multitoolEmbedding`, `oversizedEmbedding`), never a ref that a generation slot also names. Add a test that names one ref in an embedding slot and a generation slot and asserts two full charges. If `ResidentRole` were ever collapsed, the failure would be an under-reserve of a whole embedding container, and today nothing would catch it.

### Points that hold, recorded so a later pass need not redo them

- The dedupe key is `(ModelRef as written, generation-or-embedding role)` with no resolved or normalised identity anywhere. `ModelRef` is `Hashable` over `repo` and an optional `revision`, and `init(_ string:)` only splits on the first `@` — no canonicalisation. Router's pool key `ResidencyKey` is `(ModelRef, .llm(context:) | .embedding)`, which is strictly finer. The two can only diverge on the context axis, and they cannot diverge there because one resolution assigns one context to every slot: `resolveAtFixedContext(context:)` writes `contextTokens: context` onto all three slot resolutions. Conservative-or-equal, so correct. Pinned by the test at `JointFitTests.swift` that asserts a pinned and an unpinned spelling of one repository need the separate budget, not the deduped one. NOTE for future work: "one context per resolution" is now load-bearing for memory safety. If per-slot contexts are ever introduced, `ReservationKey` becomes coarser than the pool key and will under-reserve a whole set of weights.
- The margin is applied once to the deduped total. `withMargin` is called on the already-deduped `rawCharge`, and the budget subtracts that same single-margined figure. `withMargin` rounds up, so charging per part is equal to or more conservative than one application to the sum. Pinned by the test asserting `standardCharge + flashCharge == withMargin(rawWeights + rawSession)`.
- `blockedSlot` cannot mislabel in the other direction. The standard-first branch only fires when `standard.chosen == nil`, so naming `.standard` is never a false statement, and when standard did choose the branch is skipped and the fallback reports embedding then flash in allocation order. A blocked embedding slot charges nothing, so standard sees the full budget and the label is maximally justified. `blockedSlot` is nil if and only if all three slots chose, so the preference changes only which slot is named and never `fits` or `isSucceeded` — it cannot make a failing trio look like it fits.
- `CandidateReport` is constructed in seven places, all inside `JointFit.swift`; nothing else in the repo builds one. It is `public` with a `public init`, and `chargedBytes` is required and inserted mid-signature, so this is still a source-breaking change for any downstream package that constructs the type. The same commit also changed `LadderAttempt.init`'s labels and turned `fits` into a computed property, and added `Verdict.trioBlocked(ModelSlot)` which breaks downstream exhaustive switches. Worth a semver note even though no in-repo caller breaks.

### Out of scope for this diff, recorded for triage

`Router.swift` computes `residentFootprint` by summing one `footprintBytes` per pool entry, and two generation slots sharing one ref and context share one entry — so the pool records one session's KV where two are live. That under-record is a property of `Router.swift`, which this commit does not touch, and it predates this change. It is adjacent to the clamp defect above and should be triaged with it rather than assumed fixed by it. Confirmed covered by `^pq5w87d`, which states the same gap and carries acceptance criteria for it. #defect #router