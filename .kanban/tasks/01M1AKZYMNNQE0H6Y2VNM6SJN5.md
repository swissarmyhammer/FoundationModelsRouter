---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1am33w3sekeftpnc6zx86cm
  text: |-
    Picked up. Research confirms the card's diagnosis exactly.

    - `a66e1e5` message: "It does not time the call and it does not write a transcript event. ... Keep TranscriptEvent.Kind.embedding. Old recordings that have this kind still decode. Refs ^p3x0bbb".
    - `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift` keeps `case embedding` with the doc "An embedding was produced. No longer written: an embed call is no part of any session's conversation. Kept so recordings made before that change still decode."
    - The unit contract now reads, in `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`: "The embed call recorded nothing, so there is no embedding body at all." `#expect(!events.contains { $0.kind == .embedding })`.
    - The replacement signal is a span. `Tests/FoundationModelsRouterTests/EmbedTracingTests.swift` says so in its suite doc: "Card ^p3x0bbb took the `.embedding` transcript event away, so an embed call writes nothing to the transcript. A span is the replacement signal, and this suite holds its whole contract".

    Prevailing comment convention for card ids in `IntegrationTests/` is `task ^xxxxxxx` or `card ^xxxxxxx`, used widely in the compaction suites. The rewritten comments will follow it.
  timestamp: 2026-08-31T00:39:15.075487+00:00
- actor: claude-code
  id: 01m1am843gw37r8kgm4721pr95
  text: |-
    Implementation landed in one file: `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`. Nothing under `Sources/` changed, and `a66e1e5` is untouched.

    Four edits, not three. The card named three; a grep of the file for "embed" found a FOURTH statement of the same stale contract, in the suite doc comment:

        /// ... generation, embedding
        /// (with its transcript event), guided generation, ...

    Leaving that would have left the file stating the removed contract in prose while the body asserted its absence. The rule "a finding shows one example of a cause; remove that cause from the whole file" applies, so it is corrected the same way and now reads "(which writes no transcript event, since card ^p3x0bbb)".

    The edits:
    1. Suite doc comment — the "(with its transcript event)" clause, above.
    2. Step 3 comment — was "Embedding returns dimension-length vectors AND records an embedding transcript event." Now states that embed writes no transcript event, why (an embed call is no part of any session's conversation), that card ^p3x0bbb took it away, that a span is the replacement signal held by `EmbedTracingTests`, and that step 6 asserts the absence.
    3. Step 6 comment — was "The embedding event landed in the recordings tree." Now states the absence is the contract rather than a defect, names card ^p3x0bbb, explains that `TranscriptEvent.Kind.embedding` survives only for decoding older recordings, and points at `MergedAndRedactionTests` for the same absence on the unit path.
    4. The assertion — `#expect(merged.contains { $0.kind == .embedding })` became `#expect(!merged.contains { $0.kind == .embedding })`, matching the unit test.

    Kept, as the card requires: `#expect(!merged.isEmpty)`, `#expect(dimension > 0)`, `#expect(vectors.count == 2)` and `#expect(vectors.allSatisfy { $0.count == dimension })`.

    Verified locally:
    - `swift build --package-path IntegrationTests --build-tests` — "Build complete!", exit 0.
    - `swift test` at the root — 1132 tests in 125 suites passed, plus 83 tests in 10 suites passed, 0 failures. Identical to the baseline taken before the edit (same 2 pre-existing known issues).
    - `git status --porcelain -- Sources IntegrationTests` lists only the one integration test file.

    NOT verified locally, and this is the point of the card: the integration test itself never ran. That job needs real model downloads and a GPU, which this machine cannot do. CI is the measurement.
  timestamp: 2026-08-31T00:41:59.152347+00:00
position_column: doing
position_ordinal: '80'
title: Update the integration test that still expects an embedding transcript event
---
## What

CI is red, and has been for four commits: `c380151`, `760ae89`, `b26ee0f`, `c5542a1`.
The unit job passes on every one of them. One test in the gated integration suite
fails:

    IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift:506
    Test "resolve real profile, then generate, embed, guide, fork, and record"
    Expectation failed: merged.contains { $0.kind == .embedding }

This is a stale test, not a defect in the product.

## Why it fails

Commit `a66e1e5`, "refactor(embed): remove transcript recording from RoutedModel.embed"
(card ^p3x0bbb), took the recording away on purpose. Its message says so: the call
"does not time the call and it does not write a transcript event". The enum case stays
only so that older recordings still decode — see the comment at
Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:30-33.

That commit migrated the unit suite to the new contract, and
Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift:471 now asserts the
opposite of the integration test:

```swift
// The embed call recorded nothing, so there is no embedding body at all.
#expect(!events.contains { $0.kind == .embedding })
```

`a66e1e5` changed no file under `IntegrationTests/`. The unit job never runs that
suite, so the stale assertion stayed invisible until the integration job ran.

The replacement signal is a span, not a transcript event. See
Tests/FoundationModelsRouterTests/EmbedTracingTests.swift:11-13 and commit `dc902e6`.

Confirmed by git: `731a7ba` added the assertion and is an ancestor of `a66e1e5`;
`a66e1e5` is not an ancestor of the last green run `8a590bf`. So the test did pass
before, and the removal came after.

## What to do

Correct the integration test to the contract the package now keeps. Three things in
that file, all in the same test:

1. `IntegrationTests.swift:506` — the assertion. An embed writes no transcript event,
   so assert the absence, as the unit test does. Keep `#expect(!merged.isEmpty)` at
   :504: generation events do land there, and that line is what proves the recording
   tree works at all.
2. `IntegrationTests.swift:505` — the comment "The embedding event landed in the
   recordings tree" states the old contract. Rewrite it.
3. `IntegrationTests.swift:432-433` — the comment "Embedding returns dimension-length
   vectors AND records an embedding transcript event". Rewrite it. The vector
   assertion stays; only the recording half is wrong.

Say in the comment WHY the absence is correct, and name `^p3x0bbb`, so the next reader
does not read the absence as a defect.

Do not revert `a66e1e5`. The removal was deliberate, documented, and the unit suite
already holds the new contract.

## Acceptance Criteria
- [ ] The test asserts that an embed writes no `.embedding` transcript event.
- [ ] The test still asserts the embed returned vectors of the right dimension.
- [ ] `#expect(!merged.isEmpty)` stays, so a recording tree that wrote nothing at all
      still fails the test.
- [ ] The two stale comments state the current contract and name ^p3x0bbb.
- [ ] No file under `Sources/` changes. This is a test correction.

## Tests
- [ ] `swift build --package-path IntegrationTests --build-tests` builds.
- [ ] `swift test` at the root stays green.
- [ ] CI is green. The integration job needs real models and cannot run on this
      machine, so CI is the measurement. Push, then read the run.

## Note

This is the second time a change migrated the unit suite and left the gated
integration suite behind. The integration job runs only in CI, thus a local `swift
test` cannot see the gap. Worth remembering when a card changes a recording or event
contract. #router #tests #ci #integration