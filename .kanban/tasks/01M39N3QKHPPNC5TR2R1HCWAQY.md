---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39nzmvqex441tmf9pg5ynsf
  text: |-
    ### Default values — approval reported by a peer session (2026-09-24)

    The peer session foundationmodelsacpagent-e5 reports that the owner approved these three defaults as configurable starting points. The owner's words, as the peer quoted them: "those seem fine as configurable starting points".

    - window with no new line: 2,048 generated tokens;
    - minimum line length that counts in the test: 20 characters;
    - recoveries per turn: 2.

    Each value stays a configuration value that a host can change. Name each constant in the log.

    Status: this approval came through a peer session, not directly from the user of this session. The user of this session must confirm it before the implementation starts.
  timestamp: 2026-09-24T12:24:27.767396+00:00
- actor: claude-code
  id: 01m39qrz03ay1tjw3b3mrqjdan
  text: |-
    ### finish — skipped
    - reason: the three default values (2,048 tokens, 20 characters, 2 recoveries) came through a peer session. The user of this session has not confirmed them yet. Each hard-coded limit is the user's decision.
    - next: when the user confirms, run /finish ^1hcwaqy.
  timestamp: 2026-09-24T12:55:45.923910+00:00
- actor: claude-code
  id: 01m39rs3cef9c9rdn4ajekrtac
  text: |-
    ### Default values — confirmed by the user (2026-09-24)

    The user of this session confirmed the three values as DEFAULTS:
    - window with no new line: 2,048 generated tokens;
    - minimum line length that counts in the test: 20 characters;
    - recoveries per turn: 2.

    Requirement from the user: each value must be passable as an option. A host sets each value through the Router API (for example, a configuration struct next to `TokenBudget`, passed where the session is made). A value that the host does not pass uses the default. `enabled` is an option too, with default true.
  timestamp: 2026-09-24T13:13:18.990959+00:00
