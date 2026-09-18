---
comments:
- actor: claude-code
  id: 01m2v8z0041e1n7p4jrf3aq5yj
  text: |-
    Research done. Findings:
    - `Compactor.stages` is a static list. `ToolOutputElision` and `TurnTruncation` have no rule input. `Summarization.apply` runs on the original transcript and folds all old turns.
    - The session flow: `SessionConfiguration` -> `RoutedModel.makeSession(configuration:)` -> internal `makeSession(grammar:...)` -> `makeRoutedSessionActor` -> `RoutedSessionActor` stored `nonisolated let`. Fork (`RoutedSessionActorForking`) and restore (`restoreSessionTree`) pass each value again. The frozen public `makeSession(instructions:...)` convenience (^pckk91c) must not change.
    - The rule is a closure, thus it cannot go in `SessionConfiguration.Persistable`. The restore must get it from the host, the same as `tools`. Plan: add a defaulted `toolOutputProtection:` parameter to `restoreSession(id:...)` and `restoreSessionTree(root:...)`.
    - `ToolCallOutputPairing.completedToolCallId` is the one pairing rule from a `.toolOutput` to its call. Use it per turn.
    - Recording: a fold records only the new entry ids (`TranscriptDiffer.diffByEntryId`). Restore resolves `liveWindowEntryIds` to the recorded events by id. Thus a protected entry that keeps its id and its content, and that is in the live window, restores word for word.
    - Design: a protected exchange = the `.toolCalls` entry with a protected call, plus every `.toolOutput` that answers that entry (a non-protected one is elided). TurnTruncation and Summarization move the protected exchanges of the dropped turns into the kept part, after the header (and after the summary entry). The next split puts them in the header, thus a later fold does not touch them again.
  timestamp: 2026-09-18T22:07:32.868932+00:00
- actor: claude-code
  id: 01m2v9sy3pg4r97kmrqedanemq
  text: |-
    Implementation landed (TDD: stage tests and session tests were written first and failed to compile, because the API did not exist; then the code made them pass).

    Public names:
    - `public typealias ToolOutputProtection = @Sendable (_ call: Transcript.ToolCall, _ output: Transcript.ToolOutput) -> Bool` (Compaction/ToolOutputProtection.swift).
    - `SessionConfiguration.toolOutputProtection: ToolOutputProtection?` (default nil; not in `Persistable`).
    - `RoutedModel.makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:)` (new trailing parameter, default nil).
    - `RoutedModel.restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:)` (new trailing parameter, default nil).
    - `CompactionResult.protectedTokens: Int` (default 0).

    Mechanics:
    - `ProtectedToolOutputs` pairs each `.toolOutput` with its call through `ToolCallOutputPairing.completedToolCallId` (by id first), with the scope reset at each `.prompt`.
    - `ToolOutputElision` keeps a protected output unchanged. `TurnTruncation` keeps, right after the header and in original order, the `.toolCalls` entry reduced to its protected calls (new id `<id>-protected` only when a call is removed, so the fold records it and a restore rebuilds it) plus the protected output. `Summarization` does the same (kept pair before the summary entry), sends no protected output to the summarizer, charges the kept bytes out of the span budget, and names the kept ids in `liveWindowEntryIds`.
    - `Compactor.compact(..., protection:)`: when only the protected outputs keep a deterministic fold over target (protected alone over target, or the fold is under target without them), the fold completes anyway, `protectedTokens` reports it, and a warning is logged. No loop.
    - Fork passes the rule; `restoreSessionTree(..., toolOutputProtection:)` passes it to every node.

    Discovery: two `GeneratedContent` parses of one JSON object with two keys compared unequal in one test run of two; the fixture uses a one-key argument object.
  timestamp: 2026-09-18T22:22:15.670217+00:00
