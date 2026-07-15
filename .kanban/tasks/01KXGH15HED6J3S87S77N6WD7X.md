---
comments:
- actor: claude-code
  id: 01kxhmawcrqj6fxprd2tf1ysdf
  text: |-
    Implemented the context ladder in JointFit.resolve per the model-outer/context-inner policy.

    Design:
    - JointFit.resolve gained a nativeMaxContext closure param and the footprint closure now takes (ModelRef, Int) instead of ModelRef, so JointFit can query footprint at multiple context rungs.
    - resolveAtFixedContext(): unchanged single-rung behavior, used verbatim when profile.context is explicit (bypasses the ladder entirely, nativeMaxContext never invoked).
    - resolveViaLadder(): the new outer/inner loop. Outer loop walks profile.standard candidates in preference order (unchanged from today). For each candidate, contextLadder(nativeMaxContext:) builds [min(native, cap)] + step-downs (131072/65536/32768/16384/8192/4096) strictly below the top rung. Inner loop tries attemptTrio (embedding full list + this one standard candidate + flash full list, all at that context) largest-rung-first; first fitting rung wins. First standard candidate with any fitting rung wins outright — later candidates are never even tried (this is what makes it model-outer, not context-outer).
    - SlotResolution gained contextTokens: Int (defaulted to ProfileDefinition.defaultContext for old direct-construction call sites in integration tests). CandidateReport gained ladderAttempts: [LadderAttempt] (default []), populated only for standard-slot candidates walked via the ladder. New LadderAttempt type: contextTokens, estimatedFootprintBytes (this candidate's own figure at that rung), fits (whole-trio success at that rung, not just this candidate).
    - ResolutionFailure.description renders ladder attempts nested under each candidate line.
    - RouterManifest.ResolvedProfile gained context: Int (the standard slot's resolved contextTokens, since context is one shared profile-wide value across all 3 slots).
    - Router.swift: replaced both `def.context ?? ProfileDefinition.defaultContext` TODO fallbacks. sizeCandidates now fetches+caches RepoMetadata per ref (not footprint bytes at one fixed context), enabling footprint(ref, context) to be computed for any rung on demand. slotMembership/footprintBytes replicate the old preferLarger cross-slot-interpretation-max behavior (e.g. a ref used in both embedding and standard is sized under both interpretations, larger wins) but now parameterized by context. The download loop now reads the actually-resolved context off resolution.slots via Self.slotResolution(...).contextTokens instead of the temporary fallback.

    Tests: JointFitTests.swift — updated all 8 existing tests to the new closure shapes (all use explicit context 8192 so ladder never runs; added a neverCalledNativeMaxContext closure to prove the bypass). Added 5 new ladder tests: native-max-fits, step-down-fits, model-outer-preference (the acceptance-criteria scenario: bigger model at 32768 beats smaller model that would fit at 131072), nothing-fits-at-any-rung (ResolutionFailure with full per-candidate ladder detail), explicit-context-bypass. Also added one Router-level integration test (ResolveTests.swift: routerDerivesContextViaLadderAndPrefersModelOuter) using real config.json/tree.json fixtures through StubProbe+ScriptedMetadataSource+StubModelLoader, verifying the full Router.resolve() pipeline derives context 32768 and prefers the bigger model — this is the "fake metadata and probe" scenario the acceptance criteria describe. Also added a manifest.json context assertion to TranscriptNestingTests.swift's existing manifest test.

    swift test: 349 unit / 15 gated, all green, zero warnings (up from 343/15 — 6 new tests, no regressions). swift build clean, zero warnings on our own code (the one warning present is a pre-existing mlx-swift_Cmlx build-system cache message unrelated to this change).
  timestamp: 2026-07-15T00:55:23.288422+00:00
- actor: claude-code
  id: 01kxhmrp190av51zgm3bt2vrg4
  text: |-
    really-done: swift test re-run fresh, 349 unit / 15 gated, all green, zero warnings. Adversarial double-check agent verdict: PASS (independently re-ran build+test, read all touched files, verified outer/inner loop semantics, budget arithmetic, bypass-never-invokes-nativeMaxContext, contextTokens correctness on both success/failure paths, and edge cases).

    One minor non-blocking observation from the double-check: RouterManifest.ResolvedProfile.context has no default value (unlike SlotResolution.contextTokens, which defaults to ProfileDefinition.defaultContext for backward source-compat), so decoding an old on-disk manifest.json written before this change would fail to decode the new field. Accepting as-is: manifest.json is a disposable, best-effort run record the router only ever writes fresh each run — nothing in the codebase reads a manifest.json back in production, only a test that decodes what it just wrote in the same run. No live blast radius.

    Task is green and left in `doing` per the /implement workflow contract — ready for /review.
  timestamp: 2026-07-15T01:02:55.529259+00:00
depends_on:
- 01KXGH0HW8S82DM6YEFF6A4HM6
position_column: doing
position_ordinal: '80'
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
- [x] With fake metadata and probe: when the budget forces it, the bigger model at 32768 is chosen over the smaller model at 131072 (model-outer verified)
- [x] Native max fits: candidate resolves at native max (capped)
- [x] Explicit context: ladder never runs
- [x] manifest.json includes the resolved context; failure diagnostics list ladder attempts per candidate

## Tests
- [x] JointFit unit tests over fake MetadataSource and MachineProbe: native fits; step-down fits; nothing fits on any candidate at any rung yields ResolutionFailure with ladder detail; explicit-context bypass; model-outer preference case
- [x] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness