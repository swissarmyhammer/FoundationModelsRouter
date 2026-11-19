---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7smc5ftt5x8ts2h6b93k547
  text: |-
    Research done (implement step).

    - The directory sees each event of a session through its state feed (`followState` -> `recordState(after:of:)`). `SessionEvent.answered(SessionAnswer)` gives the reply and `toolCalls` (name, argumentsJSON); `answerFailed` gives a cancel or an error. No event carries the text of a user prompt: `mailDelivered` and `SubmissionStart` carry only mail ids.
    - Decision for the source of the user prompts: the session reports the prompt text of each user-type mail that an answer delivers to one observer, as it reports the fate of a mail (`observeMailFate`). The call is synchronous, in `runAnswerChain` (first take) and at the join of a continuation, before the `mailDelivered` events. The directory sets the observer at the registration and gives the text to the recapper. The tool calls and the last final message come from the `answered` events of the feed. Rejected: the settled SDK transcript (a compaction reseeds it, run lines and summaries are in prompt entries, and "since the last recap" cannot be found); the journal on disk (a memory-only session has none, and the recorder writes async).
    - The flash call follows `summarizerTiers()` in `RoutedSessionActorCompaction.swift`: `profile.flash.container.makeSession(instructions: nil, samplingMode:)`, here with `.greedy` (temperature 0), and `respondWithoutReasoning(to:maxTokens: 80)` (thinking off).
    - The clock is the Extras `RunClock`; `Router.useRunClock(_:)` gives it to the directory too, so a test advances a `ManualRunClock`.
    - The flash busy check reads `SessionStateTracking` (work started and not ended) of each live entry whose `RoutedSessionActor.model` is `profile.flash.chosen`.
    - A fork starts with no recap: `RouterSessionDirectoryForkTests` (D206 test of ^3566rvs) already covers it.
  timestamp: 2026-11-19T10:06:59.066503+00:00
- actor: claude-code
  id: 01m7snv791vssfhy6dssxa4yr1
  text: |-
    ### implement — changed
    - evidence: policy API `RouterSessionDirectory.useRecapPolicy(_ isRecapOn: @escaping @Sendable (_ workingDirectory: URL) -> Bool)` (public, default on; asked at each idle turn end of a live root session or fork and again before the call). Input source: the session reports the prompt text of each user-type mail an answer delivers (`RoutedSessionActor.observeDeliveredPrompts`, `DeliveredPrompt`, called in `runAnswerChain` and at the join of a continuation); tool calls and the last message come from the `answered` events of the state feed. New files: Directory/SessionRecapper.swift, SessionRecapInput.swift, SessionRecapOutput.swift, SessionRecapPrompt.swift, Session/DeliveredPrompt.swift. Changed: RouterSessionDirectory.swift (recapper, policy, host closures, observe under the state lock before stateChanged, forget at archive/unregister, cancelAll at shutdown, logSession internal), SessionStateTracking.swift (`hasWork` readable), Router.swift (`useRunClock` gives the clock to the directory), RoutedSessionActor.swift, RoutedSessionActorAnswerExecution.swift, RouterTelemetry.swift (`SpanName.recap`). Unit tests: SessionRecapTextTests.swift (11), SessionDeliveredPromptTests.swift (2), SessionRecapperTests.swift (19), RouterSessionDirectoryRecapTests.swift (14 in 2 suites), TelemetryContentSafetyTests+Recap.swift (1), Helpers/RecapFixtures.swift; each new test seen red first (skeleton or mutation run). Filtered changed suites: 53 tests in 7 suites passed. Integration: IntegrationTests SessionRecapIntegrationTests on mlx-community/Qwen3.8-27B-4bit passed (11.4 s), recap "Fixed the nested array parser index bug and added an empty array test; all 14 parser tests now pass." (Qwen3.5 9B is not on this machine). Full `swift test` once: 3177 tests in 360 suites passed, plus 50 and 19 in the other targets, 0 compiler warnings (only the known mlx bundle note); output in scratchpad full-suite.txt. Local only: IntegrationTests/Package.resolved (gitignored) pinned Extras to f99b111 as the root, because bd5009e has no SessionSummary.recap.
    - next: review
  timestamp: 2026-11-19T10:32:40.993982+00:00