- actor: claude-code
  id: 01m2va2tq8pb4w8xy0p6q1r459
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0 — 1342 tests in 143 suites passed (2 known issues that existed before: BoundedWait, RealModelHarness embedding slot), plus 1 and 83 tests in the other products; the one build warning is the vendored mlx-swift "missing creator" warning. `swift build --package-path IntegrationTests --build-tests` builds. New tests: Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift (13), Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift (6). New code: Sources/FoundationModelsRouter/Compaction/ToolOutputProtection.swift. Changed: Compactor.swift, ToolOutputElision.swift, TurnTruncation.swift, Summarization.swift, SessionConfiguration.swift, RoutedLLM.swift, RoutedSessionActor.swift, RoutedSessionActorCompaction.swift, RoutedSessionActorForking.swift, SessionRestoration.swift, SessionTreeRestoration.swift, GuidedGeneration.swift (comment), plus DocC link updates for the new signatures in 27 files. New task for a stale link that existed before: "A test doc comment names a restoreSessionTree signature that does not exist".
    - next: /review
  timestamp: 2026-09-18T22:27:07.112933+00:00
- actor: claude-code
  id: 01m2va9vcb2v055b1evq5tq6jh
  text: |-
    ### test — green
    - Command: `swift build`. Result: 0 errors, 1 warning. The warning comes from the mlx-swift dependency, not from our code. The warning text is: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle.
    - Command: `swift test`. Result: 1342 tests in 143 suites passed in 5.070 seconds. The run also shows 2 known issues. These known issues are not defects. They come from a test in BoundedWaitTests.swift. This test checks that BoundedWait records an issue when a wait condition does not become true. This is the correct, planned behavior.
    - Command: `swift test` also ran 1 test in 1 suite. That test passed.
    - Command: `swift test` also ran 83 tests in 10 suites. All 83 tests passed.
    - Total result: 0 failed tests, 0 skipped tests.
    - Command: `swift build --package-path IntegrationTests --build-tests`. Result: 0 errors. The build shows the same mlx-swift warning only.
    - Check: the test files do not contain `.disabled(`, `XCTSkip`, or `.skip(`. No test is turned off.
    - Next step: send this task for review.
  timestamp: 2026-09-18T22:30:57.163891+00:00
- actor: claude-code
  id: 01m2vbaz6tsv73be6vcvrrhe26
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (89ed266); 6 findings (6 confirmed, 2 refuted) — ToolOutputProtectionSessionTests.swift:28, :33, :96, :108; ToolOutputProtectionTests.swift:24, :130. The change obeys each point of "Host requirements".
    - next: correct the 6 open items in "Review Findings (2026-09-18 17:33)", then review again. The task stays in review.
  timestamp: 2026-09-18T22:49:02.426234+00:00
- actor: claude-code
  id: 01m2vbecgky7d4nzhsde3m8a2m
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 37 files (new Compaction/ToolOutputProtection.swift, 19 new tests)
    - test: green — swift test, 1342 passed in 143 suites (+1, +83), 0 failed, 0 skipped
    - commit: 89ed266
    - review: findings — Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:28, :33, :96, :108; Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift:24, :130
  timestamp: 2026-09-18T22:50:54.355142+00:00