- actor: claude-code
  id: 01m39s6k2tzz1n1a7z5td6sdy9
  text: |-
    ### Research — what the code shows (implement step)

    - The stream snapshots of `LanguageModelSession` do NOT show the reasoning while it grows. A probe (a scripted executor that sends 5 reasoning lines, then 1 answer) gave 3 snapshots, all after the answer text. So `ResponseFragment` and `inFlightResponse()` cannot see a call that is in its reasoning.
    - `LanguageModelSession.transcript` is `Observable`, and it grows while the call is in flight: `Observations { session.transcript }` gave one value per reasoning line (entries 2, text "line 0", "line 0 line 1", ...). This works for the `respond` path and for the stream path. So the detector reads the live transcript through observation, not through a poll interval (a poll interval would be a new constant).
    - The engine drops the entries of a call that throws. So the stopped attempt must be rebuilt from the entries that the watch saw last, as `InFlightTranscript.rebuilt` does for a compaction yield.
    - The recording diff is positional and checks the boundary entry. When the render changes after the record, `persistedEntryCount` and `persistedBaseline` must move to the new render, as a compaction does. Then the record keeps the full entry and no divergence marker is written.
    - A restore rebuilds the render from the record, so a restored session gets the full reasoning entry back. This is outside the card; I will add a separate task.
    - Line rule chosen: a line counts when its trimmed length is at least `minimumLineLength`. Only the tokens of counted lines that repeat fill the window; short lines (```, """, ")") add nothing and cannot stop a call. The render keeps the text of each watched entry up to the end of the last new line, and drops what follows (the repeated part).
  timestamp: 2026-09-24T13:20:41.050939+00:00
- actor: claude-code
  id: 01m39t38d7spagq9axp3r2e69b
  text: |-
    ### Implementation landed (not committed)

    What the code does now:
    - `RepetitionDetection` (public, Codable, next to the session settings) has `isEnabled`, `windowTokens`, `minimumLineLength`, `recoveriesPerTurn`. Each default is a named constant: `defaultIsEnabled = true`, `defaultWindowTokens = 2_048`, `defaultMinimumLineLength = 20`, `defaultRecoveriesPerTurn = 2`. A host passes it through `SessionConfiguration.repetitionDetection` or the new last parameter `repetitionDetection:` of `RoutedModel.makeSession(...)`. A value that the host does not pass keeps its default. A fork inherits it. The sidecar records it, and a restore applies it again (an old sidecar gives the default).
    - `LanguageModelSessionBackend.transcriptUpdates()` (default: finishes at once). The live backend reads `Observations { liveSession.transcript }`. This works on the `respond` path and on the stream path, because the stream snapshots do not show the reasoning.
    - `RepetitionDetector` reads the reasoning and response entries of the attempt line by line. Only counted lines (trimmed length >= minimumLineLength) that repeat fill the window. A new line empties the window.
    - When the window fills, `noteRepetition` logs one line (category `RepetitionStop`). The line gives the generated tokens, the new lines of the counted lines, the share, the tokens with no new line, and each value by name (`repetitionDetection: isEnabled = ..., windowTokens = ..., minimumLineLength = ..., recoveriesPerTurn = ...`). Then it cancels `inFlightModelCall`.
    - `continueAfterRepetitionStop` has the shape of the ceiling-stop recovery. It emits `SessionEvent.repetitionStopped(RepetitionStop)`, rebuilds the attempt from the entries that the watch read (`InFlightTranscript.rebuilt(settledEntries:sources:...)`), and records it whole with `FinishReason.repeatedLines`. It then cuts the repeated part out of the render (`RepeatedPartRemoval`: each watched entry keeps its text up to the end of its last new line) and moves `persistedBaseline` to the render. When a recovery is left, it runs one more attempt with `repetitionStopContinuationPrompt`, up to `recoveriesPerTurn` per turn. A stop after the last recovery ends the turn.
    - No compaction is part of this recovery: the repeated part leaves the render in its own step.

    Limits of this work:
    - A restore rebuilds the render from the record, so a restored session gives the repeated part to the model again. New task ^gg49g5e.
    - The host FoundationModelsACPAgent switches over `SessionEvent` and `FinishReason`. It must add the new cases `.repetitionStopped` and `.repeatedLines`.

    ### implement — changed
    - evidence: new Sources/.../Session/RepetitionDetection.swift, RepetitionDetector.swift, RoutedSessionActorRepetitionWatch.swift. Changed: LiveModelLoader.swift, LanguageModelSessionBackend.swift, FinishReason.swift, SessionEvent.swift, SessionConfiguration.swift, RoutedLLM.swift, RoutedSessionActor.swift, RoutedSessionActorTurnExecution.swift, RoutedSessionActorTurnGating.swift, RoutedSessionActorRecording.swift, RoutedSessionActorForking.swift, CompactionYield.swift, SessionTreeRestoration.swift, GenerationCallUsage.swift, TurnOutcome.swift, SessionProjection.swift, Examples/MultiModelGeneration/main.swift, plus doc links. Tests added: RepetitionStopTests.swift (5 acceptance + 4 default tests), RepetitionDetectorTests.swift (6), Helpers/RepeatingReasoningModel.swift, one restore/fork test in SessionTreeRestorationTests. `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: 1367 tests in 155 suites passed (2 known issues from before this work). IntegrationTests package builds.
    - next: /review ^1hcwaqy
  timestamp: 2026-09-24T13:36:20.391060+00:00
- actor: claude-code
  id: 01m39t9jvzbwe9hb3d3etnpva6
  text: |-
    ### test — green
    - command: `swift build --build-tests` in the main package. Result: 0 errors, 0 warnings in this project's code.
    - command: `swift test` in the main package. Result: 1367 tests in 155 suites pass (2 known issues, expected, not new). 1 test in 1 suite pass. 19 tests in 3 suites pass. Total: 1387 tests pass, 0 fail, 0 skip.
    - command: `swift build --build-tests` in the `IntegrationTests` package. Result: 0 errors, 0 warnings in this project's code.
    - The one warning in each build comes from the `mlx-swift` dependency plugin ("missing creator for mutated node"). It is not in this project's code and is not new.
    - The new repetition-detector tests ran and passed: suite "The repetition detector reads the share of new lines" and suite "A generate call that repeats itself is stopped and recovered".
    - Note: `sourcekit-lsp` reported stale errors for the new files (`RepetitionDetection`, `RepetitionStop`, `RoutedSessionActorRepetitionWatch`, and callers). Each named symbol exists in the source. The real Swift compiler build shows 0 errors. The LSP index had not picked up the new files. No code change was needed for this.
    - next: none. The build is clean. No files were changed by this step.
  timestamp: 2026-09-24T13:39:47.711374+00:00
- actor: claude-code
  id: 01m39tarth21dvgc86fg5jwgmz
  text: |-
    ### commit — changed
    - evidence: b848dea feat(session): stop a generation call that repeats itself, with options and defaults (^1hcwaqy)
    - next: none
  timestamp: 2026-09-24T13:40:26.577830+00:00
- actor: claude-code
  id: 01m39v1233p31xb3f46qbdk441
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit b848dea). Counts: 1 finding, 1 confirmed, 2 refuted. Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift:300 (`duplication/duplication`: the `usage` function repeats `usageDelta` of RoutedSessionActorRecording.swift).
    - check of the user requirement: each value (`isEnabled`, `windowTokens`, `minimumLineLength`, `recoveriesPerTurn`) is a public `var` of `RepetitionDetection` with a public `init` that uses the named defaults (true, 2_048, 20, 2). A host passes it through `SessionConfiguration.repetitionDetection` and the `repetitionDetection:` parameter of `makeSession(...)`. This requirement is met.
    - not counted, by the user's decision: the restore path (^gg49g5e) and the FoundationModelsACPAgent handling of the new enum cases.
    - next: remove the `usage` function, use `usageDelta`, then /review ^1hcwaqy again. The task stays in review.
  timestamp: 2026-09-24T13:52:36.963196+00:00
- actor: claude-code
  id: 01m39v1j7hcy5z5ca2h9febkvn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 new source files, many changed; 9 + 6 + 1 new tests
    - test: green — swift test, 1387 passed, 0 failed, 0 skipped; IntegrationTests builds
    - commit: b848dea
    - review: findings — Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift:300 (duplication: `usage` duplicates `usageDelta`)
  timestamp: 2026-09-24T13:52:53.489772+00:00
- actor: claude-code
  id: 01m39v4t3vmh1xwjbmyyyqss4m
  text: |-
    ### Finding fixed: `usage` repeated `usageDelta`

    - Removed the private static function `usage(before:endingAt:)` from RoutedSessionActorRepetitionWatch.swift. `recordStoppedAttempt` now calls `Self.usageDelta(before: usageOfAttempt, after: backend.usageTokenCounts())` from RoutedSessionActorRecording.swift. The calculation is the same (after minus before), so the behavior does not change.
    - The doc comment of `recordStoppedAttempt` now tells why the call gives a baseline: the count of the replaced backend minus the usage of the attempt, so the finish records the usage of the attempt.
    - I searched the diff of b848dea for more copies of the tuple subtraction. This commit added no other copy.
    - No new test: this is a refactor with the same calculation. The suite "A generate call that repeats itself is stopped and recovered" runs this path, and it passes.
  timestamp: 2026-09-24T13:54:39.867103+00:00
- actor: claude-code
  id: 01m39v4w4fyqr33fnakdcz8fss
  text: |-
    ### implement — changed
    - evidence: 1 source file changed: Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift. `swift build --build-tests`: 0 errors, 0 warnings in this project's code (the known mlx-swift plugin warning only). `swift test`: 1367 tests in 155 suites pass (2 known issues from before), 1 test in 1 suite pass, 19 tests in 3 suites pass; 0 fail. Finding checkbox is now `- [x]`.
    - next: /review ^1hcwaqy
  timestamp: 2026-09-24T13:54:41.935574+00:00
