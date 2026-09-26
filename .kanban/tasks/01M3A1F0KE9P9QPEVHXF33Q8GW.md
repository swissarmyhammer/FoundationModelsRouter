---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a3nymrdd81rbzjcytnee5w
  text: 'Consumer note from FoundationModelsACPAgent (2026-09-24, user decision): the Router agent works only in the Router. Do NOT edit ../FoundationModelsACPAgent in this change set. The ACP agent adopts the rename on its own board (card ^tz867gz there). Step 5 still applies to the other consumers unless their boards say the same. Please write the final event choice (a) or (b) and the new names in a comment here: the ACP card reads them.'
  timestamp: 2026-09-24T16:23:50.168869+00:00
- actor: claude-code
  id: 01m3cw3692jndf9sgkvnnq9ffg
  text: '2026-09-25, from the user (answer to a question during ^44y6ba4): "i just wanted you to eliminate this ''turn'' concept as i think it is confusing". Remove the word "turn" from the Router API, events, errors and code names (for example `sameSessionTurnInFlight`, `forkDuringSameSessionTurn`, `turnLock`, `SessionEvent` turn cases). Decide the new names yourself; the user does not want to choose API names. Write each rename on this task.'
  timestamp: 2026-09-25T18:08:58.658139+00:00
- actor: claude-code
  id: 01m3cwy7na6bt6aet4g0xe5dcq
  text: |-
    Work stopped on 2026-09-25 by a change of direction from the user: "it's not just removal of the word 'turn' -- it's the concept that is problematic, as opposed to a queue of requests to the Foundation level model to do generation or tool calling." A pure rename to "request" is thus probably not the correct change. No rename was made. The tree stays as it is.

    Files changed so far:
    1. `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/session.json` (new, untracked). A recording that the code at HEAD 50a629e wrote. It holds the on-disk key `recoveriesPerTurn` (from `RepetitionDetection`), and the working directory is the neutral `/fixture-work`.
    2. `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/transcript.jsonl` (new, untracked). Six events: session, prompt "first", a stamped `.response` (100 in, 50 out), a `generationCall`, prompt "second", and the failed close (`.response`, empty segments, 0 in, 0 out). It was made for the acceptance criterion "a recording written before the rename still loads". No test reads it yet, and `Package.swift` does not yet declare it as a resource. If the new direction needs no such fixture, delete the directory.
    3. `Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift`: a temporary test wrote the fixture and was then removed. The net diff is empty (`git status` shows no change).
    4. `.kanban/tasks/01M3A1F0KE9P9QPEVHXF33Q8GW.*`: the task moved to `doing`, plus these comments.

    Research results for the next agent:
    - The only key with "turn" on disk is `recoveriesPerTurn` in `session.json` (synthesized `Codable` of `RepetitionDetection`). `TranscriptEvent` JSON has no "turn" key; `isFailedTurnClose` and `turnUsageStamp` are computed, not stored.
    - `SessionEvent.turnEnded` is sent in `finishTurn` (`RoutedSessionActorRecording.swift`), one time for each attempt. `finishTurn`, `finishTurnAndRequeueIfUnattached`, `recordFailedTurn`, `isFailedTurnClose`, and `turnUsageStamp` are attempt level, not request level.
    - `turnStarted` is sent one time for each request in `runTurnWork` (`RoutedSessionActorTurnExecution.swift`). There is no request-end event.
    - The consumers FoundationModelsMultitool, AgentViewKit, and FoundationModelsAgents depend on the Router through a git URL at `branch: "main"`. Their builds do not see a local Router change unless `swift package edit` is used. Only FoundationModelsACPAgent's board (card ^tz867gz) says that it adopts the change itself.
    - The Router holds about 5500 "turn" words in about 250 files. Some are not the request level: verbs ("turns reasoning off", "turned off"), chat-template terms ("assistant turn"), and `modelTurnsThinkingOffByTemplateFlag`.
  timestamp: 2026-09-25T18:23:44.810891+00:00
- actor: claude-code
  id: 01m3cxkwnp3a3ks0rhrm41z3r0
  text: '2026-09-25: STOPPED and superseded in scope. The user wants a work-queue design with no locks and no "turn" concept, not a rename to "request". The design task ^jdp02p now designs the new model and writes the implementation tasks. This task waits on ^jdp02p; the design either replaces it with new tasks or rewrites it. Do not start the rename. The untracked fixture `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/` (a recording written at 50a629e with the key `recoveriesPerTurn`) can serve the "old recordings still load" test.'
  timestamp: 2026-09-25T18:35:34.454106+00:00
