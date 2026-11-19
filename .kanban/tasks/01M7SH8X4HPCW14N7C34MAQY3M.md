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
- actor: claude-code
  id: 01m7sqewds1qxg77zpabawa7ke
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (c58e9df3): engine 1 finding (1 confirmed, 0 refuted), plus 1 orchestrator check. Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2961, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2964. All 5 items of 2026-11-19 04:33 are fixed. The lock order (registry, then recapper) has no deadlock path.
    - next: implement the 2 items of "## Review Findings (2026-11-19 04:56)": no step after the commit can throw on the recorded path or the live path.
  timestamp: 2026-11-19T11:00:53.817272+00:00
- actor: claude-code
  id: 01m7sqfrwgerex0ys5awmfv58x
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — SessionRecapper.swift (commit-if-current), RouterSessionDirectory.swift (writeRecap, forget in unregister), 5 test files (+4 held-write tests, +5 cancel-path tests)
    - test: green — one full swift test run, 3186 tests in 360 suites (+50, +19), 0 failures
    - commit: c58e9df3
    - review: findings — RouterSessionDirectory.swift:2961 (a recorded write that throws after commit() loses the prompts), :2964 (a close between the lock and changeLiveRecord writes the recap with no factsChanged and a false failure log). Lock order checked: no deadlock.

    Orchestrator decision: split the commit in two. (1) Under the recapper lock, check that the job is current and mark it as writing; a cancel during the write only marks the job as cancelled. (2) Do the write. (3) Only after the write succeeded, and only if the job was not cancelled meanwhile, remove the covered prompts, send factsChanged once, and log success. A write that throws keeps the prompts and logs the failure. The live path must not throw after the write: if the entry went away, take the recorded path or treat it as a write with no live summary, but never log a failure for a recap that is in the record.
  timestamp: 2026-11-19T11:01:22.960876+00:00
- actor: claude-code
  id: 01m7sqwqc59eq8324sx6c51bhb
  text: |-
    Picked up for the 2 items of "## Review Findings (2026-11-19 04:56)". Research:
    - `writeRecap` calls `commit()` under the registry lock; `commit()` checks the job AND removes the covered prompts. Then the recorded path awaits `changeRecord` (can throw), and the live path calls `changeLiveRecord`, which ends with `requireLiveSummary` (throws when a close removed the entry).
    - The live write has no suspension point between the registry lock and `actor.updateRecord`, but `unregister` is nonisolated, so a close on another thread can land there. A test can hold that window without a production hook: a thread that holds the record lock of the session (`updateRecord` with a closure that waits on a semaphore) stops the live write in `updateRecord`; the test then calls `unregister` and opens the semaphore.
    - In the real flow, the recorded path with a current job needs an entry whose weak session is gone (a close forgets the job). The directory tests drive the recapper of a directory directly (fake flash target, `writeRecap` as the write) on a recorded session with a read-only folder (0o500), as `SessionIndexRecordingTests` does for a failed save.
    - Log capture: the recapper tasks are plain `Task {}`, so they inherit the task-local `TelemetryCapture` of the test that feeds the turn.
    Plan (orchestrator decision): `Host.write` gets `WriteSteps` (begin: check the job and mark it as writing; finish: after a successful write, check that no cancel came and remove the covered items) and returns whether the recap went out. A cancel of a writing job does not cancel its task. Rule for a cancel during the write: the record keeps the recap (a written file is not taken back), the prompts stay for the next recap (which gets the written recap as its previous recap), no factsChanged, no success log and no failure log.
  timestamp: 2026-11-19T11:08:27.397706+00:00
