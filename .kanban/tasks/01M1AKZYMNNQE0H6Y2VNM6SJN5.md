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
- actor: claude-code
  id: 01m1amdfrtshmcj0r3n9m68naw
  text: |-
    Validator rules checked against the diff before reporting. All four questions that could touch a comment-and-assertion edit resolve clean:

    - `function-length-swift` — threshold is 250, and the rule states the count is "excluding comments and whitespace". The 9 added comment lines move the count by zero. `endToEnd()` is 213 lines in total, well under, and it carries no `swiftlint:disable` directive that a new comment could separate from its `func` line.
    - `missing-docs-swift` — reads access level and doc-comment presence only, so it cannot apply to a change that adds no declaration. Checked the residual it does catch: the file has no `public` or `open` declaration (every helper is `private`), and there is no `.swiftlint.yml` in the repository.
    - Comments — there is NO rule about stale comments, comments restating code, or naming ticket/card ids in comments. The only comment rule is `no-commented-code`, which governs disabled code: "A block that reads as English is prose however much punctuation it carries." Both new blocks are 6 lines, over the 5-line exemption, and both read as English sentences, so neither is commented-out code.
    - `test-integrity` — no rule forbids a negative assertion. The polarity flip keeps the same exact predicate, so it is not the "weakened assertion" the rule describes (an exact value turned into "is not empty"). It is not trivial either: it names one enum case over one real collection and can fail.

    One load-bearing point worth recording for the next reader: `#expect(!merged.isEmpty)` is not decoration beside the new absence check, it is what makes the absence check mean anything. An absence assertion over a possibly-empty collection proves nothing; that kept line rules out the empty case. The card required keeping it, and this is why. Do not remove it.
  timestamp: 2026-08-31T00:44:54.938887+00:00
- actor: claude-code
  id: 01m1amdj283fxe9tvzja5a1bfj
  text: |-
    ### commit — changed
    - evidence: 4162da1 test(integration): expect no embedding transcript event; pushed to origin/main (bc95716..4162da1)
    - next: CI must confirm the integration job is green on this push.
  timestamp: 2026-08-31T00:44:57.288677+00:00
- actor: claude-code
  id: 01m1amds0pa0wdm12d42rd5d3s
  text: |-
    ### implement — changed
    - evidence: 1 file, +15/-6 — `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`. Assertion inverted to `#expect(!merged.contains { $0.kind == .embedding })`; three comments rewritten to the current contract, each naming card ^p3x0bbb (step 3, step 6, and the suite doc comment the card did not list). Kept `#expect(!merged.isEmpty)`, `#expect(dimension > 0)`, `#expect(vectors.count == 2)`, `#expect(vectors.allSatisfy { $0.count == dimension })`. No file under `Sources/` changed; `a66e1e5` not reverted.
    - verified locally: `swift build --package-path IntegrationTests --build-tests` → "Build complete!", exit 0. `swift test` at the root → 1132 tests in 125 suites passed plus 83 tests in 10 suites passed, 0 failures, unchanged from the pre-edit baseline (same 2 pre-existing known issues).
    - NOT verified locally: the integration test itself never ran. That job needs real model downloads and a GPU this machine does not have. CI is the measurement.
    - next: `/review`.
  timestamp: 2026-08-31T00:45:04.406772+00:00
- actor: claude-code
  id: 01m1ap2dsj1dpw4d4cbf38r6f9
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 4162da1) — 0 findings, 0 confirmed, 0 refuted; 7 validators attempted, 0 failed, 0 skipped. 1 file reviewed: IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift (+15/-6). The 2 .kanban files are excluded by .reviewignore.
    - next: none. Task moved to done. No section of `## Review Findings` was open before this pass, and this pass added none.
  timestamp: 2026-08-31T01:13:49.618504+00:00
- actor: claude-code
  id: 01m1ap377r9x0pstp9eb5aw544
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 1 file, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift, +15/-6; nothing under Sources/
    - test: green — `swift test` 1132 tests in 125 suites + 83 tests in 10 suites, exit 0; `swift build --package-path IntegrationTests --build-tests` builds
    - commit: 4162da1 — test(integration): expect no embedding transcript event
    - review: clean — 0 findings, 7 validators, task moved to done

    **CI is green.** Run 33345485703 for `4162da1`, both jobs:

    ```
    ci / Build & test                             completed/success
    ci / Integration (opt-in, real dependencies)  completed/success
    ```

    That run is the authoritative verification. The integration suite needs real model
    downloads and a GPU, so it cannot run on a development machine; the local checks
    above prove the file builds and the unit suite is unharmed, and nothing more.

    CI had been red for four commits before this: `c380151`, `760ae89`, `b26ee0f` and
    `c5542a1`, each on this same one test, with the unit job passing every time.

    The implementer corrected a fourth statement of the old contract that this card did
    not list — the suite doc comment said embedding came "with its transcript event".
    Leaving it would have made the file promise the event in prose while asserting its
    absence in the body.

    One note carried from the implementer, worth keeping: `#expect(!merged.isEmpty)` is
    load-bearing beside the new assertion, not decoration. An absence assertion over a
    collection that might be empty proves nothing, and that line is what rules the empty
    case out. Do not drop it in a later tidy-up.
  timestamp: 2026-08-31T01:14:15.672223+00:00
position_column: done
position_ordinal: ffffab80
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