- actor: claude-code
  id: 01m3cyxmhec7kz764gew9cbc1x
  text: 'Rewritten on 2026-09-25 by the design task ^jdp02p (not deleted). The old plan (rename "turn" to "request", keep `turnLock` as `requestLock`) is dropped: the user rejected a rename and a lock. The new tasks remove the turn itself: ^a0ze9af, ^1psqdm9, ^dpn2ytt, ^3qx0mpt, ^cbhpdjy, ^x7cxsg3, ^5d0qx1b. This task now removes what they leave: `TurnBoundaryTool` becomes `SubmissionBoundaryTool.submissionWillBegin()`, `awaitingUser(_:)` goes, and the other "turn" names and docs go. The consumer updates moved to ^d7d777f. The event choice that the ACP card ^tz867gz asked for is in `generation-queue.md` section 5.6: `submissionStarted`/`submissionEnded` for each SDK call (`submissionEnded` replaces `turnEnded` one for one), and `answered`/`answerFailed` for each final answer. The full old name to new name list is in section 5.6, and ^d7d777f posts it on ^tz867gz.'
  timestamp: 2026-09-25T18:58:22.382444+00:00
- actor: claude-code
  id: 01m3e9xj3yaeh75qxrcbwf2pax
  text: |-
    2026-09-26, research (implement step).

    Facts found:
    - The repo has about 3800 uses of "turn" (not "return") in about 240 files: Sources 438, Tests 2985, IntegrationTests 726, Examples 66, Tools 13, Markdown about 110.
    - `RouterTracing.TurnEntryPoint` and the tracing span names are already gone (^x7cxsg3). The only tracing "turn" left is doc text.
    - `notifyTurnBoundaryTools()` runs one time for each ANSWER now (in `runFirstSubmission`, the pump), not for each submission. A continuation submission (compaction yield, ceiling stop, overflow retry, rejected tool call, repetition stop) gets no call.
    - `awaitingUser(_:)` is `try await body()` only. `HumanWaitGateTests` and `TurnCancellationTests` call it.
    - `modelTurnCount` (test helper `ScriptedTurnLog`) counts executor calls, that is generation passes.
    - The string "TurnTruncation" is only a fake stage name in two test files and a stage of `compaction_plan.md`.

    Decisions (names, all mine; the user does not choose API names):
    - Public: `TurnBoundaryTool` -> `SubmissionBoundaryTool`, `turnWillBegin()` -> `submissionWillBegin()`. The session calls it one time before EACH submission: before the first submission of an answer at the same place as now (in the pump, after the take, before the model call), and before each continuation submission (after `takeMessagesJoiningTheAnswer()`, before the model call). Reason: the name says "submission", and the design says "one time before each submission of the pump".
    - `awaitingUser(_:)` is removed from `RoutedSession` and the actor. Its tests are restated as a tool body that waits for a person with no wrapper, so the test count does not drop.
    - Internal: `notifyTurnBoundaryTools` -> `notifySubmissionBoundaryTools`; `turnEventSink` -> `answerEventSink`; `currentTurnEventSink` -> `currentAnswerEventSink`; `runTurnWork` -> `runAnswerWork`; `runTurnAttempt` -> `runSubmission`; `recordFailedTurn` -> `recordFailedSubmission`; `finishTurn` -> `finishSubmission`; `finishTurnAndRequeueIfUnattached` -> `finishSubmissionAndRequeueIfUnattached`; `turnEntries` -> `submissionEntries`; `turnUsageStamp` -> `submissionUsageStamp`; `newestTurnRenderSize` -> `newestSubmissionRenderSize`; `nextTurnStandIn` -> `nextSubmissionStandIn`; `turnTextEntryIds` -> `submissionTextEntryIds`; `turnBindingToolStamp`/`turnBindingOpStamp` -> `submissionBindingToolStamp`/`submissionBindingOpStamp`.
    - Files: `Hosting/TurnBoundaryTool.swift` -> `Hosting/SubmissionBoundaryTool.swift`; `Session/RoutedSessionActorTurnExecution.swift` -> `Session/RoutedSessionActorAnswerExecution.swift`.
    - Test names: `ScriptedTurnScript` -> `ScriptedAnswerScript`, `ScriptedTurnLog` -> `ScriptedAnswerLog`, `modelTurnCount` -> `generationPassCount`, `recordModelTurn` -> `recordGenerationPass`, `ToolTurnScenario` -> `ToolAnswerScenario`, `ToolTurnRunOutcome` -> `ToolAnswerRunOutcome`, `followUpTurnCompletes`/`followUpTurnEvents` -> `followUpAnswerCompletes`/`followUpAnswerEvents`. Suites and files: `TurnCancellationTests` -> `AnswerCancellationTests`, `TurnTracingTests` -> `SubmissionTracingTests`, `GenerationQueueTurnTests` -> `GenerationQueueSubmissionTests`, `TurnFinishReasonTests` -> `SubmissionFinishReasonTests`, `TurnTokenCeilingTests` -> `AnswerTokenCeilingTests`, `TurnBoundaryToolTests` -> `SubmissionBoundaryToolTests`, `MultiTurnSessionTests` -> `MultiMessageSessionTests`, `ScriptedTurnSizingTests` -> `ScriptedAnswerSizingTests`, `ScriptedToolTurnComparisonTests` -> `ScriptedToolAnswerComparisonTests`, `ToolCallFailureTurnTests` -> `ToolCallFailureAnswerTests`, `RealToolTurnComparisonTests` -> `RealToolAnswerComparisonTests`, `Qwen38ToolTurnIntegrationTests` -> `Qwen38ToolAnswerIntegrationTests`.
    - Word rule: one SDK call is a "submission"; the chain of submissions for caller messages (or mail) up to the final reply is an "answer"; a caller prompt or mail is a "message". In tests, one `respond(to:)` call is one answer.
    - Kept: `recoveriesPerTurn` (stored JSON key, `CodingKeys`, and the fixtures), `modelTurnsThinkingOffByTemplateFlag` (English verb "turns off"), the English verb "turn"/"turned" (for example "turns reasoning off"), and a chat-template "assistant turn" of the model.
  timestamp: 2026-09-26T07:29:48.670892+00:00