- actor: claude-code
  id: 01m7spj27p8v70886tvkbwz35w
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; engine counts findings 3, confirmed 3, refuted 2; plus 2 orchestrator checks. Sources/FoundationModelsRouter/Directory/SessionRecapper.swift:90, Tests/FoundationModelsRouterTests/SessionRecapTextTests.swift:108, Tests/FoundationModelsRouterTests/SessionRecapTextTests.swift:120, Sources/FoundationModelsRouter/Directory/SessionRecapper.swift:547, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:766
    - checks that passed: the recap call uses a new blank backend of the flash container (no KV cache, no transcript of the session, no lock or queue of the session); the observer calls in runAnswerChain and at the continuation join are synchronous and add no suspension point; no read of a live transcript; no unit or integration fixture found that keeps a session idle for 20 s after a non-trivial turn (manual clock advances are 1 s or less; the fork cache integration turns are trivial); the new tests use the injected clock and have no sleeps or time limits.
    - next: implement the 5 open items, then review again.
  timestamp: 2026-11-19T10:45:09.494425+00:00
- actor: claude-code
  id: 01m7spjvbe34bwna9kcwrbxkhb
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionRecapper.swift, SessionRecapInput.swift, SessionRecapOutput.swift, SessionRecapPrompt.swift, DeliveredPrompt.swift (new); RouterSessionDirectory.swift, SessionStateTracking.swift, Router.swift, RoutedSessionActor.swift, RoutedSessionActorAnswerExecution.swift, RouterTelemetry.swift; 5 new test files (47 tests); SessionRecapIntegrationTests (Qwen3.8-27B-4bit)
    - test: green — one full swift test run, 3177 tests in 360 suites (+50, +19), 0 failures; integration 1/1 alone
    - commit: da930780
    - review: findings — SessionRecapper.swift:90 (magic numbers), SessionRecapTextTests.swift:108, :120 (the cut tests do not check the kept text), SessionRecapper.swift:547 (a cancelled recap can still be written: no check after the hop to the directory), RouterSessionDirectory.swift:766 (no test for a close or shutdown, or an archive during a running call)
  timestamp: 2026-11-19T10:45:35.214480+00:00
- actor: claude-code
  id: 01m7sq6j1t27hx7zkyba3x41sq
  text: |-
    ### implement — changed
    - evidence: The 5 review findings are fixed.
      1. magic-numbers-swift: `SessionRecapper.idleSeconds` (20) names the number of `idleTime`. swiftlint `no_magic_numbers` (allowed [0, 1, -1, 100]) on all the Swift files of da930780 now reports only Router.swift:718 (`?? 16`, not part of this change).
      2./3. SessionRecapTextTests: each cut test now also asserts that the first 500 (or 2,000) characters stay. RED: a mutant with `prefix(0)` in `SessionRecapInput.prompt` made both tests fail (`contains(...limit) → false`). The mutant was then reverted.
      4. Commit-if-current: `Host.write` now has a `commit: () -> Bool` argument. `SessionRecapper.commit(_:of:job:)` checks, under the recapper lock, that the job id is still current, and only then removes the prompts, tool calls and turns of the snapshot (it replaces `consume`). Each cancel (`turnStarted`, `forget`, `cancelAll`) takes the job under the same lock. The directory host `writeRecap(_:at:of:ifCommitted:)` calls `commit` under the registry lock and reads the live session under that lock. Then it writes to the live session with `changeLiveRecord` and no suspension point. `unregister` now calls `recapper.forget(id)` inside the registry lock, so a close is ordered with the commit. Archive and shutdown forget the job on the directory actor. A job that is not current writes nothing, sends no `factsChanged`, and keeps the prompts. `recordRecap` stays for the record tests and shares `recapChange`. Tests: FakeRecapHost got a write gate (AsyncSemaphore, which does not obey a cancel). 4 new SessionRecapperTests (new turn, new turn keeps the prompts for the next recap, forget, cancelAll during a held write). RED against the old Host API: all 4 failed (`writes.isEmpty` false; next prompt lacked the first prompt). GREEN: 23/23.
      5. RouterSessionDirectoryRecapTests: 5 new tests (archive during the held call, close during the wait, close during the held call, shutdown during the wait, shutdown during the held call). The fixture has `holdsFlashCalls`. Each test passed with the fix, and each failed in one mutant run with the 3 calls removed (unregister forget, archive forget, shutdown cancelAll). 6 issues: the 5 new tests and the old archive-during-the-wait test. Reverted.
    - Filtered: SessionRecapInputTests 7, SessionRecapperTests 23, RouterSessionDirectoryRecapTests 17, all passed. The IntegrationTests package builds (the host in SessionRecapIntegrationTests calls `commit`).
    - Full `swift test` once: 3186 tests in 360 suites passed, plus 50 and 19 in the other targets, exit 0. No compiler warnings (only the known mlx bundle note). Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-suite-fix.txt
    - next: review (the task stays in doing; not committed)
  timestamp: 2026-11-19T10:56:21.050064+00:00