- actor: claude-code
  id: 01m7st4581wafb4kwvsfd7rbdn
  text: |-
    ### implement — changed
    - evidence: The 2 items of "## Review Findings (2026-11-19 04:56)" are fixed and checked.
      Design (orchestrator decision): `SessionRecapper.Host.write` now takes `SessionRecapper.WriteSteps` and returns `Bool` (true when the recap went out). (1) `start`: under the recapper lock, checks that the job is current and sets the phase `.writing`. A cancel (turnStarted, forget, cancelAll) of a writing job only takes the job; `Job.task` gives nil for `.writing`, so the task of the write is not cancelled. (2) The host writes the record. (3) `finish`, after a successful write only: if the job is still current, removes the covered prompts, tool calls and turns, and gives true. Then the host sends `factsChanged` one time (only when the record changed), and the recapper logs "wrote a recap" (debug). A write that throws calls no `finish`: the prompts stay, and the recapper logs "a recap write failed; the session keeps its previous recap, and the next recap covers the same prompts" (warning), which is separate from the call-failure log.
      `RouterSessionDirectory.writeRecap(_:at:of:steps:)`: reads the live session under the registry lock, then calls `steps.start()` under the recapper lock only (no nested lock). Live path: `applyLiveRecordChange` (new, static, can throw only before the change) → `finish` → `recordFactsChange`. No `requireLiveSummary` after the write. Recorded path: `changeRecordedRecord` → `finish` → `emit(.factsChanged)`. `changeLiveRecord` uses `applyLiveRecordChange`.
      Rule for a cancel during the write (written in the docs of SessionRecapper, WriteSteps, writeRecap, forget, cancelAll, turnStarted): the write runs to its end; the record keeps the recap (a written record is not taken back; the next recap gets it as its previous recap); the prompts stay for the next recap; there is no `factsChanged` and no success or failure log.
      Files: Sources/FoundationModelsRouter/Directory/SessionRecapper.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/Helpers/RecapFixtures.swift (WriteHold before/after the start, cancelledWrites, startedWrites, host(writingThrough:afterStart:), shared SessionRecapper.feedTurn), Tests/FoundationModelsRouterTests/SessionRecapperTests.swift (+2 tests; runTurn uses feedTurn), Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecapWriteTests.swift (new, 3 tests), IntegrationTests/.../SessionRecapIntegrationTests.swift (new host API; the package builds).
      RED, each run one time before the fix (against the old API): recapper "a new turn after the start of the write keeps the prompts" (the prompt was missing) and "...does not cancel the write" (cancelledWrites 1); directory "a recorded recap write whose save fails keeps the prompts" (folder 0o500, FrontmatterDocumentSaveError; the prompt was missing) and "...logs the failure of the write" (only "a recap call failed" was logged); "a close during the live recap write logs no failure" (it logged "a recap call failed"). GREEN: 5/5.
      What did not work: the first version of the close test held the session record lock on its own thread. In the full run that deadlocked: `scanInbox` on the directory actor reads `facts` under the same lock, so the write never started. Stacks: scratchpad/hang-sample.txt. I stopped that run. The test now closes the session (`unregister`) from a test host hook right after `start` and before the record write. RED for this version came from a temporary mutant that put back the summary read after the write (the false failure log showed). The mutant was then reverted.
      Filtered changed suites: 82 tests in 8 suites passed (with the existing held-write tests). Full `swift test`, one run after the last change: 3191 tests in 361 suites, plus 50 and 19, exit 0, only the known mlx bundle note. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-suite-write-steps-2.txt
    - next: review (the task stays in doing; not committed)
  timestamp: 2026-11-19T11:47:28.129828+00:00
- actor: claude-code
  id: 01m7stdz83v7ckc5egc38ehkhj
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (0813c581): engine counts findings 1, confirmed 1, refuted 3. IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SessionRecapIntegrationTests.swift:108 (the integration host records the recap before `steps.finish()`; the RecapFixtures host records it only after `finish()` returns true).
    - The 2 items of "## Review Findings (2026-11-19 04:56)" are fixed. The orchestrator checks found no finding: no step after the record write throws on the recorded path or the live path; a write that throws keeps the prompts and `endCall` clears the `.writing` job; no lock is nested in `writeRecap` (registry lock, released, then recapper lock); no file write or `await` under a Mutex; a cancel during the write does not cancel the write and gives no `factsChanged`; the new tests use a host hook and an `AsyncSemaphore` gate, and no thread blocks on a lock.
    - next: implement the 1 open item of "## Review Findings (2026-11-19 05:48)", then review again. The task stays in review.
  timestamp: 2026-11-19T11:52:49.667339+00:00
