---
position_column: todo
position_ordinal: '80'
title: LiveModelLoader gives the footprint of its model loader to an Extras pool
---
## What
`LiveModelLoader` conforms to `PooledModelLoader`, but it does not implement `footprintBytes(of:)`. Thus it uses the Extras default, which gives 0. An application that gives a `LiveModelLoader` to an Extras `ModelPool` (the type doc tells about this use) gets a footprint of 0 bytes for each model, and the budget of the pool counts no weights.

The Router path does not use this measure: `SlotPoolLoader` gives `footprintBytes` to `admission.acquire`. The gap is only on the direct pool path.

Found during ^1056ce6.

## Acceptance Criteria
- [ ] `LiveModelLoader.footprintBytes(of:)` gives the value of its model loader (`MLXModelLoader` measures the weights in its cache folder).

## Tests
- [ ] A unit test with a stub model loader that gives a known footprint, through a `LiveModelLoader`.
- [ ] `swift test` passes with zero failures and zero warnings.