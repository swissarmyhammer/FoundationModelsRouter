---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bq5vz0z0fyz27knka1xahy
  text: |
    ## Confirmed as the card that covers `Router.residentFootprint`

    Checked while closing `^8hs4wrw`'s review findings. That card carries a line under "Out of scope for this diff, recorded for triage":

    > `Router.swift` computes `residentFootprint` by summing one `footprintBytes` per pool entry, and two generation slots sharing one ref and context share one entry — so the pool records one session's KV where two are live.

    This card states the same gap word for word in "The gap", and its acceptance criteria already bind the two figures together ("the bytes `Router` holds against the host budget for a shared key equal the bytes `JointFit` reserved for the same trio"). No extension was needed, and `^8hs4wrw` now names this card at that line.

    ### One fact from `^8hs4wrw` that shapes the fix here

    `JointFit.resolve` now takes a THIRD injected closure, `sessionBytes`, beside `footprint`. It answers the absolute KV cache of ONE session at a working context, and it is never discounted for residency. `Router.sessionBytes(for:context:metadataByRef:)` implements it as `metadata.footprint.kvBytes(context:)`.

    So joint fit's figure for a shared key is now exactly:

        withMargin(weights + kv) + withMargin(kv)

    and the pool records `withMargin(weights + kv)` for its one entry. The gap this card names is the second term, and `Router` can compute it from the same `sessionBytes` helper rather than deriving it again.
  timestamp: 2026-08-19T00:36:43.616770+00:00