- actor: claude-code
  id: 01m3ebhe2kzd4zpt972r8cccwe
  text: |-
    2026-09-26, implementation landed (not committed).

    What changed:
    - New public protocol `SubmissionBoundaryTool.submissionWillBegin()` (file `Hosting/SubmissionBoundaryTool.swift`, replaces `TurnBoundaryTool`). The session calls it before the first submission of each answer (in the pump, as before, also for a submission that only mail started) AND before each continuation submission (in `runSubmission(... isContinuation: true ...)`, after `takeMessagesJoiningTheAnswer()`, before the model call). The continuation call is new behavior: `SubmissionBoundaryToolTests.aContinuationSubmissionFiresItsOwnCall` failed before it (log was `[hook, respond, respond]`).
    - `awaitingUser(_:)` removed from `RoutedSession`, the actor and the DocC topic list. `HumanWaitGateTests` (9 tests) and one `AnswerCancellationTests` test are restated as a tool body that waits for a person with no wrapper; no test was deleted.
    - Every internal and test name in the decision comment is renamed; 16 files renamed with `git mv` (2 in Sources, 12 in Tests, 2 in IntegrationTests). Docs, Examples, Tools, `generation-queue.md` (new paragraph "The last 'turn' names", the 5.6 "untracked" sentence fixed: tracked since f87c7e8), `compaction_plan.md` and the memory notes are updated.
    - Public-surface tests: `SubmissionBoundaryToolPublicSurfaceTests` (unit target, plain import, a conformer mounted on a session gets one call for each submission through the decorator chain) and `SubmissionBoundaryToolConformancePublicSurfaceTests` (public-surface target, the `as? any SubmissionBoundaryTool` cast).

    Kept uses of "turn", with the reason:
    - `recoveriesPerTurn`: the stored JSON key (`RepetitionDetection.CodingKeys`, its doc, `StoredRecoveriesKeyTests`, the two `session.json` fixtures). Old recordings need it.
    - `"keepRecentTurns": 4` in the fixture `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/01M0BGQR2DV5T0P9XQ1PS05K8V/session.json`: stored fixture data; no code reads it.
    - `modelTurnsThinkingOffByTemplateFlag` and the English verb in doc text ("turn it off", "turns reasoning off", "turned off", "turns X into Y", "turn out to be"): not a Router work unit.
    - "a first assistant turn" (Sources `DiscoveryPriming.swift`, IntegrationTests `PropagationProbeIntegrationTests.swift` two places): the chat-template role of the model.
    - History only: `generation-queue.md` old-name columns of its rename tables, user quotes, task titles, section 2 and the "Since ^3qx0mpt" history; `UPSTREAM_ASKS.md` "then named `TurnOutcome.contextFill`"; `compaction_plan.md` "in place of the old word 'turn'"; memory notes that say an old name was removed.

    Process notes for the next agent:
    - In this session the `files` tool `edit file` with `replace_all` replaced only one match for each call, and it echoes the whole file. Three sub-agents (E2, E1c) applied exact phrase-for-phrase replacements with a perl script from the shell to fit their context; the scripts and specs are in the session scratchpad. The result was checked by the full build and test run.
    - Some test prompt literals changed ("turn N" -> "message N" in `AutoCompactionFixtures`, "text N" in `driveAnswers`); the assertions that read them changed with them.
    - Consumers (^d7d777f) must rename `TurnBoundaryTool`/`turnWillBegin()` and drop `awaitingUser`.
  timestamp: 2026-09-26T07:58:08.467472+00:00
