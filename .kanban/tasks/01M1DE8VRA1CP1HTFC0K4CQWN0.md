---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1deprh12dvt4jmgessx94ma
  text: |
    Research, before the edit.

    **One keyword is enough.** `RestoredSession` is already `public`, at
    `SessionRestoration.swift`. The constant stands in
    `extension RestoredSession`, and that extension carries no access
    modifier. Swift then lets one member state `public` for itself. The
    compiler confirmed the starting state word for word:
    `internal static let instructionsDivergencePhrase: String` inside
    `struct RestoredSession`. No second keyword is needed.

    **The doc comment did not state why a consumer pins the symbol.** It
    named the grep target and said what the phrase covers. It never said
    that a consumer outside this package holds the phrase in a test. The
    new paragraph states that.

    **The house pattern for this test already exists.** Nine test files use
    a plain `import FoundationModelsRouter`, with no `@testable`. Five of
    them are named `*PublicSurfaceTests.swift`. Each states the same idea:
    the plain import makes the compiler the first assertion, because a
    symbol that loses `public` stops the file compiling. The new test
    follows that pattern.

    **Where the test lives.** The unit target, not `IntegrationTests/`. The
    test needs no external system and it runs in 0.001 seconds. The
    `IntegrationTests` package holds the real-model suites only.

    **What the existing tests already hold.** `SessionRestorationTests`
    asserts that a real divergence event text contains the constant. It
    reads the constant, so it cannot see a phrase edit. The new test holds
    the literal, so the two together hold the whole contract: the event
    carries the phrase, and the phrase is the exact saved grep target.
  timestamp: 2026-09-01T03:02:50.657540+00:00
- actor: claude-code
  id: 01m1deq1njr057f5bqgeejryvg
  text: |
    Both red states were proved, in order.

    **Red 1, the access level.** The test file was written first and run
    against the internal constant. The build broke:

        InstructionsDivergencePhrasePublicSurfaceTests.swift:28:33: error:
        'instructionsDivergencePhrase' is inaccessible due to 'internal'
        protection level

    That proves the plain import binds the public surface only.

    **Green.** `public` on the constant. The test passed:
    `Test run with 1 test in 1 suite passed after 0.001 seconds`.

    **Red 2, the phrase edit.** The phrase was edited to
    `"restored session instructions differ from the recorded ones"` and the
    test was run again:

        ✘ Test "the published phrase is the exact text a saved grep looks
        for" recorded an issue at
        InstructionsDivergencePhrasePublicSurfaceTests.swift:28:9:
        Expectation failed:
        RestoredSession.instructionsDivergencePhrase == Self.savedGrepTarget
        ↳ RestoredSession.instructionsDivergencePhrase == Self.savedGrepTarget → false
        ↳   RestoredSession.instructionsDivergencePhrase → "restored session instructions differ from the recorded ones"
        ↳   Self.savedGrepTarget → "restored session instructions differ from the recorded instructions"

    The phrase was then restored. `git diff --stat` reports one file, 7
    insertions and 1 deletion, so the experiment left nothing behind. The
    one deletion is the `static let` line the `public` keyword replaced.
    The phrase line itself is untouched.
  timestamp: 2026-09-01T03:03:00.018804+00:00
- actor: claude-code
  id: 01m1deq8v0sdp0mgt0366cx1a0
  text: |
    ### implement — changed
    - evidence: 2 files — `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift` (the `public` keyword and the paragraph that states why), `Tests/FoundationModelsRouterTests/InstructionsDivergencePhrasePublicSurfaceTests.swift` (new, 1 test). The phrase edit failed with `Expectation failed: RestoredSession.instructionsDivergencePhrase == Self.savedGrepTarget`, `→ "…the recorded ones"` against `→ "…the recorded instructions"`. `swift test`: 1159 tests in 128 suites, plus 83 tests in 10 suites, exit 0, 2 known issues — the baseline of 1158 in 127 plus this one new test in its own suite. `swift build --package-path IntegrationTests --build-tests`: `Build complete!`, exit 0. `git status --porcelain` holds no trace of the phrase experiment.
    - next: `/review`
  timestamp: 2026-09-01T03:03:07.360693+00:00
position_column: doing
position_ordinal: '80'
title: Publish the instructions divergence phrase, because the doc names it a grep target
---
## What

`instructionsDivergencePhrase` is `static let` with no `public`, at
`Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:52`.

The doc comment above it says a person greps committed transcripts for
that exact text. So the phrase is a documented contract. A consumer
cannot pin a contract it cannot name.

## Why this is worth one keyword

A stable grep target that no test outside this package holds can change
in a refactor. Every saved grep then finds nothing, and the record looks
empty rather than broken. The person who loses is the transcript reader,
which is the same reader the divergence event exists for.

Publishing the phrase lets a consumer assert on it, so drift fails a
build instead of failing quietly.

## Where this came from

The ACPAgent session raised it on 2026-09-01, after it read the source at
commit 587cfe7. It said plainly that it does not need the symbol: it
asserts on `TranscriptEvent.kind == .divergence`, which is public and
sufficient. It asked only because the doc names the phrase as the grep
target.

That reasoning is correct, and it is the same class of defect as the rest
of this work: a documented promise a consumer cannot verify.

## What to do

- Make `instructionsDivergencePhrase` public.
- Read its doc comment. If the comment does not say why a consumer would
  pin it, say so in one sentence.
- Add a test that pins the phrase. The test must fail if a person edits
  the phrase.

Do not change the phrase text. Saved greps depend on it now.

## Acceptance criteria

- [x] `instructionsDivergencePhrase` is public.
- [x] A test pins the exact phrase, and it fails when the phrase changes.
- [x] The doc comment states why the symbol is public.
- [x] `swift test` is green. The baseline is 1158 tests in 127 suites,
      plus 83 tests in 10 suites, exit 0, with 2 known issues.
- [x] `swift build --package-path IntegrationTests --build-tests` is
      green. Note: without `--build-tests` this command builds nothing.

## Note

`^w30hzsy` published the restore surface this phrase belongs to. Read
that card first for the divergence design. #api #recording #router