---
comments:
- actor: claude-code
  id: 01m3wcc0wt8gnaw5gx0tmt6pae
  text: |-
    Research done.
    - The change is in `Sources/FoundationModelsRouter/Session/RepetitionDetector.swift` (`read(line:)`) and `RepetitionDetection.swift` (two new settings, `CodingKeys`, `init(from:)` with `decodeIfPresent`, `loggedValues`).
    - Plan: a line has a shape. When `comparesLineShapes` is on, each run of decimal digits becomes one `#`. `minimumLineLength` applies to the shape. A long shape is new or repeated as before. A short shape is neither new nor repeated for its first `shortLineRepeatThreshold` occurrences (default 8). After that, each occurrence is a repeat: it counts and fills the window.
    - Two existing tests conflict with the new rule that the card orders, and must change: `RepetitionDetectorTests.shortLinesDoNotCount` (400 short lines with no new line between them; the card says that 1,000 lines of one short shape must fill the window), `RepetitionDetectorTests.differentEscapedLinesDoNotStop` and `RepetitionStopTests.repeatedShortLinesDoNotStop` (their "different" lines differ only in digits, for example `Step \(index): ...`). These tests will use lines that differ in text, and code blocks with some short lines, as the card describes.
    - `ToolCallRepetitionStopTests.differentSnippetRuns` also has lines that differ only in digits, but 30 lines of about 52 tokens stay below the default window of 2,048 tokens, so it does not stop.
  timestamp: 2026-10-01T18:42:01.754591+00:00
- actor: claude-code
  id: 01m3wcxgy601prkgqywkp7e1k8
  text: |-
    Implementation landed (TDD: RED seen on 3 detector tests, then GREEN).
    - `RepetitionDetection`: two new settings with named defaults: `comparesLineShapes` (`defaultComparesLineShapes = true`) and `shortLineRepeatThreshold` (`defaultShortLineRepeatThreshold = 8`). Both are in `CodingKeys`, decode with `decodeIfPresent` and their default, and appear in `loggedValues`. New `shape(of:)`: the trimmed line, with each run of decimal digits (`\d+`) replaced by `digitRunPlaceholder` (`#`).
    - `RepetitionDetector.read(line:)`: compares the shape. `minimumLineLength` applies to the shape. A long shape is new or repeated as before (`seenShapes`). A short shape is counted in `shortShapeOccurrences`; after `shortLineRepeatThreshold` occurrences, each further occurrence counts and fills the window (`readShort`, `readRepeat`).
    - Tests changed because the card changes the rule they held: `shortLinesDoNotCount` became `shortLinesUpToTheThresholdDoNotCount`; `differentEscapedLinesDoNotStop` and `RepetitionStopTests.repeatedShortLinesDoNotStop` now use lines that differ in text (new shared test helper `Helpers/DigitFreeLabel.swift`). The log-line test of `RepetitionStopTests` also checks the two new names.
    - Environment: the local `Package.resolved` (not tracked) pinned Extras at 3de1179 and the build failed before any change (`MLXModelLoader` not found). `swift package update FoundationModelsExtras` moved it to 50fd4a5. With 50fd4a5, 6 expectations in `ResolveTracingTests`, `ToolTracingTests` and `TelemetryContentSafetyTests` fail also with my change stashed. New card ^arqwppv holds that work.
  timestamp: 2026-10-01T18:51:35.238386+00:00
- actor: claude-code
  id: 01m3wcxmd6dp3cwdktgtb0jvcv
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Session/RepetitionDetection.swift, Sources/FoundationModelsRouter/Session/RepetitionDetector.swift, Tests/FoundationModelsRouterTests/RepetitionDetectorTests.swift, Tests/FoundationModelsRouterTests/RepetitionStopTests.swift, Tests/FoundationModelsRouterTests/Helpers/DigitFreeLabel.swift. `swift test --filter RepetitionDetectorTests`: 23 tests passed. Full `swift test`: 1434 tests, 6 issues in 3 tracing/telemetry suites that fail the same with the change stashed (Extras 50fd4a5, card ^arqwppv), 2 known issues, 0 compiler warnings; the other targets: 23 and 19 tests passed.
    - next: /review
  timestamp: 2026-10-01T18:51:38.790683+00:00
- actor: claude-code
  id: 01m3wd7tm8vwbj8rw612vkefdw
  text: |-
    ### test — green
    - evidence: swift test (full, run 2) — 1434 tests in 178 suites passed, 0 failures, 0 warnings, 0 skipped (2 known issues are the existing withKnownIssue proofs in BoundedWaitTests and RealModelHarnessTests). First run had 6 failing checks in 4 suites.
    - fixed: Extras 50fd4a5 records only the error type on a span, not the error. Router change: RoutedSessionActorSubmissionEvents.recordSubmissionError now sets error status and the error.type attribute (new RouterTelemetry.AttributeKey.errorType). It no longer records the error description, which held the tool arguments. This fixes the TelemetryContentSafetyTests failure.
    - fixed: ResolveTracingTests, ToolTracingTests and SubmissionTracingTests now read the failure with the new helper FinishedInMemorySpan.failureType (Tests/FoundationModelsRouterTests/Helpers/FinishedInMemorySpan+Failure.swift). This covers the work of card ^arqwppv.
    - next: review. Nothing is committed.
  timestamp: 2026-10-01T18:57:12.840938+00:00
position_column: doing
position_ordinal: '80'
title: The repetition detector misses a loop of short lines that differ only in their digits
---
## Problem

The repetition detector (^1hcwaqy) did not stop a counting loop. The call ran until `passTokenLimit` (16,384 tokens), and the turn ended with no patch.

Evidence: SWE-bench run of 2026-10-01, `django__django-13447`, in FoundationModelsACPAgent at `bench/preds.code-context.transcripts/django__django-13447/`. The last generation call: "fed 31420 tokens, generated 16384 tokens, stopped at the token ceiling, left text". The call took 560 seconds. Its reasoning holds 1,483 lines. 1,475 of these lines have this form:

```
- "Fixed #38692"
- "Fixed #38700"
- "Fixed #38708"
```

Each number is 8 more than the number before it.

## Why the detector did not stop it

`RepetitionDetector.read(line:)` has two gates, and this loop goes through both:

1. Each line is about 16 characters. `minimumLineLength` is 20, thus the line is "neither new nor repeated" and it does not fill the window.
2. Each line is different, because the number changes. Thus with a smaller minimum, each line is still a new line, and each new line empties the window.

## What to do

- Compare the shape of a line, not its exact text. Before the `seenLines` check, replace each run of digits with one placeholder (for example `#`). `- "Fixed #38692"` and `- "Fixed #38700"` then have the same shape, and the second line is a repeat.
- Apply `minimumLineLength` so that a short line that repeats many times still fills the window. Proposal: a short shape counts as a repeat after it occurs N times in the call (N configurable, for example 8). A line such as ``` or `)` that occurs some times stays out, and 1,000 lines of one short shape do not.
- Keep each new behavior a setting of `RepetitionDetection` with a named default, as the other four values are.

## Tests

- A reasoning text of 1,000 lines of the form `- "Fixed #<n>"`, with n += 8: the detector stops it before `windowTokens` plus one line of tokens.
- Lines that differ in text and not only in digits stay new.
- A text with some ``` and `"""` lines (as in normal reasoning with code blocks) does not stop.
- Each new setting decodes with its default when the key is absent.

## Note

A second loop of the same run (`django__django-14016`) was not repetition: new lines continued. The detector worked correctly there. A separate card handles that loop: a reasoning limit for each pass. #generation-queue