- actor: claude-code
  id: 01m0d999j6ar3v1krnhbst9afz
  text: |-
    ## Research done — the design decision

    The gap is confirmed in `Router.swift`:

    - `acquireModel` writes `footprintBytes` on a fresh `PoolEntry` only. A reuse acquisition bumps `refcount` and records no bytes.
    - The figure comes from `chosenFootprint(for:)`, which reads `estimatedFootprintBytes` — the whole margined footprint. `JointFit` charges the second generation slot `chargedBytes` = `withMargin(kv)` (2_516_583 at the test fixture's 8192 context), and the pool does not hold it.

    The fix I will make (the card's first option, with one guard):

    - `PoolEntry` gets two figures: `baseFootprintBytes` (the first load's whole `× 1.2` footprint, a floor) and `acquiredChargeBytes` (the sum of the bytes each live acquisition charged at its joint fit). `footprintBytes` becomes computed: `max(base, acquiredChargeBytes)`.
    - Each acquisition passes its own `chargedBytes` — read from the chosen `CandidateReport.chargedBytes`, the exact figure `JointFit` subtracted. A reuse acquisition ADDS its charge; a release SUBTRACTS it.
    - `residentProfiles` stores `(key, chargedBytes)` holds, so `release(token:)` and the rollback path give back exactly each acquisition's share.
    - The `max(base, ...)` floor keeps today's conservative behavior when the first (fully charged) holder releases while a zero-charged reuser still holds the entry: resident weights never become unaccounted. This diverges from strict equality only in that stale-holder case, and only in the safe direction.

    By construction the pool delta of one resolve equals the sum of the trio's `chargedBytes` — the exact figure `JointFit` reserved. Criterion 1 and 2 follow; criterion 3 is pinned through `ResolutionFailure.budgetBytes` of a second resolve.

    Fixture math (2-layer config, 10 MB weights, context 8192): kv = 2_097_152 raw; `withMargin(kv)` = 2_516_583; generation base = 14_516_583; embedder = 12_000_000. Shared-pair trio reservation = 14_516_583 + 2_516_583 + 12_000_000 = 29_033_166.
  timestamp: 2026-08-19T15:12:24.646988+00:00
- actor: claude-code
  id: 01m0da48bgwp70g85xsk8fqw2f
  text: |-
    ## Implementation landed — TDD, both tests written first and seen red

    **RED.** Two new hermetic tests in `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift` failed with the exact predicted figures before the fix:

    - `sharedGenerationPairHoldsBothKVCachesAgainstTheBudget` — resolves a trio whose standard and flash slots name `org/pair-repo`, then resolves a disjoint trio that cannot fit and pins `ResolutionFailure.budgetBytes`. Red: 2_517_583 where 1_000 is correct — the missing figure is exactly one margined session KV cache (2_516_583).
    - `releasingOneHolderOfSharedPairGivesBackOnlyItsShare` — a second profile reuses the resident pair (charged only its own flash slot's KV, 2_516_583), releases, and the pinned budget shows only that share came back. Red: 5_034_166 where 2_517_583 is correct.

    **GREEN.** The fix in `Sources/FoundationModelsRouter/Router.swift`, the card's first option:

    - `PoolEntry` now carries `baseFootprintBytes` (the first load's whole `× 1.2` footprint, a floor) and `acquiredChargeBytes` (the sum of what every live acquisition charged at its joint fit). `footprintBytes` became computed: `max(base, acquiredCharge)`.
    - Each acquisition passes `chargedBytes` read from the chosen `CandidateReport.chargedBytes` — the exact figure `JointFit` subtracted (new helper `chosenCharge(for:)` beside `chosenFootprint(for:)`, both over a shared `chosenReport(for:)`). A reuse acquisition ADDS its charge to the entry.
    - New `ResidencyHold` (key + chargedBytes) replaces the bare key in `resolve`'s `slotHolds`, the rollback path, and `residentProfiles`, so `release(token:)` and `releaseKey(key:chargedBytes:)` give back exactly each acquisition's share.
    - The `max(base, ...)` floor keeps today's conservative accounting when the fully-charged first holder releases while a zero-charged reuser still holds the entry — resident weights never go unaccounted.
    - `makeRoutedModel`'s `footprintBytes` stamp on the handle stays `chosenFootprint` on purpose: it reports the model's whole size, not pool accounting.

    **Verification.**

    - `swift test --filter PooledResidencyTests`: 12/12 pass, including the 2 new tests.
    - `swift build --build-tests -Xswiftc -warnings-as-errors`: clean, 0 warnings.
    - `Scripts/swift-test.sh --skip IntegrationTests`: green — 997 tests in 91 suites (1 pre-existing known issue) + 72 tests in 8 suites, exit 0.

    **Out of scope, noted for completeness.** A LATER resolve that reuses a resident generation key is still priced at zero by the `footprint` closure's residency discount, including the KV its own new sessions add. That is a `JointFit` pricing question across resolves, not the pool-entry accounting this card names; the pool now holds exactly what joint fit reserved, which is what the acceptance criteria bind.
  timestamp: 2026-08-19T15:27:08.144900+00:00
- actor: claude-code
  id: 01m0da5keg64w1m84w5cwm7vwq
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/PooledResidencyTests.swift. RED seen first (budgetBytes 2_517_583 vs 1_000; 5_034_166 vs 2_517_583), then GREEN: `swift test --filter PooledResidencyTests` 12/12 pass; `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `Scripts/swift-test.sh --skip IntegrationTests` green (997 tests in 91 suites + 72 tests in 8 suites, exit 0). Follow-up card filed for the cross-resolve residency-discount KV gap: ^4pbv8b9.
    - next: /review
  timestamp: 2026-08-19T15:27:52.272976+00:00
- actor: claude-code
  id: 01m0da8ec3yy31n1ag5s3m1qpb
  text: |-
    ### test — green
    - We ran `Scripts/swift-test.sh --skip IntegrationTests`. No `FM_ROUTER_*` variable was set.
    - Result: 997 tests in 91 suites passed, with 1 known issue. This known issue is the pre-existing `BoundedWaitTests` record. It counts as green.
    - A second bundle ran: 72 tests in 8 suites passed.
    - No test failed. No test was skipped.
    - We also ran `swift build --build-tests -Xswiftc -warnings-as-errors`. The build finished with no error and no compiler warning.
    - Next step: proceed to review.
  timestamp: 2026-08-19T15:29:25.379026+00:00
- actor: claude-code
  id: 01m0daprntr75x62b0094zs6nz
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (local backend, commit 82c1404) — 0 findings, 7 validator attempts, 0 failed. 2 files reviewed; 12 `.kanban/` files excluded by `.reviewignore`.
    - next: none. The task moved to `done`.
  timestamp: 2026-08-19T15:37:14.682901+00:00
- actor: claude-code
  id: 01m0daqenpj4gyqr6rfr83txr4
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files, `Router.swift` and `PooledResidencyTests.swift`; each acquisition now charges its own joint-fit bytes, with TDD (red first)
    - test: green — `Scripts/swift-test.sh --skip IntegrationTests`, 997 + 72 tests passed, 0 failures; warnings-as-errors build clean
    - commit: 82c1404
    - review: clean — `review sha HEAD~1..HEAD`, 0 findings over 2 files; task moved to `done`
    - discovery: `^4pbv8b9` filed for the zero-priced reuse resolve, out of this card's scope
  timestamp: 2026-08-19T15:37:37.206013+00:00
position_column: done
position_ordinal: ffc080
title: '[Router] A pooled entry shared by two slots records one KV cache, while joint fit now reserves two'
---
Found while implementing `^8hs4wrw`, which made `JointFit` reserve a shared model's weights one time and its KV cache one time for each slot. This card is the `Router` half of the same accounting, and `^8hs4wrw` deliberately left it alone: it is a pool question, not a joint-fit one.

## The gap

`Router.acquireModel` records a fresh pool entry's `footprintBytes` from `Router.chosenFootprint(for:)`, which reads the chosen candidate's `CandidateReport.estimatedFootprintBytes` — the whole margined footprint of that one model, weights plus **one** KV cache.

When `standard` and `flash` name one reference at one context they share one `ResidencyKey`, so:

- the pool holds ONE entry, carrying weights plus ONE KV cache;
- the two slots open TWO sessions, so the box really carries weights plus TWO KV caches;
- `JointFit` now reserves weights plus TWO KV caches, which is the honest figure.

`Router.resolve` sums `pool.values` `footprintBytes` into `residentFootprint` and subtracts it from the host budget before the next profile resolves. So a later resolve sees one KV cache more budget than the box really has for each shared reference.

## Scale

The gap is one KV term for each reference two generation slots share. On the reported `multitool-cli-demo` shape (a 27B at a context of 32768) that is about 2.1 GB of a 26.8 GB budget, so it is not small.

## What a fix has to decide

The `footprintBytes` of a pool entry is documented as "the steady-state cost of this entry for as long as it exists". A shared entry has two steady-state costs, depending on how many slots hold it. Options a fix must choose between:

- Add the second KV term to the entry when a second slot acquires the same key, and take it away again on release.
- Record the whole trio's reservation against the resolve rather than per entry.

Either way the figure `Router` subtracts from the host budget must match what `JointFit` reserved, and a test must pin the two together.

## Acceptance Criteria

- [x] The bytes `Router` holds against the host budget for a shared key equal the bytes `JointFit` reserved for the same trio
- [x] Releasing one of two slots on a shared key gives back only that slot's share
- [x] A test resolves two profiles in order, the first naming one reference in both generation slots, and pins the budget the second one sees #router #defect