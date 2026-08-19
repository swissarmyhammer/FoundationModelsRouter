---
assignees:
- claude-code
position_column: todo
position_ordinal: '9980'
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

- [ ] A resolve that reuses a resident generation key is charged one session KV cache, not zero
- [ ] A resolve that reuses a resident embedding key stays charged zero
- [ ] A test resolves profile A, then profile B naming A's generation model, and pins the budget a third resolve sees to include B's KV term #router #defect