- actor: claude-code
  id: 01m2vbtyqc3aza2ssmw6x3ye1f
  text: |-
    Review findings (2026-09-18 17:33) are corrected. What changed, for each cause, in the whole file:
    - no_unchecked_sendable: `SeededLLMContainer` is now a `private struct` with a plain `LoadedLLMContainer` (Sendable) conformance. It holds only a `String` and `[Transcript.Entry]`, so no lock is necessary. The two files have no other `@unchecked Sendable`.
    - access-control: `seedEntries` and `responseText` are now `private`. `Directories.cache` and `Directories.recordings` stay internal, because `resolveProfile` reads them from outside the struct.
    - reuse (driveRecentTurns): removed. Each test calls the shared `driveTurns(Fixtures.recentTurnCount, on:)` from Helpers/CompactionFoldFixtures.swift. The prompts are now "turn <n>", not "recent turn <n>"; no assertion reads them.
    - reuse (deterministicBudget): removed. The shared `deterministicFoldBudget(for:protection:)` has a new parameter `protection: ToolOutputProtection? = nil`. Its floor is now what `TurnTruncation(keepRecentTurns: defaultKeepRecentTurns, protection:)` leaves. With nil, that is header + recency window, the same value as `recencyWindowOnlyEstimate`, so the callers that existed before get the same budget.
    - reuse (RecordingSummarizer): moved to the new shared file Helpers/RecordingSummarizer.swift as `actor RecordingSummarizer(summary:)`. No shared summarizer double existed in Helpers (`FakeSummarizer` is local to the Evals target; the doubles in SummarizationStageTests.swift are private).
    - inverse-operation-coverage: new test "Summarization with no rule folds the skill output into the summary, the behavior before the rule existed". It calls `Summarization().apply(...)` with no protection argument. It fails with 3 issues when the rule is given (checked, then removed), and passes without it.
    Discovery: the `files` tool `edit file` with `replace_all: true` replaced only one match in each call here, so each site was edited on its own.
    The files still have 4 swiftlint warnings from the default rule set (`trailing_comma` in ToolOutputProtectionTests.swift, `opening_brace` in ToolOutputProtectionSessionTests.swift). These lines were not changed, and these rules are not in the 12 rules of the disallowed-constructs-swift gate.
  timestamp: 2026-09-18T22:57:46.220144+00:00
- actor: claude-code
  id: 01m2vbv1a852kczn2se3enmwmk
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift, Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift, Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift, Tests/FoundationModelsRouterTests/Helpers/RecordingSummarizer.swift (new). `swift test`: 1343 tests in 143 suites passed with 2 known issues that existed before, plus 1 and 83 tests passed; 0 failed. The one build warning is the mlx-swift "missing creator" warning. 6 of 6 findings are checked.
    - next: /test, then /review
  timestamp: 2026-09-18T22:57:48.872724+00:00
- actor: claude-code
  id: 01m2vc5r2ygvfm40m7j9w1757a
  text: |-
    ### test — green
    - I ran `swift test`. Result: 83 tests in 10 suites, all pass. No fails. No skips.
    - I ran `swift build --package-path IntegrationTests --build-tests`. Result: build complete, no errors. One warning shows, but it comes from the third-party `mlx-swift` dependency, not from project code.
    - I ran `swiftlint lint` on the four changed files. It found 4 warnings: 1 `opening_brace` in ToolOutputProtectionSessionTests.swift, and 3 `trailing_comma` in ToolOutputProtectionTests.swift.
    - I fixed all 4 warnings:
      - ToolOutputProtectionSessionTests.swift: moved the opening brace of `resolveProfile(in:routerId:)` to the same line as its return type.
      - ToolOutputProtectionTests.swift: removed the trailing comma before the closing `]` in three array literals (in `ruleReadsTheCallArguments`, `truncationReducesAMixedToolCallsEntry`, and `summarizationKeepsTheProtectedPair`).
    - I ran `swiftlint lint` again on the four files. Result: clean, no warnings.
    - I ran `swift test` again after the fixes. Result: 83 tests in 10 suites, all pass.
    - next: send the task to review.
  timestamp: 2026-09-18T23:03:39.870714+00:00