- actor: claude-code
  id: 01m39w1mrbgw7b9c7xazx9h61z
  text: |-
    ### test — green
    - command: `swift build --build-tests` in the package root. Result: build OK, no warning in our own `Sources/` or `Tests/` files. (Warnings seen were only in the third-party `mlx-swift` dependency's C++ metal kernel headers, under `.build/checkouts/`, out of our source tree.)
    - command: `swift test`. Result: 3 test runs, all green.
      - 1367 tests in 155 suites passed (2 known issues — pre-existing `withKnownIssue` markers in `BoundedWaitTests.swift` and `RealModelHarnessTests.swift`, not new, not skips)
      - 1 test in 1 suite passed
      - 19 tests in 3 suites passed
      - 0 failures, 0 skipped
    - command: `swift build --build-tests` in `IntegrationTests/`. Result: build OK, no warning in our own code (only the same third-party mlx-swift bundle notice).
    - The uncommitted fix in `RoutedSessionActorRepetitionWatch.swift` (call `Self.usageDelta` in place of the duplicate `usage` function, now removed) builds and tests clean.
    - Checked `swiftformat`/`swiftlint` as due diligence. No `.swiftformat` or `.swift-format` file is in the repo. `swiftformat --lint` with the stated default options finds pre-existing style gaps in 312 of 371 files repo-wide, not caused by this fix. `swiftlint` on the changed file finds 2 warnings (a line-length line and an `optional_data_string_conversion` line); both are confirmed identical at `HEAD`, so they pre-date this fix. None of these are `swift build`/`swift test` failures or warnings, so they are out of scope for this test pass.
    - next: ready for commit and review.

    evidence: `swift build --build-tests` clean; `swift test` — 1387 tests total, 0 failed, 0 skipped, 2 pre-existing known issues; `IntegrationTests` `swift build --build-tests` clean.
  timestamp: 2026-09-24T14:10:24.651118+00:00
position_column: doing
position_ordinal: '80'
title: Stop a generate call that repeats itself, with a configurable detector and a default
---
## The measurement

Transcript: `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/bench/preds.t90.transcripts/django__django-13964/01M38ATWY3RB45SQSYD5BX53P8/transcript.jsonl`. Model mlx-community/Qwen3.8-27B-mxfp4. The two long calls of ^gfxd7av contain only reasoning, and most of each call repeats itself.

Measured by the peer session:

- seq 132 (reasoning entry seq 131): 162,595 characters, 3,128 lines, 205 distinct. The share of new lines (lines not seen earlier in the same entry), per tenth of the text: 37%, 28%, then 0% for the last eight tenths. Approximately 32,000 of its 39,617 tokens added nothing.
- seq 225 (reasoning entry seq 224): 50,006 characters. New lines per tenth: 91%, 79%, 85%, 76%, 67%, then 0% for the last five tenths.

Measured again in this session (the text split on "\n", blank lines included, tenths by line count):

- seq 131: 162,596 characters, 4,197 lines, 210 distinct. New lines per tenth: 32%, 18%, then 0% for the last eight tenths.
- seq 224: 50,007 characters, 550 lines, 140 distinct. New lines per tenth: 84%, 78%, 49%, 42%, 0%, 0%, 0%, 0%, 0%, 2%.

The two methods split lines in different ways, so the numbers are different. The pattern is the same: the share of new lines goes to zero and stays there.

This is not a cycle of the same text with a fixed period. The model writes the lines that it already wrote again, in a different sequence. The signal that makes it different from normal reasoning: the share of new lines goes to zero and stays at zero.

## Requirements

1. Router monitors the reasoning (and the text) of the call in flight. Router stops the call when the call no longer makes new lines. Router already stops a call when it cancels the task that reads the stream. The engine examines cancellation between tokens.
2. After the stop, recover as for a ceiling stop (^46bz58k): a short prompt that tells the model to act, and a bound on the number of recoveries. The repeated part must NOT go back into the context that the model receives. Keep the part that was new, or remove that reasoning entry from the render. The recorded transcript keeps full fidelity (see ^tpsc0nf decision 3): the full entry stays in the transcript.
3. A configuration value with a default that is on, so that a host changes it only when necessary. For example, a struct next to `TokenBudget` with:
   - `enabled` (default true);
   - the window, in generated tokens, that must contain at least one new line;
   - a minimum line length for the test, so that short lines that repeat by nature (```, """, ")", "...") do not count. In seq 132 the lines that repeated most were these: ``` 226 times, """ 184 times;
   - the number of recoveries per turn.
4. A log line, and a usage or event record, when the detector stops a call. They give the number of tokens that the call generated and the share of new lines, so that a host can see the stop.

## The default values are the user's decision

Rule of this user: each hard-coded limit is the user's decision, one value at a time. Do not choose a default value without the user. Name each constant in the log.

Proposals of the peer (NOT approved):
- window: approximately 2,048 generated tokens. With this value, seq 132 would stop after approximately 8,000 tokens, not 39,617.
- minimum line length: no value proposed.
- recoveries per turn: no value proposed.

Before the implementation, measure the defaults on more runs, write the measurements on this card, and ask the user to approve each value. The two calls above are the first two data points.

## Acceptance

- A test: a stream whose new-line share goes to zero for one full window is stopped, and the log line and the event record are emitted with the token count and the new-line share.
- A test: normal reasoning with repeated short lines (```, """, ")") is not stopped.
- A test: after a stop, the next model call does not receive the repeated part. The recorded transcript still contains the full entry.
- A test: recoveries stop at the configured number per turn.
- A test: `enabled: false` turns off the detector.

## Related

- ^gfxd7av: the question about which ceiling stopped the two long calls.
- ^46bz58k: recovery after a ceiling stop.
- ^tpsc0nf: the render to the model and the full-fidelity transcript.

## Source

A peer session (foundationmodelsacpagent-e5) asked for this card on behalf of the owner. FoundationModelsACPAgent will show the setting in its config.yaml when the Router API exists.

## Review Findings (2026-09-24 08:40)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 35 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorRepetitionWatch.swift:300` `duplication/duplication` — The `usage` function duplicates the logic of `usageDelta` from `RoutedSessionActorRecording.swift`. Both calculate the difference between two usage tuples: (after - before). The implementations are nearly identical and should be unified. Remove the `usage` function and call `usageDelta` from `RoutedSessionActorRecording` instead. At line 275, replace `Self.usage(before: usageOfAttempt, endingAt: backend.usageTokenCounts())` with `Self.usageDelta(before: usageOfAttempt, after: backend.usageTokenCounts())` (adjusting parameter names to match the existing function's signature).
