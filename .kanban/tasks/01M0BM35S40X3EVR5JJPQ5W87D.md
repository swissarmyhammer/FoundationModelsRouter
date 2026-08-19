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
position_column: todo
position_ordinal: '9180'
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

- [ ] The bytes `Router` holds against the host budget for a shared key equal the bytes `JointFit` reserved for the same trio
- [ ] Releasing one of two slots on a shared key gives back only that slot's share
- [ ] A test resolves two profiles in order, the first naming one reference in both generation slots, and pins the budget the second one sees
#router #defect