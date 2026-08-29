---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m16venbk5t8ss3fa47mq4xxe
  text: |-
    Research, before the change.

    The audit escape does not apply. Nothing shows that the four members were made internal on purpose:
    - `extension RoutedSession` (Sources/FoundationModelsRouter/Session/RoutedSession.swift) carries no access modifier. Three of its seven members state `public` one by one; the other four state nothing. A mixed extension of this shape is an omission, not a boundary.
    - The four members are thin wrappers over public requirements of the same public protocol.
    - Task ^hhtc4v7 measured the same cause and recorded it as a defect for this card.

    One consequence the card does not name: `enum PromptCancellationResult` (same file) is also internal by omission. Swift does not let a public method return an internal type, so `cancelPrompt(id:)` cannot become public until this enum becomes public. The enum has no other reader than `cancelPrompt(id:)` and the tests, thus widening it adds no risk. `SessionOutbox.ItemID`, `CompactionResult`, `TokenBudget` and `CompactionPrompt` are public already.

    The documentation route, from ^hhtc4v7:
    1. `swift build --target FoundationModelsRouter -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc <sgdir>`
    2. Copy only `FoundationModelsRouter*.symbols.json` into a clean directory.
    3. `xcrun docc convert Sources/FoundationModelsRouter/FoundationModelsRouter.docc --fallback-display-name FoundationModelsRouter --fallback-bundle-identifier com.swissarmyhammer.FoundationModelsRouter --additional-symbol-graph-dir <sgdir> --output-path <outdir>`

    The baseline ^hhtc4v7 left is 107 warnings, five of which this card must remove:
    - `'(String)' isn't a disambiguation for 'enqueue(prompt:)'` at RoutedSession.md:70
    - `'cancelPrompt(id:)' doesn't exist` at RoutedSession.md:80
    - `'compact()' doesn't exist` at RoutedSession.md:91
    - `'compact(prompt:)' doesn't exist` at RoutedSession.md:92
    - `'compact(budget:)' doesn't exist` at RoutedSession.md:93

    `compact(prompt:)` names a method that exists in no form. The file already lists `compact(prompt:budget:)` on the next line, thus the entry is a duplicate and is deleted, not corrected.

    The test target holds no plain-import test file yet, thus this card adds one.
  timestamp: 2026-08-29T13:30:55.731715+00:00
- actor: claude-code
  id: 01m16vy6q6e8vd2b8hn7h6sftm
  text: |-
    TDD, the red step. The new file `Tests/FoundationModelsRouterTests/RoutedSessionPublicSurfaceTests.swift` uses a plain `import FoundationModelsRouter`. Before the change, `swift build --build-tests` failed with exactly the errors the card predicts:

    ```
    RoutedSessionPublicSurfaceTests.swift:61:55: error: missing arguments for parameters 'prompt', 'budget' in call
    RoutedSessionPublicSurfaceTests.swift:79:48: error: missing argument for parameter 'prompt' in call
    RoutedSessionPublicSurfaceTests.swift:96:61: error: cannot convert value of type 'String' to expected argument type 'Transcript.Prompt'
    RoutedSessionPublicSurfaceTests.swift:110:61: error: cannot convert value of type 'String' to expected argument type 'Transcript.Prompt'
    RoutedSessionPublicSurfaceTests.swift:112:21: error: cannot find type 'PromptCancellationResult' in scope
    RoutedSessionPublicSurfaceTests.swift:112:70: error: 'cancelPrompt' is inaccessible due to 'internal' protection level
    ```

    The compiler saw the public overloads only: `compact(prompt:budget:)` in place of `compact()` and `compact(budget:)`, and `enqueue(prompt: Transcript.Prompt)` in place of `enqueue(prompt: String)`.

    The green step. Five declarations in `Sources/FoundationModelsRouter/Session/RoutedSession.swift` become `public`, each on the member and not on the extension, which is the pattern the three public siblings already use:
    - `compact()`
    - `compact(budget:)`
    - `enqueue(prompt: String)`
    - `cancelPrompt(id:)`
    - `enum PromptCancellationResult` — required, because Swift does not let a public method return an internal type.

    The four tests then pass. Each one drives a scripted fixture and asserts on what the member did:
    - `compact()` measures the live transcript against the session's own working context, applies no stage and keeps `tokensAfter == tokensBefore`.
    - `compact(budget:)` folds against `AutoCompactionFixtures.fixedBudget`, applies the `Summarization` stage, and shrinks the transcript.
    - `enqueue(prompt:)` stages the plain text, which the test reads back off `pendingPrompts()`.
    - `cancelPrompt(id:)` reports `.withdrawn` and empties the queue.

    The audit found no sibling with the same defect: the other `extension RoutedSession`, in `Session/TurnOutcome.swift`, already states `public` on its one member.

    SwiftLint reports four findings on `RoutedSession.swift` — one `file_length` (411 of 400) and three `line_length` on lines 34, 67 and 342. All four are the same at `HEAD`. The change adds no line and no character to any of them.
  timestamp: 2026-08-29T13:39:25.030379+00:00