- actor: claude-code
  id: 01m2vc9t9dsegdsnd3h84dx7py
  text: |-
    ### test — green (full counts)
    `swift test` runs three test products. Here are the full counts for each, read from the full run log after the swiftlint fixes:
    - Main product (FoundationModelsRouterTests, holds the changed files): 1343 tests in 143 suites passed, with 2 known issues. These 2 known issues are the planned, correct behavior of the BoundedWait tests (they check that BoundedWait records an issue when a wait condition never becomes true). They are not failures.
    - Second product: 1 test in 1 suite passed.
    - Third product (Evals): 83 tests in 10 suites passed.
    - Grand total: 1427 tests, 0 failed, 0 skipped.
    - I checked the full log for "failed" and "error:" outside "passed after" lines. Every match is a test name that contains the word "failed" (tests of failure-handling code), not a real failure.
    - I checked the full log for "skipped". Every match is a test name that contains the word "skipped", not a real skip.
    - `swift build --package-path IntegrationTests --build-tests`: 0 errors. One warning shows, from the third-party mlx-swift dependency, not from project code.
    - `swiftlint lint` on the 4 changed files: 0 warnings, after the 4 fixes recorded in my prior comment.
    - next: send the task to review.
  timestamp: 2026-09-18T23:05:53.197932+00:00
- actor: claude-code
  id: 01m2vchdtaqb7a5fm0fazatddp
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (6581750): 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 4 files reviewed. All 6 items in "Review Findings (2026-09-18 17:33)" are checked.
    - next: none. The task is in done.
  timestamp: 2026-09-18T23:10:02.570210+00:00
- actor: claude-code
  id: 01m2vchxtbadevv2zk7fmv0rcw
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files (6/6 findings checked)
    - test: green — swift test, 1427 passed in 3 products (1343 + 1 + 83), 0 failed, 0 skipped; swiftlint 0 warnings on changed files
    - commit: 6581750
    - review: clean — 0 findings, 6/6 prior items checked; task in done
  timestamp: 2026-09-18T23:10:18.955316+00:00
position_column: done
position_ordinal: ffffd780
title: A host cannot keep a tool output through compaction, so a loaded skill is elided
---
## What

A host cannot keep a tool output through compaction. `FoundationModelsACPAgent` needs to keep the body of each skill that the model loads with the `skills` tool (`op: "use skill"`). That body is the procedure that the model must follow for the rest of the session.

Router has no seam for this:

- `Compactor.stages` is a fixed internal list: `[ToolOutputElision(), TurnTruncation()]` (`Compaction/Compactor.swift:90`).
- `ToolOutputElision` replaces the segments of every `.toolOutput` entry older than the recency window with `[elided: original "<tool>" output omitted by compaction]` (`Compaction/ToolOutputElision.swift`). It has no exemption.
- A host gives only `TokenBudget`, `CompactionPrompt` and `Summarization` to a session. None of them can mark an entry as protected.

Thus the first deterministic stage removes a loaded skill, and the model continues with no procedure and no visible error.

The Agent Skills standard says: "Skill instructions are durable behavioral guidance — losing them mid-conversation silently degrades the agent's performance without any visible error." It recommends that a host exempts skill content from pruning. Source: https://agentskills.io/client-implementation/adding-skills-support

## The work

1. A host-supplied rule that marks a tool output as protected. For example, a `SessionConfiguration` value such as `protectedToolOutput: @Sendable (Transcript.ToolOutput, Transcript.ToolCall?) -> Bool`, which gets the output and the call that made it (the host needs the arguments to see `op: "use skill"`). Choose the shape; it must be `Sendable`, and it must not need a tag in the output text.
2. `ToolOutputElision` keeps a protected output unchanged.
3. `TurnTruncation` and the summarization stage keep a protected output: a turn that holds one is not dropped whole, or the protected output moves into the kept part of the transcript. The summary never replaces it.
4. The rule is inherited by a fork, as the other session configuration is.
5. The recording and the restore of a session keep the protected entries unchanged.
6. Tests: a scripted session with a protected tool output and a tool output that is not protected; after a compaction that runs each stage, the protected output is in the transcript word for word, and the other one is elided.

## Host requirements

These come from the host that needs this card (`FoundationModelsACPAgent`). Obey them in addition to "The work".

