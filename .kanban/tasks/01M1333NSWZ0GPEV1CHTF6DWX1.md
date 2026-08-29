---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m16zr5a8v51hqc09s82wr5kr
  text: |-
    Research notes for the next agent.

    Why the plain import costs more code than `ExamplesTests.swift` does:

    `LoadedLLMContainer` and `LanguageModelSessionBackend` are public protocols, but
    their default implementations sit in extensions with NO access modifier, so those
    defaults are `internal` and stop at the router module boundary. A conformer that
    uses a plain `import FoundationModelsRouter` therefore must write every member
    itself:

    - `LoadedLLMContainer`: `makeSession(instructions:tools:)`,
      `makeSession(transcript:tools:)`, and `languageModel`.
    - `LanguageModelSessionBackend`: `streamResponseFragments(to:maxTokens:)`,
      `makeFork(tools:)`, and `replacingTranscript(_:)`.

    `languageModel` is the hard one: its type is `any FoundationModels.LanguageModel`,
    and the scripted container has no model to give. The example implements it with
    `preconditionFailure`, which is exactly what the router's own internal default
    does. No source change was needed, so the card stayed inside its named files.

    Every helper in `Tests/FoundationModelsRouterTests/Helpers/` (`ScriptedSessionFixture`,
    `StubSessionBackend`, `ScriptedToolCallingModel`) uses `@testable import` and
    `InMemoryRecorder`, which is internal. None of them can be reused from a
    plain-import file. The example carries its own harness for that reason.

    The example asserts on real values. Proof: each of the 7 expectations was negated
    and re-run, and each one failed. Restored after.
  timestamp: 2026-08-29T14:46:01.288147+00:00
- actor: claude-code
  id: 01m170bp4zvmks2e6jng3azy5v
  text: |-
    Design decision, so the next agent does not undo it.

    The harness first carried its own `StubProbe`, `StubMetadataSource`,
    `StubEmbeddingContainer`, `StubModelLoader` and canned Hub metadata, copied from
    `ExamplesTests.ExampleHarness`. That was a duplication blocker: the same JSON and
    the same stubs already live in `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift`,
    and `ExampleHarness.rawMetadata` is `fileprivate`, so it cannot be shared.

    The harness now calls `RouterTestFixtures.makeRouter`, `RouterTestFixtures.profile()`,
    `RouterTestFixtures.makeTempDir` and `StubModelLoader` instead. It keeps only the two
    conformances the card is about: `ScriptedBackend` and `ScriptedContainer`.

    `RouterTestFixtures` is a `@testable` file, but that does not weaken the plain-import
    proof. The proof is about the router symbols THIS file names, and every one of them is
    public. `RouterTestFixtures.makeRouter` also has a default argument built from the
    router-internal `InMemoryRecorder`; Swift evaluates a default argument in the module
    that declares it, so a plain-import caller compiles. Measured, not assumed.

    Also removed: an unstructured `Task` that bridged `streamResponseFragments` into
    `streamResponse`. One generic `streamTurn(prompt:element:)` now serves both entry
    points, so there is no unstructured task and no duplicated stream body.

    Lint state of the new file, under the rules the review enforces
    (`missing_docs`, `no_magic_numbers`, `function_body_length`, `closure_body_length`):
    clean. No line is longer than 120 characters. The file declares nothing `public`, so
    `missing_docs` cannot reach it, and every number sits behind a named `static let`.
  timestamp: 2026-08-29T14:56:41.119134+00:00
- actor: claude-code
  id: 01m170bwwvcfsdn83tgqwkfktg
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterTests/ProjectionExampleTests.swift (new, 273 lines, plain `import FoundationModelsRouter`, 1 `@Test`, 7 expectations), Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md (new, 144 lines). `swift build` complete, no compiler warnings. `swift test`: 1106 tests in 118 suites passed, plus 83 tests in 10 suites passed; 2 known issues, both pre-existing `withKnownIssue` markers. TDD: the test passed on the first run because `SessionProjection` already exists, so each of the 7 expectations was negated and re-run; all 7 failed, then were restored. Two follow-up cards filed: ^3t0mbb1 and ^q8cnmb2.
    - next: /review
  timestamp: 2026-08-29T14:56:48.027228+00:00