- actor: claude-code
  id: 01m7stek27bgf9h5scw3ctz7y4
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — SessionRecapper.swift (WriteSteps), RouterSessionDirectory.swift (writeRecap), RecapFixtures.swift, SessionRecapperTests.swift (+2), RouterSessionDirectoryRecapWriteTests.swift (new, 3), SessionRecapIntegrationTests.swift
    - test: green — one full swift test run after the last change, 3191 tests in 361 suites (+50, +19), 0 failures (the first run hung in the first version of a new test; stacks saved; the test was redesigned)
    - commit: 0813c581
    - review: findings — SessionRecapIntegrationTests.swift:108 (the test host records the recap before steps.finish())
  timestamp: 2026-11-19T11:53:09.959948+00:00
- actor: claude-code
  id: 01m7sthfxgj27ktx9zc58ptzse
  text: |-
    ### implement — changed
    - evidence: IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SessionRecapIntegrationTests.swift. The write closure of the test host now does `guard steps.start(), steps.finish() else { return false }`, then `writes.record(recap)`, then `return true`. A recap counts as written only when `finish()` gives true, as in the `FakeRecapHost.host` of RecapFixtures.swift. The doc of `WriteLog` now says "wrote with no cancel".
    - Shared helper: not possible without a root source change. `SessionRecapper` and its `Host` and `WriteSteps` are internal, and FoundationModelsRouterTestSupport (the only target that both test packages share) sees only the public and `package` surface. A shared helper would need a wider access level on production types. Also, the unit host runs its write gate between `start` and `finish`, so one helper does not fit both hosts. Thus both hosts keep the same order: start, finish, then record.
    - No change outside IntegrationTests, so the full root `swift test` was not run.
    - TDD: no RED run. The change is in a test host, and no unit test can make a real-model integration host fail in a cancel window.
    - Tests: `swift build --package-path IntegrationTests --build-tests`: build complete, no compiler warnings (only the known mlx bundle note). `swift test --package-path IntegrationTests --skip-build --filter SessionRecapIntegrationTests`, one run: 1 test in 1 suite passed (3.19 s).
    - next: review (the task stays in doing; not committed)
  timestamp: 2026-11-19T11:54:45.040606+00:00
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

## Review Findings (2026-11-19 04:56)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2961` `completeness/invariant-propagation` — On the recorded path, writeRecap calls commit() at line 2957 before the write. commit() removes the covered prompts, tool calls and turns from the recapper state. If changeRecord(of:_:) then throws (for example, the index.md read or save fails), the error goes to makeRecap's catch, which only logs that the session keeps its previous recap. The prompts are already gone, so the next recap cannot see them. The live path (line 2964) has no throwing step after commit, so the removal-after-write invariant holds only on the live path. The recorded path breaks it. Make the recorded-path write succeed before the prompts are removed, or restore the removed prompts when the write throws. Alternatively, have commit() only mark the job as committed, and remove the covered items after changeRecord returns. Add a test where the recorded session's index.md save fails, and assert that the prompts remain for the next recap.