1. Rule shape (suggested; the implementer chooses the final one): `public typealias ToolOutputProtection = @Sendable (_ call: Transcript.ToolCall, _ output: Transcript.ToolOutput) -> Bool`. The rule must see the CALL (the host decides on tool name "skills" and argument `op` == "use skill"). Pair the call and the output by id: the `.toolCalls` entry holds the call whose id is the id of the `.toolOutput` entry.
2. The rule is an optional field of `SessionConfiguration` (default nil = the behavior of today). Add a parameter with default nil to the `makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:)` overload on the standard profile, and to `restoreSession(id:recordingRoot:instructions:tools:...)`. The closure is not Codable, so it is not recorded: the host gives it again at restore, as it gives the tools. A fork inherits it.
3. Every stage keeps a protected output word for word:
   - `ToolOutputElision` does not elide it.
   - `TurnTruncation` must not lose it when it drops a turn. Keep the protected call and its output as a pair in the kept transcript: put the `.toolCalls` entry (reduced to the protected calls only) and the `.toolOutput` entry right after the header, in their original order. A `.toolOutput` must never stay without its call.
   - Summarization never replaces a protected output with summary text.
4. Protected outputs count against the budget like other entries. When protected content alone is over the target, do not remove it: complete the compaction with the other entries, and report it (for example in `CompactionResult`, or a log line). Do not loop.
5. No tag, marker or wrapper in the output text. Only the rule finds the entry.
6. Tests: a scripted session with one protected and one unprotected tool output, compacted through each stage, keeps the protected one word for word and elides the other; a fork keeps the rule; a restore with the rule keeps it.

If the Router code makes one of these points impossible, stop and report the exact conflict as `stuck`, with a proposal. Do not choose a different design.

## Where it was found

`FoundationModelsACPAgent`, card `^2zb9s07`. That card waits for this one. #compaction #cross-repo

## Review Findings (2026-09-18 17:33)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 37 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:28` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:33` `swift/access-control` — Property `seedEntries` is only used internally within `SeededLLMContainer` (lines 39, 43) and should be marked `private` to reflect its internal-only scope. Change `let seedEntries: [Transcript.Entry]` to `private let seedEntries: [Transcript.Entry]`.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:96` `reuse/reuse` — The `driveRecentTurns` function reimplements a helper that loops calling `session.respond()` repeatedly—a pattern that already exists elsewhere and should be reused instead. This helper is called from multiple test methods (lines 146, 163, 177, 194, 212, 231), making it a candidate for extraction to shared test fixtures or reuse of an existing utility. Check `CompactionFoldFixtures.driveTurns()` or similar existing helpers; reuse or extend the existing implementation instead of duplicating the logic here.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:108` `reuse/reuse` — The `deterministicBudget` function reimplements budget-calculation logic that already exists elsewhere. This helper is called from multiple test methods (lines 148, 197), making it a multi-use function that should be shared, not duplicated. Reuse `CompactionFoldFixtures.deterministicFoldBudget()` or extend it to cover the protection-rule test case, rather than reimplementing the same logic here.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift:24` `reuse/reuse` — The `RecordingSummarizer` test double reimplements a summarizer mock that already exists elsewhere. This actor is instantiated in multiple test methods (lines 133, 152, 171), making it a shared test utility that should be placed in shared test fixtures or should reuse an existing test double instead of duplicating it. Check if `FakeSummarizer` or similar existing test doubles in the Helpers directory can be reused or extended. If not, add `RecordingSummarizer` to shared test fixtures (`Helpers/`) instead of defining it locally in this test file.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift:130` `completeness/inverse-operation-coverage` — The Summarization stage tests (lines 130–178) only exercise the WITH-protection path, while ToolOutputElision (line 60) and TurnTruncation (line 121) both include tests calling the stage constructor with no protection argument. When a new parameter/capability is added, both the enabled and default/disabled cases should be tested for completeness. Add a test (after line 178) that calls `Summarization().apply(transcript, …)` without the protection parameter, asserting the old behavior when protection is absent, analogous to lines 60–65 and 121–126.