- actor: claude-code
  id: 01m16vyesk4x6xxm8fhtv35y4g
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md, Tests/FoundationModelsRouterTests/RoutedSessionPublicSurfaceTests.swift (new, plain `import FoundationModelsRouter`). `swift build`: Build complete, exit 0. `swift test`: exit 0, 1103 tests in 116 suites passed, plus 83 tests in 10 suites in the evals target; the 2 known issues are pre-existing `withKnownIssue` blocks in BoundedWaitTests and RealModelHarnessTests, which the change does not touch. DocC by the symbol-graph route of ^hhtc4v7: 91 warnings before, 85 after, 0 added; `RoutedSession.md` now has 0 warnings. The 6 removed warnings are the 5 the card names plus `'cancelPrompt(id:)' doesn't exist at '/FoundationModelsRouter/RoutedSession/cancel(id:)'`, which came from the doc comment of `cancel(id:)` in the source file and had the same cause.
    - next: /review
  timestamp: 2026-08-29T13:39:33.299220+00:00
- actor: claude-code
  id: 01m16w4zbfwf243kb1ftbvdvth
  text: |-
    ### test — green
    - evidence: `swift test` — 1103 tests in 116 suites passed (2 known issues, both pre-existing intentional `withKnownIssue` cases unrelated to this task: `BoundedWaitTests` and `RealModelHarnessTests`), plus a second bundle with 83 tests in 10 suites passed. 0 failures. 0 skipped tests in the repo. 0 compiler warnings in `Sources/` or `Tests/`.
    - Verified the new `Tests/FoundationModelsRouterTests/RoutedSessionPublicSurfaceTests.swift` suite (4 tests, no `@testable import`) compiled and passed, which proves the four `extension RoutedSession` members (`compact()`, `compact(budget:)`, `enqueue(prompt:)`, `cancelPrompt(id:)`) and `enum PromptCancellationResult` are truly `public`.
    - Verified the diff scope with `git diff --stat`: only `Sources/FoundationModelsRouter/Session/RoutedSession.swift` (the `public` additions), `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` (the removed `compact(prompt:)` Topics entry, which names no existing symbol), and the new test file.
    - next: ready for review.
  timestamp: 2026-08-29T13:43:06.863164+00:00
- actor: claude-code
  id: 01m16w60xk3t4x0tk74jp9g14y
  text: |-
    ### commit — changed
    - evidence: ea78b34e2c15f927fe2fed15cc229a1729d7d751, 7 files changed, 246 insertions(+), 17 deletions(-)
    - next: none
  timestamp: 2026-08-29T13:43:41.235904+00:00
- actor: claude-code
  id: 01m16wc4jtdfbfcj4mspk4s8ff
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit ea78b34) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. No prior findings open.
    - next: task moved to done.
  timestamp: 2026-08-29T13:47:01.594036+00:00
- actor: claude-code
  id: 01m16wcknsf4n2e8cd577wpmbc
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files; DocC warnings 91 before, 85 after, 0 added
    - test: green — swift test, 1103 tests in 116 suites plus 83 in 10 suites, 0 failures, 0 skipped
    - commit: ea78b34 — 7 files
    - review: clean — zero findings; task moved to done
  timestamp: 2026-08-29T13:47:17.049523+00:00
position_column: done
position_ordinal: ffff9c80
title: Publish the RoutedSession convenience extension members
---
## What

`extension RoutedSession` (Sources/FoundationModelsRouter/Session/RoutedSession.swift:317) carries no access modifier, so the members that do not state one are `internal`. The extension is a mix:

Public today: `respond(to:)` (line 334), `streamResponse(to:)` (line 339), `streamEvents(to:)` (line 344).

Internal today, and the defect: `compact()` (line 320), `compact(budget:)` (line 329), `enqueue(prompt: String)` (line 351), `cancelPrompt(id:)` (line 365).

The four internal members are convenience wrappers over public requirements of the same public protocol — `compact(prompt:budget:)`, `enqueue(prompt: Transcript.Prompt)`, `cancel(id:)` and `cancelCurrentTurn()` — exactly as their three public siblings are. The protocol's own doc comments present them as caller surface: `cancelCurrentTurn()` points the reader at ``cancelPrompt(id:)`` for the combined behavior. A consumer with a plain import can call `respond(to:)` but not `compact()`, which is not a defensible boundary.

Make the four members `public`, so the extension matches the protocol it extends.

This also repairs five DocC warnings in `FoundationModelsRouter.docc/RoutedSession.md` that task ^hhtc4v7 could not fix: the `## Topics` entries for `compact()`, `compact(budget:)` and `cancelPrompt(id:)`, and the disambiguation warning on `enqueue(prompt:)`. One Topics entry names `compact(prompt:)`, which exists in no form — correct it to the protocol requirement `compact(prompt:budget:)` or remove it.

If the audit shows any of the four was made internal deliberately, do not widen it: record the reason on this task and leave that one member as it is.

## Acceptance Criteria
- [x] `compact()`, `compact(budget:)`, `enqueue(prompt: String)` and `cancelPrompt(id:)` are callable through a plain `import FoundationModelsRouter`.
- [x] The `RoutedSession.md` Topics entries for those members resolve, and no entry names a method that does not exist.
- [x] The DocC warning count falls by the five named warnings, with no new warning.

## Tests
- [x] Add the calls to `Tests/FoundationModelsRouterTests/GuidedPublicSurfaceTests.swift`, or a new plain-import test file if that one does not exist yet. A plain `import FoundationModelsRouter` (no `@testable`) makes the compiler itself prove the surface is public.
- [x] Assert each of the four members runs against the scripted fixtures, not only that it compiles.
- [x] Rebuild the documentation by the symbol-graph route in ^hhtc4v7 and compare the warning list before and after.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api