- actor: claude-code
  id: 01m3ebhkt5z7fckvvekgnjmjwm
  text: |-
    ### implement — changed
    - evidence: 238 files changed (git diff --stat), 16 renamed with git mv, 2 new test files (Tests/FoundationModelsRouterTests/SubmissionBoundaryToolPublicSurfaceTests.swift, Tests/FoundationModelsRouterPublicSurfaceTests/SubmissionBoundaryToolConformancePublicSurfaceTests.swift). `swift build --build-tests`: complete. `swift test`: 1466 + 15 + 19 = 1500 passed (was 1496; +4 new), 2 known issues as before, 0 failed. `swift test --skip-build --filter SubmissionBoundaryTool`: 6 + 1 passed. `AnswerCancellationTests|HumanWaitGateTests|NestedGenerationReentryTests|SubmissionBoundaryToolTests` 3 extra runs: 54 tests passed each time. IntegrationTests `swift build --build-tests`: complete. Only warning: the known mlx "missing creator" line. Criterion 1 command prints nothing; criterion 2 shows 13 verb / chat-template hits only.
    - next: review
  timestamp: 2026-09-26T07:58:14.341945+00:00
- actor: claude-code
  id: 01m3egghxsptm08mzj69esh9q7
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`, 12 findings (12 confirmed, 7 refuted). SessionProjection.swift:637, AnswerCancellationTests.swift:1, AnswerCancellationTests.swift:130, CeilingStopCompactionTests.swift:59, HumanWaitGateTests.swift:73, HumanWaitGateTests.swift:424, ScriptedToolAnswerComparisonTests.swift:45, SubmissionBoundaryToolTests.swift:90, SubmissionBoundaryToolTests.swift:157, ToolOutputProtectionSessionTests.swift:111, RecordCompactionFixture/main.swift:114, RecordCompactionFixture/main.swift:179.
    - note: The engine did not review 12 Markdown files, because no validator matches them. The duplication validator did not review AnswerCancellationTests.swift, because the file is larger than the prompt cap.
    - next: Correct each item in "Review Findings (2026-09-26 03:07)". Then do the review again. The task stays in review.
  timestamp: 2026-09-26T09:25:02.521730+00:00
- actor: claude-code
  id: 01m3egjrk8akfygzvqphf55p11
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — about 238 files, 16 renamed (last turn names removed)
    - test: green — swift package clean then swift test, 1500 passed (1466+15+19), 0 failed, 0 skipped; renamed suites 3 extra runs clean; all products and IntegrationTests build clean
    - commit: 73a2e85
    - review: findings — SessionProjection.swift:637, AnswerCancellationTests.swift:1, :130, CeilingStopCompactionTests.swift:59, HumanWaitGateTests.swift:73, :424, ScriptedToolAnswerComparisonTests.swift:45, SubmissionBoundaryToolTests.swift:90, :157, ToolOutputProtectionSessionTests.swift:111, Tools/RecordCompactionFixture/main.swift:114, :179
  timestamp: 2026-09-26T09:26:14.888845+00:00
- actor: claude-code
  id: 01m3egwftmzx46qce9nv6mfrrc
  text: |-
    2026-09-26, implement step for the 12 findings of "Review Findings (2026-09-26 03:07)". Research and decisions.

    - Finding 10: `driveAnswers(_:on:)` has a definition. It is a top-level test helper in `Tests/FoundationModelsRouterTests/Helpers/CompactionFixtures.swift` (the function `driveAnswers(_ count: Int, on session: RoutedSession) async throws`). The finding is false: the suite compiles. Fix: the suite doc of `ToolOutputProtectionSessionTests` and each of the 6 call sites name the helper file.
    - Finding 1 (`swift/immutability`), same cause in the whole file: `SessionProjection.swift` has 4 functions with a `var` accumulator in a loop: `transcriptRows(from:)`, `supersededTextEntryIds(in:)`, `canonicallyOrderedTranscript()`, `groupedRows(from:supersededTextRowIds:)`. All 4 change. `supersededTextEntryIds` groups the entries by submission first (`compactMap` to marks, `split` at each submission start, all texts but the last of each group). `transcriptRows` threads a private scan struct through `reduce(into:)`. `canonicallyOrderedTranscript` gets the carried ordinals from `reduce(into:)`. `groupedRows` finds the anchor rows (not context) and maps each anchor with the context rows before it. The existing tests (`SessionProjectionSeedingTests`, `SessionProjectionTests`, `ProjectionExampleTests`) hold the behavior; this is a refactor with no behavior change.
    - Findings 3, 5, 8, 9 (`no_unchecked_sendable`), same cause in the whole file: `HumanWaitGateTests` has 3 (`AnswerHook`, `HookedSessionBackend`, `HookedLLMContainer`), `SubmissionBoundaryToolTests` 2, `AnswerCancellationTests` 1 (`AnswerHook`). `AnswerHook` is the same type in 2 files, and tests set and clear `midAnswer` during a test, so it cannot be immutable: it moves to one shared helper `Helpers/AnswerHook.swift`, a `Sendable` final class with the closure in a `Mutex` (the idiom of `StubSessionBackend`). The mutable fields of the `HumanWaitGateTests` backend and container go into a `Mutex`. `OrderRecordingBackend` has only `let` fields of `Sendable` types, so a plain `Sendable` is sufficient; `OrderRecordingLLMContainer` becomes a struct (as the other `PlainTranscriptStubContainer` conformers).
    - Finding 2: `AnswerCancellationTests.swift` is split into 5 files, one suite (`AnswerCancellationTests`) with extensions in other files, as the repo splits `RoutedSessionActor` into `RoutedSessionActorX.swift` files. The suite name and the test ids do not change. Helpers that tests in other files use become internal (not private), namespaced in the suite.
    - Findings 4, 6, 7 (`swift/fluent-usage`), same cause in the whole file: `CeilingStopCompactionTests`: `answerEvents` -> `makeAnswerEvents`, `cutText(length:)` -> `makeCutText(length:)`. `ScriptedToolAnswerComparisonTests`: `script(narration:)` -> `makeScript(narration:)`, `respondRun`/`streamRun` -> `makeRespondRun`/`makeStreamRun` (each builds and returns a new `ToolAnswerRunOutcome`). `HumanWaitGateTests` static helpers get a first label: `completedAnswer(awaiting:prompt:observer:)`, `completedRun(awaiting:named:finishedWhen:)` (both), `finished(named:when:)`, `isResponse(entry:)`.
    - Findings 11, 12: every `print` in `Tools/RecordCompactionFixture/main.swift` gets `// swiftlint:disable:next no_direct_standard_out_logs` with the reason, the idiom of `Examples/MultiModelGeneration/main.swift`.
  timestamp: 2026-09-26T09:31:33.588930+00:00