Checks that the orchestrator asked for (in addition to the engine):

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2964` `orchestrator/live-write-outcome` — The live path also has a throwing step after the commit. `unregister(_:)` is `nonisolated` and takes only the registry lock, so a close on another thread can remove the entry after `writeRecap` releases the lock and before `changeLiveRecord` reads the summary. Then `actor.updateRecord` writes the recap, `recordFactsChange` finds no entry and sends no `factsChanged`, and `requireLiveSummary` throws `unknownSession`. `makeRecap` catches the error and logs "a recap call failed; the session keeps its previous recap", but the record holds the new recap. The doc of `writeRecap` says that a committed recap of a live session goes to that session also when it closes just after the commit. Make the outcome true: when the commit holds and `updateRecord` ran, the write must not throw and must not log a failure (for example, write through `updateRecord` and `recordFactsChange` and do not require a live summary after the commit). Fix this together with the item above, so that no step after the commit can throw on either path.

Lock-order check (asked by the orchestrator), with no finding: the recapper never takes the registry lock and never calls the host under its own lock (`commit`, `forget`, `cancelAll`, `turnStarted`, `startWait`, `enqueue`, `startNextCall`, `endCall`, `snapshot` only change its state and make tasks; `Task.cancel` and `jobChanges.signal()` run after its lock). The order is always registry lock, then recapper lock (`recordState` → `observe`, `unregister` → `forget`, `writeRecap` → `commit`). The cancel handlers that a cancel under the registry lock can run (`ChangeSignal.waitForChange`, the clock sleep, the flash backend call) take only their own locks. `writeRecap` runs no file write and no `await` under the registry lock; `changeLiveRecord` is synchronous and does not call into the session actor with an `await`. The held-write tests use an `AsyncSemaphore` gate and the jobs signal, not a clock, and each fails when the job check of `commit` is removed.

## Review Findings (2026-11-19 05:48)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/SessionRecapIntegrationTests.swift:108` `completeness/invariant-propagation` — The test write closure records the recap before it calls steps.finish(). If a cancel came during the write, finish() returns false and the recap is still counted as written. The sibling host in RecapFixtures.swift records only after steps.finish() returns true. The two write paths disagree about what counts as a written recap, so this test cannot catch a regression in the cancel rule it is meant to mirror. Call steps.finish() first and return false when it fails. Record the write only after finish() returns true, as the RecapFixtures host does. Then writes.all reflects only recaps that the recapper sent out.

Checks that the orchestrator asked for (in addition to the engine), with no finding:

- The 2 items of 2026-11-19 04:56 are fixed. `writeRecap` calls `steps.start()` before the write and `steps.finish()` only after a write that succeeded. On the recorded path, only `changeRecordedRecord` can throw, and it throws before `finish`; `finish`, `recordedSummary` and `emit` do not throw. On the live path, only `recordOwner` can throw, and it throws before `updateRecord`; `finish` and `recordFactsChange` (`try?`) do not throw, and no `requireLiveSummary` comes after the write.
- A write that throws calls no `finish`, so the prompts, the tool calls and the turns stay. `endCall` then clears the job in the `.writing` phase, so the job does not stay. The failure log is the new warning "a recap write failed", which is separate from the call-failure log.
- Lock order: `writeRecap` reads the live session with `session(id:)` (the registry lock only, then released), then calls `start` (the recapper lock only). `finish` releases the recapper lock before `recordFactsChange` or `emit` takes the registry lock. No lock is nested in `writeRecap`. `unregister` → `forget` keeps the order registry lock, then recapper lock. `startWrite` and `finishWrite` call no host and make no task.
- No file write and no `await` is under a Mutex. The recorded save runs on the directory actor. The live write uses `RoutedSessionActor.updateRecord`, as before.
- A cancel during the write: `takeJob` gives no task for `.writing`, so the write is not cancelled, and `finishWrite` finds the job gone and gives `false`. This agrees with the decided rule.
- Tests: the directory close test runs `unregister` from the `afterStart` hook of the host on the task of the write, after `start` released the recapper lock. No thread blocks on a lock. The recapper tests use the `AsyncSemaphore` gate and the jobs signal. The implementer reports each new test red before the fix (the comment of 2026-11-19 11:47).