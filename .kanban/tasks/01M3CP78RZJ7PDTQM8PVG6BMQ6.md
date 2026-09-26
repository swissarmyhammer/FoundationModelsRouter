---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3f41c5c5x680rnqm63sdjar
  text: 'Data from ^cx1type stress (24 processes x 60 repetitions, the ^zr22hpd filter, load 7 to 34), 4 rounds: exit 134 with `_ContiguousArrayStorage deallocated with non-zero retain count 2` in 3, 4, 0 and 4 processes. One round also had 2 processes with exit 139 (SIGSEGV, EXC_BAD_ACCESS in `_swift_release_dealloc`). Crash reports swiftpm-testing-helper-2026-09-26-100246.ips and -100253.ips: the faulting frames are FoundationModels frames and `SessionLanguageModel.Executor.respond(to:model:streamingInto:)`, so it looks like the same use-after-free in another form. Round 1 was at HEAD c75de40 with no change, so this is not from ^cx1type.'
  timestamp: 2026-09-26T15:06:16.620223+00:00
- actor: claude-code
  id: 01m3frjza63rpg0bk4dygf9mb8
  text: |-
    Research (load about 15 of 18 cores; 4 sourcekit-lsp processes of other sessions use about 4 cores).

    1. Reproduced at HEAD 1c99acd: 12 helper processes x 100 repetitions, the task filter: round 1 gave 5 crashes (4 x exit 134 with the retain-count message, 1 x exit 139); round 2 gave 9.
    2. Stack under lldb (ReportCrash wrote no .ips for these runs): the aborting thread is an unnamed task job of FoundationModels (image offsets as in the task), `swift_release_dealloc` -> `swift_deallocClassInstance` -> fatalError. The retain count 2 means that one more retain came after the last release: a read of a shared variable raced a write of that variable. The .ips 100253 (exit 139) shows the same bad object destroyed in `SessionLanguageModel.Executor.respond`, which destroys its copy of the request (its transcript).
    3. Thread Sanitizer (`swift build --build-tests --sanitize=thread`, `swift test --sanitize=thread --skip-build`): it reports only a false positive in ULID.init (the zero-size `SystemRandomNumberGenerator` passed inout; the location is the value witness table of Builtin.Int64). TSan does not see the fault, because the other side of the race is in FoundationModels, which is not instrumented. Note: swiftpm-testing-helper ignores DYLD_INSERT_LIBRARIES (TSan says "interceptors not installed"); use `swift test --sanitize=thread`.
    4. Per suite (12 x 100): ToolResultCompactionTests 6 crashes, GenerationCallUsageTests 2, RejectedToolCallRetryTests 0, SessionEventStreamTests 0. Even `resultUnderTheTriggerDoesNotCompact` (one tool call, no compaction) crashes.
    5. Bisect in Router code: when `MLXFoundationModelsSessionBackend.transcriptUpdates()` gives a finished stream (the repetition watch then reads nothing), the task stress gives 0 of 12. The same binary with the watch on gives 5 and 8 of 12 on the two suites. Thus the trigger is the repetition watch (^1hcwaqy): `Observations { Array(session.transcript) }` reads `LanguageModelSession.transcript` on its relay task while the SDK runs a tool loop.
    6. Probes with a raw `LanguageModelSession` (no Router code), 12 x 200, 16 sessions for each test:
       - tool loop, nothing reads the transcript: 0 crashes (also 0 at 12 x 1000).
       - tool loop, another task reads `session.transcript` in a loop: 12 of 12 crash.
       - text-only model (reasoning + 40 text appends), the same reads: 0.
       - tool loop, reads of `session.usage` or `isResponding` only: 0.
       - tool loop, reads only inside the tool body: 0.
       - tool loop, reads at all times except inside the tool body: 12 of 12.
       - tool loop, reads only while an executor pass runs (a lock opens a gate at the start of `respond` and closes it at the end, and each read holds the lock): 0 of 12 at 300 repetitions.
       Conclusion: the SDK writes the transcript with no guard between the passes of a tool loop (outside the executor pass and outside the tool body). A read from another task in that window races the write. The fault is in FoundationModels (a documented `Observable`, `@unchecked Sendable` type whose getter is not safe), but the Router causes it: the protocol states that the backend must guard its transcript, and the live backend reads from the relay task in that window.
  timestamp: 2026-09-26T21:05:24.806718+00:00
- actor: claude-code
  id: 01m3fy72881s1qany5hh06954q
  text: |-
    Fix landed (not committed).

    Cause: `MLXFoundationModelsSessionBackend.transcriptUpdates()` (the source of the repetition watch, ^1hcwaqy) read `LanguageModelSession.transcript` through `Observations` on a relay task of its own, at all times. `LanguageModelSession` writes its transcript with no guard between two passes of a tool loop, so a read in that window races the write and the runtime aborts. The fault is in the Router's use of the SDK; the SDK getter is also not safe (write-up for Apple in the next comment).

    Change:
    - `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift`: `SessionLanguageModelState` gets pass watches: `addPassWatch(_:)`, `removePassWatch(_:)`, `withPassWatches(_:)`. The executor runs each watch on a child task of the pass (a task group), cancels it when the wrapped executor returns, and waits for it. Thus each watch starts inside a pass and has ended before the pass returns to the SDK. The watches live in the existing `installation` Mutex of the state. There is no new lock, and the session design has no lock.
    - `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: `transcriptUpdates()` installs a pass watch. The watch runs `relayTranscript(of:into:)`: it reads the transcript with `withObservationTracking(options: .didSet)`, gives the value, and waits for the next change on an `AsyncStream`, which ends at a cancel. The stream removes its watch at termination.
    - `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`: the doc of `transcriptUpdates()` states the rule (read only where no unguarded write can run; the live backend gives no value between two passes).

    What did not work: a pass watch that iterates `Observations` in place of the `AsyncStream` wait. The stress test hung in 3 of 3 runs (swiftpm-testing-helper, 40 s watchdog; with the `.timeLimit(.minutes(1))` trait the test fails after 64 s): at times the `Observations` iteration does not end at the cancel of the pass, and the pass waits for a change that comes only after it returns. A small probe (one `Observations` loop, cancelled while it waits) ended at the cancel, so the hang is a rare race, not every cancel.

    Tests:
    - `Tests/FoundationModelsRouterTests/SessionLanguageModelPassWatchTests.swift` (deterministic): the tool body of a two-pass tool loop sees watch counts starts 1, ends 1 (the watch of pass 1 ended by a cancel before the tool ran); after the call starts 2, ends 2, no uncancelled end; a removed watch does not run. RED before the fix: the build failed (`addPassWatch`, `removePassWatch`, `PassWatch` did not exist).
    - `Tests/FoundationModelsRouterTests/TranscriptUpdatesToolLoopTests.swift` (crash regression, about 2 s): 64 backends x 256 tool loops, 4 readers of `transcriptUpdates()` for each call. Before the fix: 5 of 8 runs aborted with the retain-count message. After the fix: 8 of 8 passed (0 retain-count messages).

    Proof of the acceptance items:
    - [x] Stress: 12 helper processes x 100 repetitions with the task filter, 3 rounds after the fix: 0, 0 and 0 crashes, 12 of 12 "Test run with 28 tests in 4 suites passed" each round (load 14 to 43). Before the fix the same command gave 5 and 9 crashes. Note: the filter matches 4 suites only, because `TurnTokenCeilingTests` and `TurnFinishReasonTests` are now `AnswerTokenCeilingTests` and `SubmissionFinishReasonTests`. A wider round (12 x 100 with those two, `GenerationQueueSubmissionTests` and the two new suites; 67 tests in 9 suites) gave 12 of 12 passed, 0 crashes.
    - [x] Regression test: `TranscriptUpdatesToolLoopTests` fails before the fix (5 of 8 runs abort) and passes after it (8 of 8); `SessionLanguageModelPassWatchTests` fails before the fix (does not compile) and passes after it.
    - Full run `swift test`: 1465 + 17 + 19 = 1501 passed (1498 before + 3 new), 2 known issues that the suite expects (RealModelHarness, BoundedWait), 0 warnings.
  timestamp: 2026-09-26T22:43:46.056884+00:00
- actor: claude-code
  id: 01m3fy7cyc5dmhe61jr5nnamxg
  text: |-
    Write-up for Apple (FoundationModels, macOS 27 SDK in Xcode at /Applications/Xcode.app, this machine 2026-09-26).

    Title: `LanguageModelSession.transcript` read from another task during a tool loop aborts the process ("_ContiguousArrayStorage deallocated with non-zero retain count 2").

    `LanguageModelSession` is `Observable` and `@unchecked Sendable`, and its `transcript` getter is public. A read of `transcript` from a second task while a `respond`/`streamResponse` call runs a tool loop aborts the process with the message above (SIGABRT in `swift_deallocClassInstance` on an unnamed FoundationModels task job; FoundationModels offsets 0x94d8c and 0x95714 in each report), and at times gives EXC_BAD_ACCESS in `_swift_release_dealloc`. The window is between the passes: after the executor call returns and before the next executor call, outside the `Tool.call` body. Reads inside a `LanguageModelExecutor.respond` call and reads inside `Tool.call` did not crash. A model with no tool call did not crash. Reads of `usage` and `isResponding` did not crash.

    Minimal repro (no Router code):
    1. A `LanguageModel` whose executor sends `.toolCalls(entryID:action: .toolCall(id:name:action: .appendArguments(json, tokenCount: 1)))` for a mounted `Tool` when the request transcript holds no `.toolCalls` entry, and else sends `.response(action: .appendText(...))`.
    2. 16 tasks at the same time, each: `let session = LanguageModelSession(model: m, tools: [tool], instructions: "i")`; start `Task { while !Task.isCancelled { _ = Array(session.transcript).count; await Task.yield() } }`; then `for try await _ in session.streamResponse(to: "look up the record") {}`; cancel the reader.
    3. Run the test bundle in 12 `swiftpm-testing-helper` processes at the same time, `--repetitions 200` (command in the memory note `stub-backend-producer-race.md`). Result: 12 of 12 processes abort. The same with no reader: 0 of 12 (also 0 at `--repetitions 1000`). The same reader gated to executor passes only: 0 of 12 at 300 repetitions.
    The probe code was a temporary test file (`ZZCrashProbeTests.swift`); it is deleted. The scripted model `Tests/FoundationModelsRouterTests/Helpers/ToolResultCompactionModel.swift` and `LargeResultTool` are the model and tool it used.
  timestamp: 2026-09-26T22:43:57.004773+00:00
- actor: claude-code
  id: 01m3fy7pa966c3t11zjks5xzcb
  text: |-
    Other findings (no tasks filed, as the orchestrator ordered):
    1. `swift test --sanitize=thread` reports a "Swift access race" in `ULID.init<A>(timestamp:generator:)` (ULID.swift in the yaslab package, called from `ULID.generate()` in `MessageID.init()` and `InFlightTranscript.appendingOutputs`). It is a false positive: the location is the value witness table of `Builtin.Int64`, from the zero-size `SystemRandomNumberGenerator` passed `inout`. A TSan run of this repo shows it until it is suppressed.
    2. `swiftpm-testing-helper` run directly ignores `DYLD_INSERT_LIBRARIES` (TSan aborts with "interceptors not installed"), and the Swift backtracer refuses it ("not supported for privileged executables"). Use `swift test --sanitize=thread --scratch-path <dir>` for TSan, and `lldb --batch -o "settings set target.env-vars DYLD_FRAMEWORK_PATH=... DYLD_LIBRARY_PATH=..." -o run -k "thread backtrace all"` for a stack. ReportCrash wrote no `.ips` for these aborts (it throttles).
    3. The stress filter in this task names `TurnTokenCeilingTests` and `TurnFinishReasonTests`, which no longer exist (now `AnswerTokenCeilingTests`, `SubmissionFinishReasonTests`); the filter matches 4 suites and 28 tests.
    4. A pass watch must end soon after its cancel: the pass does not return to the SDK before that. A loop over `Observations` does not always end at a cancel (see the fix comment). Any future pass watch must wait on something that ends at a cancel.
    5. The memory note `stub-backend-producer-race.md` names the same runtime message for the `StubSessionBackend` race. This crash had another cause (the SDK transcript read between passes). I added a memory note for it.
  timestamp: 2026-09-26T22:44:06.601380+00:00
- actor: claude-code
  id: 01m3fy87byrcrzwbwwpf4a5maj
  text: |-
    ### implement — changed
    - evidence: crash stack = FoundationModels task job -> `swift_release_dealloc` -> `swift_deallocClassInstance` fatalError (a retain raced the last release). Cause = `MLXFoundationModelsSessionBackend.transcriptUpdates()` read `LanguageModelSession.transcript` on its own task between the passes of a tool loop, where the SDK writes it with no guard. Files: Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift, Tests/FoundationModelsRouterTests/SessionLanguageModelPassWatchTests.swift (new), Tests/FoundationModelsRouterTests/TranscriptUpdatesToolLoopTests.swift (new). Stress 12 x 100 task filter: before 5 and 9 crashes, after 0/0/0 over 3 rounds; wider 67-test round 0 of 12. Regression test: 5 of 8 aborts before, 8 of 8 passes after. `swift test`: 1465 + 17 + 19 = 1501 passed, 0 warnings.
    - next: /review
  timestamp: 2026-09-26T22:44:24.062643+00:00
- actor: claude-code
  id: 01m3fyw39dnyz3hkhtjyy0b5b5
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (8aafaf3). 1 finding (1 confirmed, 0 refuted). Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:167 code-hygiene/dead-code-swift — var.instance `number` is assignOnlyProperty.
    - next: Remove the assign-only property `number` from the whole file, or make the code read it. Then run the tests and review again. The task stays in review.
  timestamp: 2026-09-26T22:55:15.245826+00:00
- actor: claude-code
  id: 01m3fyx9nc5z1e7skbsc2rbbpx
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — pass watches; transcript read only inside a pass; 2 new tests (crash cause was in the Router)
    - test: green — swift test, 1501 passed (1465+17+19), 0 failed, 0 skipped; 6 related suites 3 extra runs clean; IntegrationTests build clean
    - commit: 8aafaf3
    - review: findings — Concurrency/SessionLanguageModel.swift:167
  timestamp: 2026-09-26T22:55:54.540507+00:00
- actor: claude-code
  id: 01m3fz6aex1ae9vd6e1gsh8z54
  text: |-
    Finding fixed: `SessionLanguageModel.swift` `code-hygiene/dead-code-swift` — var.instance `number` is assignOnlyProperty.

    Decision: remove, not read. `PassWatchID.number` had only one reader, the `Hashable` conformance that the compiler synthesizes. Periphery cannot see that reader. The number was necessary only to make each key unique. That needed a second property, `Installation.nextPassWatchNumber`, which is a counter and has the same cause. Now `PassWatchID` is a `final class` with no stored property. Its `==` is `===` and its `hash(into:)` uses `ObjectIdentifier(self)`. This is the same pattern as `Executor.Configuration` in the same file. Each call of `addPassWatch(_:)` makes a new object, so each key is unique with no counter. `addPassWatch` makes the id outside the lock and holds the lock only for the dictionary write. Both properties are removed. The callers (`LiveModelLoader.transcriptUpdates()`, `SessionLanguageModelPassWatchTests`) do not change: they only keep the id and give it to `removePassWatch(_:)`.

    I did not use `// periphery:ignore`. The rule text permits it for a property that synthesized `Hashable` reads, but the order for this step was to remove the property or make the code read it. With no stored property, no marker is necessary.

    Periphery 3.8 (`swift build --build-tests --scratch-path <scratch>`, then `periphery scan --skip-build --index-store-path <scratch>/out --retain-public --relative-results --format json`): 0 results for `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift`. The same filter finds results in other files of `Concurrency/` (AsyncSemaphore.swift, GenerationQueue.swift), so the filter works. The clean build had no warning from project sources (only mlx-swift Metal warnings).
  timestamp: 2026-09-26T23:00:50.269499+00:00