depends_on:
- 01M7SH8C0CNGBFPYPYT3566RVS
position_column: doing
position_ordinal: '80'
title: The session directory makes a recap on the flash slot after 20 s of idle time after a turn that is not trivial (D206)
---
## Goal

`RouterSessionDirectory` makes the recap of each root session and each fork that it hosts: one sentence of at most 200 characters, about what the session did and where it stands. It costs no model call for a trivial turn, and it never blocks a turn. Decision D206 (`TestudoApp/features/decisions.md`, commit da60a90; the user chose the FLASH slot). Brief: `../.briefs/recap/router-brief.md` items 2, 3, 4 and 5; overview `overview.md`.

## Depends on

The facts task (`recap`, `recapAt` in the record and the summaries).

## Change

1. A new type (for example `SessionRecapper`) that the directory owns. At `workEnded` with the state `idle` for a root session or a fork:
   - A trivial turn makes no call: no tool call and a final message of fewer than 280 characters, or a turn that ended with a cancel or an error.
   - Else a wait of 20 seconds (an injected clock). `workStarted` of the same session cancels the wait and a running call; the output of a cancelled call is discarded. Turns that are not trivial add up until a recap is written.
   - After the wait, the session goes into one queue for each directory (one call at a time for the server). Before a call starts, wait until no session of the directory whose model is the flash model has a running turn (from `workStarted`/`workEnded`). A new turn of the session removes it from the queue or cancels its running call.
   - The input, at most 4,000 tokens: the previous recap, the user prompts of the turns since the last recap (each cut to 500 characters), the names and targets of the tool calls of those turns (for example the changed file paths), and the last final message (cut to 2,000 characters). Cut the oldest prompts first.
   - The call: the `flash` slot, a new blank session `profile.flash.container.makeSession(instructions:samplingMode:)` with only the recap prompt, as the compaction does (`Session/RoutedSessionActorCompaction.swift:429-438`; budget `Compaction/Summarization.swift:107-125`). It never uses or changes the KV cache or the transcript of the session. Thinking off, temperature 0, at most 80 output tokens. The prompt asks for one sentence in the language of the user prompts, the work in the past tense, the state in the present tense, no preamble. The prompt text is in one file (as `Compaction/CompactionPrompt.swift`).
   - The output: remove quotes and line breaks, cut to 200 characters at the end of a word, discard an empty output. Write `recap` and `recapAt` with `updateRecord`, then send `factsChanged`.
   - A failure keeps the previous recap and writes a telemetry span (`RouterTelemetry`) with the session id, the slot, the token counts and the error. The user sees no error.
2. A subagent gets no recap. A `/btw` fork gets none (the host archives it after its turn; the archive cancels the wait).
3. An archive cancels the wait and the call of that session. The recap stays in the record, and an unarchive starts nothing.
4. The policy: the directory takes a recap policy from its host (on or off, for each session folder). Off: no wait and no call; existing recaps stay. Default on. ACPAgent gives it from the setting `sessions.recap`.

