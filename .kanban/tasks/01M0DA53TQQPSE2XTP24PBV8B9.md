---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0e4xkx67fgtrhk5nxgh7svs
  text: |-
    Research done. Findings:

    - The gap is in `Router.footprintBytes(for:context:metadataByRef:membership:residentKeys:)` in Sources/FoundationModelsRouter/Router.swift. For a resident generation key it appends `0`. The correct marginal cost is `metadata.footprint.kvBytes(context:)` — the new profile's own session adds a new KV cache on the shared container. The embedding interpretation stays `0` (an embedder has no KV term).
    - No pool change is necessary. `acquireModel` adds `CandidateReport.chargedBytes` to the entry's `acquiredChargeBytes`, and `releaseKey` subtracts the same figure. The corrected charge flows through.
    - In one resolve, a flash slot that names a resident key that the standard slot already charged goes through the `chargedKeys` + `sessionBytes` path. Both paths now answer one KV cache for a resident generation key. The result: a reuse trio with two generation slots on one resident model is charged two KV caches — one for each new session.
    - Four tests in PooledResidencyTests.swift pin the old zero price and must change their arithmetic: `sharedRefsLoadOnceAndBothGenerate`, `releasingOneProfileKeepsSharedModelLoadedForTheOther`, `concurrentGenerationOnSharedModelSerializes` (each needs 2 more KV terms of RAM), and `releasingOneHolderOfSharedPairGivesBackOnlyItsShare` (reuse charge becomes 2 KV, not 1).
    - Test profiles in this suite get an explicit context of 8192 from the `ProfileDefinition` initializer default, so residency keys match across resolves. The margined KV constant is `sessionKVMarginedBytes = 2_516_583`.

    Plan (TDD): write a failing test that resolves A, then B that names A's generation model and A's embedder, and pins the budget a third resolve sees to the headroom buffer alone. Then apply the one-line fix and correct the four tests and the stale doc comments in Router.swift and JointFit.swift.
  timestamp: 2026-08-19T23:15:22.150961+00:00
- actor: claude-code
  id: 01m0e5fassekfy8w2k92xgezaf
  text: |-
    Implementation landed. What changed:

    - Sources/FoundationModelsRouter/Router.swift — `footprintBytes` now answers `metadata.footprint.kvBytes(context:)`, not `0`, for a resident generation key. A resident embedder stays `0`. Five stale doc comments got the same correction (`poolLock`, `PoolEntry`, `ResidencyHold`, `resolve`, `acquireModel`, `chosenCharge`).
    - Sources/FoundationModelsRouter/Resolution/JointFit.swift — doc comments only: the type doc, the `resolve` parameter doc, and the `evaluateCandidate` doc now state the marginal cost of a resident generation model correctly.
    - Tests/FoundationModelsRouterTests/PooledResidencyTests.swift — new regression test `reusingResidentGenerationModelChargesOneSessionKVCache` (TDD: watched it fail RED with budget 2_517_583 against expected 1_000, then GREEN after the fix). Four existing tests pinned the old zero price and got the new arithmetic through a new `reusedTrioCharge` fixture constant (2 × `sessionKVMarginedBytes`): `sharedRefsLoadOnceAndBothGenerate`, `releasingOneProfileKeepsSharedModelLoadedForTheOther`, `concurrentGenerationOnSharedModelSerializes`, `releasingOneHolderOfSharedPairGivesBackOnlyItsShare`.

    Notes for the next agent:

    - A reuse trio with two generation slots on one resident model is charged TWO KV caches — one for the standard slot (residency path) and one for the flash slot (`chargedKeys` + `sessionBytes` path). Both paths now agree on the figure.
    - No pool change was necessary. The corrected charge flows through `CandidateReport.chargedBytes` into `acquiredChargeBytes`, and `releaseKey` gives back the same figure.
    - The race test's scenario still prices its shared EMBEDDER at zero; its doc comment now states the split.

    Verification:

    - `Scripts/swift-test.sh --skip IntegrationTests` — 1021 tests in 96 suites passed (baseline 1020 + 1 new), 77 tests in 9 suites passed. The single known issue is the pre-existing `withKnownIssue` in the BoundedWait suite.
    - `swift build --build-tests -Xswiftc -warnings-as-errors` — Build complete, zero warnings.

    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Resolution/JointFit.swift, Tests/FoundationModelsRouterTests/PooledResidencyTests.swift; Scripts/swift-test.sh --skip IntegrationTests → 1021 + 77 passed; swift build --build-tests -Xswiftc -warnings-as-errors → clean
    - next: review
  timestamp: 2026-08-19T23:25:02.649008+00:00
- actor: claude-code
  id: 01m0e5j2kt4bdrb2xdh47axchf
  text: |-
    ### test — green
    - evidence: `swift build --build-tests -Xswiftc -warnings-as-errors` — build OK, no warnings. `Scripts/swift-test.sh --skip IntegrationTests` — 1021 tests in 96 suites passed (1 known issue, the pre-existing BoundedWaitTests issue), plus 77 tests in 9 suites passed. No fail. No skip.
    - next: ready for review.
  timestamp: 2026-08-19T23:26:32.570896+00:00
position_column: doing
position_ordinal: '8580'
title: '[Router] A later resolve that reuses a resident generation model is priced at zero, including the KV cache its own new sessions add'
---
Found while implementing `^pq5w87d`. That card made the pool hold exactly what `JointFit` reserved for each trio, so the two figures now agree. But the reservation itself has a sibling gap ACROSS resolves.

## The gap

`Router.footprintBytes(for:context:metadataByRef:membership:residentKeys:)` answers `0` for a candidate whose exact `ResidencyKey` is already resident. That discount is correct for the WEIGHTS: the pool already charges them. It is not correct for the KV cache: the pool entry's charge covers the sessions of the profiles that already hold it, and the new profile's own sessions materialize NEW caches on the same container.

Concretely: profile A holds model M as its standard slot (the pool charges weights + one KV). Profile B resolves and also names M for its standard slot. `JointFit` charges B zero for M, so the box is sized without B's KV cache. Within ONE resolve `evaluateCandidate` already handles this through `chargedKeys` + `sessionBytes` (`^8hs4wrw`); across resolves the residency discount hides the same term.

## Scale

One KV term for each generation slot a LATER profile puts on an already-resident model. At the `multitool-cli-demo` shape (27B at context 32768) that is about 2.1 GB for each such slot.

## Shape of a fix

The `footprint` closure the router injects into `JointFit.resolve` must answer the session KV cache — not zero — for a resident generation key. The embedding interpretation stays zero (no KV term). The pool then also has to hold that charge, which `^pq5w87d`'s `chargedBytes` plumbing already supports: the acquisition's charge is read from `CandidateReport.chargedBytes`, so a correct charge flows through the pool with no further pool change.

## Acceptance Criteria

- [x] A resolve that reuses a resident generation key is charged one session KV cache, not zero
- [x] A resolve that reuses a resident embedding key stays charged zero
- [x] A test resolves profile A, then profile B naming A's generation model, and pins the budget a third resolve sees to include B's KV term #defect #router