- actor: claude-code
  id: 01m3ehd6dk6b6s57vhvv1247ee
  text: |-
    2026-09-26, the 12 findings are fixed (not committed). All 12 items are `- [x]`.

    What changed:
    - `SessionProjection.swift`: 4 loops with a `var` accumulator are gone. `transcriptRows(from:)` uses `reduce(into:)` over a private `ColdTranscriptScan` struct (the old `failUnansweredToolCallRows(in:)` is now its `finishedRows`). `supersededTextEntryIds(in:)` maps the entries to a private `SubmissionMark` enum, splits at each submission start, and keeps all text ids but the last of each submission. `canonicallyOrderedTranscript()` sorts the indices by the ordinals from a new `carriedOrdinals()` (`reduce(into:)`); the `-1` is the named constant `ordinalBeforeEveryRecordedEntry`. `groupedRows(from:supersededTextRowIds:)` finds the anchor rows and maps each with its context rows (`isContext(row:supersededTextRowIds:)`, `groupedItems(anchor:context:)`). No behavior change: the projection suites pass.
    - `AnswerCancellationTests.swift` (100579 bytes) is now 5 files of one suite: `AnswerCancellationTests.swift` (14534 bytes, suite + regression, recording, stranded work, outbox rule), `AnswerCancellationStubs.swift` (16748), `AnswerCancellationFixtures.swift` (23003), `AnswerCancellationEntryPointTests.swift` (16951), `AnswerCancellationCompactionTests.swift` (30273). The other files are `extension AnswerCancellationTests`, so the suite name and the test ids do not change. 25 `@Test` and 124 `#expect`/`#require`/`Issue.record` before and after. A sorted line diff of old and new shows only the dropped `private`, the removed `AnswerHook`, the new file docs and imports.
    - `AnswerHook` (the same type in 2 suites) is one shared `Sendable` helper: `Tests/FoundationModelsRouterTests/Helpers/AnswerHook.swift`, the closure in a `Mutex`.
    - `HumanWaitGateTests`: `HookedSessionBackend` and `HookedLLMContainer` are `Sendable` with their mutable fields in a `Mutex`; the static helpers are `finished(named:when:)`, `completedRun(awaiting:named:finishedWhen:)` (2), `completedAnswer(awaiting:prompt:observer:)`, `isResponse(entry:)`.
    - `SubmissionBoundaryToolTests`: `OrderRecordingBackend` is a plain `Sendable` class (only `let` fields of `Sendable` types); `OrderRecordingLLMContainer` is a struct.
    - `CeilingStopCompactionTests`: `makeAnswerEvents`, `makeCutText(length:)`. `ScriptedToolAnswerComparisonTests`: `makeScript(narration:)`, `makeRespondRun(narration:)`, `makeStreamRun(narration:)`.
    - `ToolOutputProtectionSessionTests`: finding 10 was false. `driveAnswers(_:on:)` is defined in `Tests/FoundationModelsRouterTests/Helpers/CompactionFixtures.swift` (top-level `func driveAnswers(_ count: Int, on session: RoutedSession) async throws`). The suite doc and each of the 6 call sites name that file.
    - `Tools/RecordCompactionFixture/main.swift`: each of the 9 `print` calls has `// swiftlint:disable:next no_direct_standard_out_logs` with the reason (the tool reports its progress on standard out).

    Process notes: the `files` tool echoes the whole file on each edit, so the mechanical renames went to a sub-agent, which used only the `files` tool. No perl, no sed.
  timestamp: 2026-09-26T09:40:41.011469+00:00
