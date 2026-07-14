---
depends_on:
- 01KXGH0HW8S82DM6YEFF6A4HM6
position_column: todo
position_ordinal: '8680'
title: 'JointFit: derive context via ladder — model choice outer, context inner'
---
## What
When profile context is nil, Resolution/JointFit.resolve derives it. Policy decided 2026-07-14: MODEL CHOICE IS THE OUTER LOOP — walk candidates biggest-first exactly as today, and for each candidate trio run context as the INNER loop. Prefer the biggest model at any acceptable context over a smaller model at a huge context; no minimum floor beyond the ladder end.

- Ladder per candidate: start at min(nativeMaxContext of the standard-slot candidate, cap), then step down 131072, 65536, 32768, 16384, 8192, 4096 (skip rungs above native max)
- First candidate trio with ANY fitting rung wins, taking the LARGEST fitting rung
- Explicit profile context bypasses the ladder entirely (single-rung behavior, exactly today)
- Record the resolved context in SlotResolution diagnostics and manifest.json so consumers (the coding harness frontends) can display it
- ResolutionFailure diagnostics enumerate per-candidate ladder attempts so a failure explains itself

## Acceptance Criteria
- [ ] With fake metadata and probe: when the budget forces it, the bigger model at 32768 is chosen over the smaller model at 131072 (model-outer verified)
- [ ] Native max fits: candidate resolves at native max (capped)
- [ ] Explicit context: ladder never runs
- [ ] manifest.json includes the resolved context; failure diagnostics list ladder attempts per candidate

## Tests
- [ ] JointFit unit tests over fake MetadataSource and MachineProbe: native fits; step-down fits; nothing fits on any candidate at any rung yields ResolutionFailure with ladder detail; explicit-context bypass; model-outer preference case
- [ ] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness