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