- actor: claude-code
  id: 01m3fz6jpq5awnz4nrnpwv0ahn
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift (`PassWatchID` is now an identity class; `number` and `nextPassWatchNumber` removed). Periphery: 0 results in the file. `swift test`: 1465 + 17 + 19 = 1501 passed, 2 known issues that the suite expects, 0 warnings from project sources. `SessionLanguageModelPassWatchTests` + `TranscriptUpdatesToolLoopTests` 3 extra runs: 3 tests in 2 suites passed each time.
    - next: /review
  timestamp: 2026-09-26T23:00:58.711725+00:00
- actor: claude-code
  id: 01m3fzkjy3bhg1awvk50whnyw1
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 2e9d710) gave 0 findings (0 confirmed, 0 refuted, 7 validators attempted, 0 failed). The engine reviewed 1 file. The prior finding at `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:167` (`code-hygiene/dead-code-swift`, assign-only property `number`) is checked, and the new review did not find it again.
    - next: None. The task is in `done`.
  timestamp: 2026-09-26T23:08:04.931751+00:00
- actor: claude-code
  id: 01m3fzpekt3nn5mm9tf635wkdd
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (PassWatchID by object identity; unread number and counter removed)
    - test: green — swift test, 1501 passed (1465+17+19), 0 failed, 0 skipped; 4 related suites 3 extra runs clean
    - commit: 2e9d710
    - review: clean — 0 findings
  timestamp: 2026-09-26T23:09:38.810805+00:00