Read `routed-session-cancellation-invariants` in the memory folder before a change near the session actor. The recap must not share the session's generation queue in a way that blocks a turn.

## Tests (no sleeps, an injected clock)

- [x] A turn with a tool call, then 20 s of idle time: one call to the flash model in a session that is not the session of the turn, then one `factsChanged`; the record has `recap` and `recapAt`.
- [x] A turn with no tool call and a reply of 20 characters: no call.
- [x] A new turn 5 s after the end: the wait is cancelled; after the second turn, one call with both prompts in the input.
- [x] An archive during the wait: no call, no write.
- [x] A model output of 400 characters: the recap has at most 200 characters and ends at a word.
- [x] A model error: the old recap stays, and a span records the error.
- [x] A fork has no recap at its start. A subagent gets no call.
- [x] The policy off: no call.
- [x] A running turn of another session on the flash model when the wait ends: the call starts only after that turn ends.
- [x] A new turn of the session while its recap runs: the call is cancelled, and nothing is written.
- [x] The KV cache and the transcript of the session are the same before and after a recap.
- [x] The prompt on the bundled flash models (Qwen3.8 27B, Qwen3.5 9B): an integration test that gives one sentence of at most 200 characters. (Qwen3.8 27B 4-bit ran on this machine; Qwen3.5 9B is not on this machine.)

## After

Push when green. Send the sha and the policy API to foundationmodelsmultitool-89, foundationmodelsacpagent-9e and testudoapp-9a. #d206

## Review Findings (2026-11-19 04:33)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/SessionRecapper.swift:90` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/SessionRecapTextTests.swift:108` `completeness/invariant-propagation` — The test that a prompt is cut to 500 characters only checks that no run of 501 'a' characters remains. It does not check that the first 500 characters are kept. An input that drops the prompt entirely passes this test, so the cut rule is not proven. Also assert that the rendered input contains the first 500 characters of the prompt, for example `rendered.contains(String(repeating: "a", count: SessionRecapInput.promptCharacterLimit))`. Then a cut to 0 characters fails the test.
- [x] `Tests/FoundationModelsRouterTests/SessionRecapTextTests.swift:120` `completeness/invariant-propagation` — The test that the last message is cut to 2,000 characters only checks that no run of 2,001 'm' characters remains. An input that drops the last message entirely passes, so the kept part of the message is never proven. Also assert that the rendered input contains `SessionRecapInput.lastMessageCharacterLimit` consecutive 'm' characters, so that an empty last message fails the test.

Checks that the orchestrator asked for (in addition to the engine):

- [x] `Sources/FoundationModelsRouter/Directory/SessionRecapper.swift:547` `orchestrator/cancelled-output-discarded` — `makeRecap` reads `Task.checkCancellation()` and then calls `host.write`, which hops to the directory actor (`recordRecap` → `changeRecord` → `changeLiveRecord`). No part of the write checks the job again. A `workStarted`, an archive (`forget`) or a close that comes during the hop cancels the task, but the write still runs: the output of a cancelled call goes to the record and sends `factsChanged`, and `consume` then removes the prompts. When the session closed during the hop, `changeRecord` writes to the `index.md` of the recorded session. Make the check and the write one step: for example, give `Host.write` a guard that reads, on the directory actor and under the lock of the recapper, that the job `jobID` of the session is still current, and write nothing when it is not. Add a test that cancels the job after the cancel check and before the write (a held `write` in the test host) and expects no write.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:766` `orchestrator/cancel-paths-tested` — The close of a session calls `recapper.forget(id)`, and `shutdown()` calls `recapper.cancelAll()`, but no test proves that a close or a shutdown during the wait or during the call makes no call and writes nothing. No test proves that an archive during a running call writes nothing (the archive test covers only the wait). Add one test for each path: a close during the wait, a close during a held call, a shutdown during a held call, and an archive during a held call. Each test must fail when the matching `forget` or `cancelAll` call is removed.