- actor: claude-code
  id: 01m3ehdahhh57931cjxjfzgybk
  text: |-
    ### implement — changed
    - evidence: 14 files. Changed: Sources/FoundationModelsRouter/Session/SessionProjection.swift, Tests/FoundationModelsRouterTests/AnswerCancellationTests.swift, HumanWaitGateTests.swift, SubmissionBoundaryToolTests.swift, CeilingStopCompactionTests.swift, ScriptedToolAnswerComparisonTests.swift, ToolOutputProtectionSessionTests.swift, Tools/RecordCompactionFixture/main.swift. New: Tests/FoundationModelsRouterTests/AnswerCancellationStubs.swift, AnswerCancellationFixtures.swift, AnswerCancellationEntryPointTests.swift, AnswerCancellationCompactionTests.swift, Helpers/AnswerHook.swift. `swift test`: 1466 + 15 + 19 = 1500 passed, 2 known issues as before, 0 failed. Changed suites (`--filter` on type names, 11 suites) 3 extra runs: 131 tests passed each time. `swift build --build-tests`: complete, no warning. `swift build --product RecordCompactionFixture`: complete. IntegrationTests `swift build --build-tests`: complete. Only warning: the known mlx "missing creator" line.
    - next: review
  timestamp: 2026-09-26T09:40:45.233379+00:00
depends_on:
- 01M3CYMT8QK7YBJ904JX7CXSG3
- 01M3CYN72XRWG9THXXE5D0QX1B
position_column: doing
position_ordinal: '80'
title: 'Remove the last "turn" names: the boundary tool, awaitingUser, the tracing names and the docs'
---
## Why

Rewritten on 2026-09-25 by the design task ^jdp02p. The earlier plan of this task renamed "turn" to "request". The user rejected that: "A rename of 'turn' to 'request' is NOT the goal"; the "turn" concept is vague and must go, "as opposed to a queue of requests to the Foundation level model to do generation or tool calling". The work-queue tasks remove the turn itself: ^a0ze9af (the worker), ^1psqdm9 (the submission is the item), ^dpn2ytt (reads and forks with no lock), ^3qx0mpt (the pump, no `turnLock`), ^cbhpdjy (the message API), ^x7cxsg3 (the events and `SessionAnswer`), ^5d0qx1b (the limits for each answer and the stored key). This task removes what is left. Design: `generation-queue.md`, sections 5.6 and 5.10.

## What to do

1. Replace `TurnBoundaryTool.turnWillBegin()` with `SubmissionBoundaryTool.submissionWillBegin()`. The session calls it one time before each submission of the pump, after it takes the messages, at the same place as now (after the drain, before the model call).
2. Remove `awaitingUser(_:)` from `RoutedSession`. It is a pass-through since ^93kjn94. A wait for a person in an in-band tool holds the model for every session on it. The way to wait for a person is an elicitation from a background run (`SessionEvent.elicitationRequested`, `respond(elicitationId:response:)`).
3. Rename every other Swift name with "turn" at the request level that the earlier tasks left: for example `recordFailedTurn`, `runTurnAttempt`, `currentTurnEventSink`, `turnEventSink`, `settledRunDeliveryPrompt` docs, `RouterTracing.TurnEntryPoint`, `modelTurnCount` in test helpers, and the "turn" wording in doc comments, `plan.md` and `generation-queue.md`. Keep the recording keys on disk as ^5d0qx1b decided.
4. Update the test names and the suite names that say "turn".

## Acceptance Criteria

- [x] `rg -n "\b[A-Za-z]*[Tt]urn[A-Z]" Sources` shows only recording keys kept for old files and `modelTurnsThinkingOffByTemplateFlag`. <!-- the command prints nothing: `recoveriesPerTurn` and `modelTurnsThinkingOffByTemplateFlag` are still in Sources but the pattern does not match them -->
- [x] `rg -n -i "\bturns?\b" Sources` shows no doc comment that names a request-level "turn". <!-- 13 hits left: the English verb "turn off" / "turns X into Y", and one chat-template "assistant turn" (DiscoveryPriming.swift) -->
- [x] A test: `submissionWillBegin()` is called one time before each submission of the pump, also for a submission that mail started. <!-- SubmissionBoundaryToolTests.aSubmissionThatMailStartedFiresACall, .aContinuationSubmissionFiresItsOwnCall (red before the change), .twoAnswersFireTwoCalls, .oneRespondFiresOneCallBeforeTheModelCall -->
- [x] Public-surface tests for `SubmissionBoundaryTool`. <!-- SubmissionBoundaryToolPublicSurfaceTests.aMountedPublicConformerGetsOneCallForEachSubmission (unit target, plain import, through the decorator chain); SubmissionBoundaryToolConformancePublicSurfaceTests.theCastFindsOnlyAConformer (FoundationModelsRouterPublicSurfaceTests target) -->
- [x] Full `swift test` green, 0 new warnings; IntegrationTests build clean. <!-- swift test: 1466 + 15 + 19 = 1500 passed (was 1496), 2 known issues as before; IntegrationTests `swift build --build-tests`: complete; only warning: the known mlx "missing creator" line --> #generation-queue #naming

## Review Findings (2026-09-26 03:07)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 242 file(s) reviewed, 15 not reviewed.