position_column: done
position_ordinal: ffffff9d80
title: Find the crash in the SDK tool loop under parallel load (_ContiguousArrayStorage deallocated with non-zero retain count 2)
---
## What

Test processes that run a real `LanguageModelSession` tool loop through `LiveBackendContainer` crash under parallel load. The runtime writes this message and aborts (SIGABRT):

`Object ... of class _ContiguousArrayStorage deallocated with non-zero retain count 2 ... resulting in a dangling reference.`

The crashed thread is in FoundationModels code with no symbols, under `completeTaskWithClosure`, then `swift_release_dealloc`. The FoundationModels image offsets are the same in each report: 0x94d8c, 0x95714, 0xde975, 0xdcc4d, 0x376d1. This fault is not the same as the `StubSessionBackend` race that ^9smkhk8 (01M20SJKV6YKW4FAFQH9SMKHK8) fixed. That race was in a test stub. This crash is in the SDK path.

## The fault is at HEAD 158f7bf

I built HEAD 158f7bf in a separate git worktree and ran the stress below. 5 of 12 processes crashed with the same message. Thus the fault was there before ^93kjn94.

## Reproduction

Run 12 `swiftpm-testing-helper` processes at the same time. Each process uses `--repetitions 100`, with this filter:

`FoundationModelsRouterTests\.(RejectedToolCallRetryTests|ToolResultCompactionTests|TurnTokenCeilingTests|SessionEventStreamTests|TurnFinishReasonTests|GenerationCallUsageTests)/`

The result is 4 to 5 crashed processes of 12. The command is in the memory note `stub-backend-producer-race.md`. The tests that were in flight at the crash include `SessionEventStreamTests` ("a turn that throws after the SDK durably recorded a tool call still yields that call's events before the stream fails"), and `TurnTokenCeilingTests` / `TurnFinishReasonTests` tool-calling turns. The two tests of `GenerationQueueTurnTests` (^93kjn94) crash the same way. Each test runs a tool loop through the real SDK.

## Next

- Find out if the race is in our code or in the SDK. Our code includes `MLXFoundationModelsSessionBackend`, the executor wrappers (`QueuedLanguageModel`, `RecordingLanguageModel`), the `transcriptEntries()` reads, and the scripted test models. A thread-sanitizer run (`swift test --sanitize=thread`) of one of these suites is the first step.
- If the race is in the SDK, make a minimal reproduction and record it.

## Acceptance

- [x] The stress above gives 0 crashes of 12 processes over 3 rounds.
- [x] A regression test fails before the fix and passes after it.

## Review Findings (2026-09-26 17:52)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Concurrency/SessionLanguageModel.swift:167` `code-hygiene/dead-code-swift` — var.instance `number` is assignOnlyProperty.