- actor: claude-code
  id: 01m170mcmzfawdm7xsyy0xkn4d
  text: |-
    ### test — green

    - evidence: `swift test` (full run, twice in a row for confirmation) — FoundationModelsRouterTests: 1106 tests in 118 suites passed (2 known issues, both pre-existing `withKnownIssue` cases unrelated to this task); FoundationModelsRouterEvals: 83 tests in 10 suites passed. Zero failures, zero warnings in Sources/ or Tests/, zero skipped tests.
    - one run under load showed 2 failing tests: `GenerationStallDiagnosticTests` ("a streaming turn reports the stall against the fragments it counted", the known flaky card ^q8cnmb2) and `TurnCancellationTests.cancelledProactiveFoldReportsNoCompaction`. Re-ran both in isolation: both passed. Two later full-suite runs on a quiet machine were both green with no failures at all. No test was changed or weakened.
    - `HumanWaitGateTests` and `GenerationStallDiagnosticTests` also re-run in isolation directly, per instruction: both green (`swift test --filter 'FoundationModelsRouterTests.HumanWaitGateTests'`, `swift test --filter 'FoundationModelsRouterTests.GenerationStallDiagnosticTests'`).
    - build check: `swift build` and `swift build --build-tests` after touching the changed/new files to force recompilation — no warnings from Sources/ or Tests/, only one pre-existing warning from the mlx-swift dependency build (`missing creator for mutated node ... mlx-swift_Cmlx.bundle`), not our code.
    - no skipped or disabled tests found in Tests/ (`.disabled(`, `XCTSkip` — no matches).
    - scope confirmed: only two new files present for task ^tf6dwx1 — `Tests/FoundationModelsRouterTests/ProjectionExampleTests.swift` (plain `import FoundationModelsRouter`, confirmed) and `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md`. No test was edited or deleted.
    - next: none — suite is clean.
  timestamp: 2026-08-29T15:01:26.303931+00:00
position_column: doing
position_ordinal: '80'
title: Add an example that binds SessionProjection
---
## What

`SessionProjection` (Sources/FoundationModelsRouter/Session/SessionProjection.swift:33) is public, `@Observable`, and documented for SwiftUI binding — but no example, tool, or README line uses it. It is the largest public surface with no external exercise (~34 members). Keep it public, and give it a consumer.

- Add the example in a NEW file, `Tests/FoundationModelsRouterTests/ProjectionExampleTests.swift`, with a plain `import FoundationModelsRouter`. Do not put it in `ExamplesTests.swift`: that file's line 5 is `@testable import FoundationModelsRouter`, which is file-scoped and cannot be opted out of per declaration, so the plain-import proof would be impossible there.
- Drive a scripted session, feed `streamEvents(to:)` into `SessionProjection.apply(eventsFrom:)`, and read the projected transcript rows and phase.
- The example is the documentation: write it as display-quality code with a doc comment, in the style of the examples in `ExamplesTests.swift`.
- Create a new DocC page `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md` that shows the binding pattern and links `SessionProjection`. A new file, so it does not collide with the tasks that edit `RoutedSession.md`.
- Do not add a runnable GUI target; the offline example plus DocC is the scope.

## Acceptance Criteria
- [x] `ProjectionExampleTests.swift` exists, uses a plain `import FoundationModelsRouter`, and holds an example a reader can copy into a SwiftUI app.
- [x] The example compiles against the public surface only, which the plain import proves.
- [x] `SessionProjection.md` exists and links `SessionProjection`.

## Tests
- [x] The example is itself a test: it asserts the projected rows and the end phase after the scripted turn.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #examples #docs