> ⚠️ 1 file(s) not reviewed — the rendered prompt would exceed the agent's prompt cap:
> - `Tests/FoundationModelsRouterTests/AnswerCancellationTests.swift` — 271468 rendered bytes, over the 262144-byte per-file cap; not reviewed by: duplication (split the file)

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 12 file(s) not reviewed — no validator matched:
> - `Examples/CompactionDemo/README.md` — no validator matches this file
> - `Examples/MultiModelGeneration/README.md` — no validator matches this file
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/GuidedGeneration.md` — no validator matches this file
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md` — no validator matches this file
> - `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/README.md` — no validator matches this file
> - `Tools/RecordCompactionFixture/README.md` — no validator matches this file
> - `UPSTREAM_ASKS.md` — no validator matches this file
> - `compaction_plan.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file
> - `model-pool.md` — no validator matches this file

> ⚠️ Tool rules `code-hygiene/disallowed-constructs-swift`, `code-hygiene/function-length-swift`, `code-hygiene/idioms-swift`, `code-hygiene/magic-numbers-swift` and `code-hygiene/missing-docs-swift` each declined one item for each of these 16 old paths of renamed files, because no file is at the old path: `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Qwen38ToolTurnIntegrationTests.swift`, `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift`, `Sources/FoundationModelsRouter/Hosting/TurnBoundaryTool.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`, `Tests/FoundationModelsRouterTestSupport/ToolTurnScenario.swift`, `Tests/FoundationModelsRouterTests/GenerationQueueTurnTests.swift`, `Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift`, `Tests/FoundationModelsRouterTests/MultiTurnSessionTests.swift`, `Tests/FoundationModelsRouterTests/ScriptedToolTurnComparisonTests.swift`, `Tests/FoundationModelsRouterTests/ScriptedTurnSizingTests.swift`, `Tests/FoundationModelsRouterTests/ToolCallFailureTurnTests.swift`, `Tests/FoundationModelsRouterTests/TurnBoundaryToolTests.swift`, `Tests/FoundationModelsRouterTests/TurnCancellationTests.swift`, `Tests/FoundationModelsRouterTests/TurnFinishReasonTests.swift`, `Tests/FoundationModelsRouterTests/TurnTokenCeilingTests.swift`, `Tests/FoundationModelsRouterTests/TurnTracingTests.swift`.

- [x] `Sources/FoundationModelsRouter/Session/SessionProjection.swift:637` `swift/immutability` — Uses a `var` accumulator in a loop to build a collection. The pattern `var submissionTextEntryIds: [String] = []` followed by `.append()` and `.removeAll()` calls in the loop should use `map`/`compactMap`/`reduceInto` instead, so the final value is clear without walking every line of the loop body. Refactor to eliminate the accumulator by using `reduceInto` to thread the mutable state through the iteration, or by grouping entries by submission boundary first and then using `filter`/`map` to compute the superseded IDs.
- [x] `Tests/FoundationModelsRouterTests/AnswerCancellationTests.swift:1` `review-engine/prompt-cap` — This file exceeds the review prompt cap — 271468 rendered bytes against the 262144-byte per-file cap — so these validators could not review it: duplication. Split the file into smaller modules that fit the review prompt cap.
- [x] `Tests/FoundationModelsRouterTests/AnswerCancellationTests.swift:130` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/CeilingStopCompactionTests.swift:59` `swift/fluent-usage` — Factory method should begin with `make`. This function creates and returns [SessionEvent], a newly constructed collection, so per Apple's API Design Guidelines it should use the factory method pattern (e.g., `makeAnswerEvents`). Rename to `makeAnswerEvents` to follow the factory method naming convention.
- [x] `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:73` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:424` `swift/fluent-usage` — First parameter of non-conversion static function omits its label. The fluent-usage rule requires labels on all parameters except for value-preserving conversions (e.g., `Int64(x)`). This helper function awaits a task to completion—not a type conversion—so the first parameter should carry a descriptive label to clarify the function's intent at call sites. Add a label to the first parameter: `awaiting answerTask:` so the function reads `completedAnswer(awaiting: taskA, prompt: ..., observer: ...)`, making the intent clear at call sites.
- [x] `Tests/FoundationModelsRouterTests/ScriptedToolAnswerComparisonTests.swift:45` `swift/fluent-usage` — Factory methods should begin with `make`. This function creates and returns a `ScriptedAnswerScript` instance, making it a factory method that should be named `makeScript` instead of `script`. Rename the function from `script(narration:)` to `makeScript(narration:)` to follow the factory method naming convention.
- [x] `Tests/FoundationModelsRouterTests/SubmissionBoundaryToolTests.swift:90` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/SubmissionBoundaryToolTests.swift:157` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:111` `completeness/public-output-contract` — The function `driveAnswers(Fixtures.recentAnswerCount, on:)` is called at 6 test sites (lines 111, 128, 142, 160, 178, 197) but is never defined, causing compilation failure. Either the function definition is missing from this change, or these calls should not be present. Either add the definition of `driveAnswers(_:on:)` helper function to the test class, or remove the calls to this undefined function from lines 111, 128, 142, 160, 178, and 197. If the function should exist, provide its implementation with signature: `private static func driveAnswers(_ count: Int, on session: RoutedSession) async throws`. <!-- the helper is defined: `func driveAnswers(_ count: Int, on session: RoutedSession) async throws` in Tests/FoundationModelsRouterTests/Helpers/CompactionFixtures.swift; the suite doc and each call site now name that file -->
- [x] `Tools/RecordCompactionFixture/main.swift:114` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Tools/RecordCompactionFixture/main.swift:179` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.