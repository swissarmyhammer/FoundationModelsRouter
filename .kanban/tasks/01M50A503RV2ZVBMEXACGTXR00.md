---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51tysm141y5jkg7k1d01sxh
  text: |-
    Implementation notes (STE).

    - Design check: Extras RunPlane.backgroundRuns() gives each open run of the session plane. A background call that a tool body mounts with ToolContext.mount(_:) is a full run on the same plane, under its own token, and its terminal is staged as mail in the outbox of the session (task ^3rr9rn4). So the design works at each depth. No Extras change.
    - Production: RoutedSessionActorPump.runAnswer reads S0 (readOpenRunTokens) after startAnswerLimits and before the first submission. countAnswer(openRunsAtStart:) is async: user-type mail sets 0 with no read; else it reads S1 and adds 1 only when S1 is not a subset of S0. The pause guard, the held mail, mailDeliveryPaused and the default 100 did not change.
    - Test fixtures: new Tests/.../Helpers/MailOnlyAnswerFixtures.swift (GatedJob with one gate for each run token, InnerJobStarter, a scripted Backend, Session fixture, MessagingRun). The fixtureTools lookup of BackgroundingBackend moved to a shared Array extension.
    - Trap found: the funnel of a run posts its terminal BEFORE the run plane settles the run, so the wake of that post can find nothing to deliver; the wake of deliver(settledTerminal:) starts the answer, and it comes AFTER the waiters of runPlane.wait resume. So "wait for the settle, then pumpEnds()" is a race. The fixture waits on idleChanges until no pump runs and no unheld terminal of the run waits.
    - Trap found: a `count == N` wait for pause events holds forever when the session sends more pauses (old code in test c sent 3). waitForPauses now waits for `>= N`, and each test checks the exact count from the events that end() gives after close.
    - Changed old tests (all in MailOnlyAnswerLimitTests), each only to the new rule: the run of the old LatchedBackgroundToolRunner had an open gate and settled at once, so under the new rule it could settle before the answer end and not count. Each test now keeps each run open at its own gate until the answer that started it ended, then settles it: anEndlessChainStopsAtTheLimit (= test a), theHeldMailRidesTheNextCallerMessage, aCallerMessageStartsTheCountAgain (= test e), aChainUpToTheLimitRunsWhole (its last answer starts no run, so the count stays below the limit; display name changed to say so), aLimitOfZeroHoldsAllMail. Each also checks the exact pause count at the end.
    - Docs updated: SessionConfiguration.mailOnlyAnswerLimit, defaultMailOnlyAnswerLimit and Persistable field, MailDeliveryPause (doc, limit doc and the description text; no test reads that text, the public surface test checks only non-empty), SessionEvent.mailDeliveryPaused, RoutedSession.md, RoutedLLM param doc, RoutedSessionActor.mailOnlyAnswerLimit and mailOnlyAnswersInARow docs, generation-queue.md section 5.4.
  timestamp: 2026-10-16T07:48:50.945107+00:00
- actor: claude-code
  id: 01m51tyy41cezbk0tjb3h5ezgd
  text: |-
    ### implement — changed
    - evidence: production Sources/FoundationModelsRouter/Session/RoutedSessionActorPump.swift; docs SessionConfiguration.swift, MailDeliveryPause.swift, SessionEvent.swift, RoutedSessionActor.swift, RoutedLLM.swift, FoundationModelsRouter.docc/RoutedSession.md, generation-queue.md; tests MailOnlyAnswerCountTests.swift (new), Helpers/MailOnlyAnswerFixtures.swift (new), MailOnlyAnswerLimitTests.swift, Helpers/BackgroundingBackendFixtures.swift.
    - RED on old code (filter on function names, 2 tests matched): manyMessagesOfOneRunDoNotPause failed at MailOnlyAnswerCountTests.swift:126 (prompts.count 4, expected 12); aRunThatSettlesInsideTheAnswerDoesNotCount failed at :146 (prompts.count 4, expected 7). GREEN after the change: both passed. Both suites: 12 tests in 2 suites passed.
    - Full run (one time): "Test run with 1770 tests in 215 suites passed after 8.353 seconds with 1 known issue" (the known issue is the existing withKnownIssue test of RealModelHarness); plus 26 and 19 tests passed; exit 0.
    - IntegrationTests: swift build --build-tests --manifest-cache local → Build complete, exit 0.
    - next: /review
  timestamp: 2026-10-16T07:48:55.553425+00:00
- actor: claude-code
  id: 01m51vkr4vfj4gbhq1yqcks1nx
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (local backend), 2 findings (2 confirmed, 2 refuted) — Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:58, Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:76
    - next: implement the 2 reuse findings (move the shared makeFixture and the first-prompt helper into MailOnlyAnswerFixtures), then test, commit and review again.
  timestamp: 2026-10-16T08:00:17.563937+00:00
- actor: claude-code
  id: 01m51vmcfgdz17jry7tcdmgxf6
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 14 files
    - test: green — swift test, 1770 passed, 1 known issue; IntegrationTests build complete
    - commit: d4048361
    - review: findings — Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:58, Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:76
  timestamp: 2026-10-16T08:00:38.384331+00:00
- actor: claude-code
  id: 01m51vzgee8zmj5c8njbdwhf7t
  text: |-
    ### implement — changed
    - Finding 1 (MailOnlyAnswerLimitTests.swift:58, reuse): the two private makeFixture wrappers are deleted. MailOnlyAnswerFixtures.Session.make is now the one shared make. It takes prefix, limit (default MailOnlyAnswerFixtures.limit), gates (default RunGates()), tool (a closure that makes the tool over the gates; default a GatedJob with the name MailOnlyAnswerFixtures.jobName) and callsTool. Both suites call it with a private directoryPrefix constant.
    - Finding 2 (MailOnlyAnswerLimitTests.swift:76, reuse): startTheChain(on:) and answerTheFirstPrompt(on:) are deleted. The shared helper is MailOnlyAnswerFixtures.Session.answerCallerPrompt(_:). It takes the prompt. The name is answerCallerPrompt, not answerFirstPrompt, because the Limit suite also uses it for the later caller message (it replaced the same respond plus pumpEnds pair there).
    - The same cause, removed in the whole of both files: the two suites had the same constants limit = 3 and promptsOfOneChain = limit + 1, and each had its own jobName. These are now MailOnlyAnswerFixtures.limit, .promptsOfOneChain and .jobName ("gated_job"). The forwarding helper settleTheRunsOfOneChain(on:) in the Limit suite and the same inline call in the Count suite are now one shared Session.settleTheRunsOfOneChain(). settleTheOpenRun(of:) and settleTheOpenRuns(_:of:) take MailOnlyAnswerFixtures.jobName as the default name. The backend picks the tool by its arguments type, not by its name, so the change of the job name does not change test behavior.
    - evidence: files Tests/FoundationModelsRouterTests/Helpers/MailOnlyAnswerFixtures.swift, Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift, Tests/FoundationModelsRouterTests/MailOnlyAnswerCountTests.swift. swift test (one run): exit 0; 1770 tests in 215 suites passed with 1 known issue (the expected RealModelHarness one), plus 26 tests in 14 suites and 19 tests in 3 suites passed; no Swift compiler warnings. IntegrationTests: swift build --build-tests --manifest-cache local, exit 0, Build complete.
    - next: review
  timestamp: 2026-10-16T08:06:42.894818+00:00
- actor: claude-code
  id: 01m51w7knr8jggzka6cqjvsxk5
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (96e08d3e), local backend: 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. The 2 items of "Review Findings (2026-10-16 02:49)" are fixed: the two suites call the shared `MailOnlyAnswerFixtures.Session.make(prefix:limit:gates:tool:callsTool:)` and `answerCallerPrompt(_:)`. The private `makeFixture`, `startTheChain(on:)` and `answerTheFirstPrompt(on:)` copies are deleted.
    - next: none. The task moved to done.
  timestamp: 2026-10-16T08:11:08.344026+00:00
- actor: claude-code
  id: 01m51w85h9jwsrgkpj6jwhw3ac
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files
    - test: green — swift test, 1770 passed, 1 known issue; IntegrationTests build complete
    - commit: 96e08d3e
    - review: clean — 0 findings
  timestamp: 2026-10-16T08:11:26.633410+00:00
position_column: done
position_ordinal: fffffff180
title: Count an answer toward mailOnlyAnswerLimit only when the model started a new background run in it
---
Follow-up (a) of the task 11 review ^jrb5y4t (accepted: keep the limit and its rule).

Today an answer counts toward mailOnlyAnswerLimit when it delivered only run mail (a background run terminal or a ToolContext.message event). Thus a long agent tree with many child messages and no user input can reach the limit (for example 10 children x 10 messages that arrive one at a time), and the session pauses by mistake. Only an answer in which the model started a new background run can make a loop with no end.

Change: an answer counts toward mailOnlyAnswerLimit only when the model started a new background run in that answer. User-type mail still sets the count to zero. The default (100) and the pause behavior do not change.

## Design (accepted by the reviewer)

1. At the answer start (in the pump, before the first submission, in the work of the answer), Router reads the set S0 of the completion tokens of the open runs with `runPlane.backgroundRuns()`. At the answer end (after the answer and all its continuations), Router reads the set S1 the same way. The answer started a new background run when S1 − S0 is not empty. This covers each depth on the session plane: a model background call, a run that a runCode-like tool leaves open, and the run of a nested MCP call.
2. A run that starts and settles in the answer does not count. A run that is open at the two reads does not count.
3. One answer (the first submission and all its continuations) adds 1 at most.
4. User-type mail in the answer (also in a continuation) sets the count to 0. A mail-only answer with a new run adds 1. A mail-only answer with no new run keeps the count (no reset), because a loop also has message-only answers between its run-starting answers.
5. Limit 1: a background run of an earlier answer that starts a new inner run while this answer is open counts for this answer. This is accepted: the error goes toward a pause, never toward a loop with no end.
6. Limit 2: a child session has its own run plane. The guard of the child session covers it.
7. The pause check, the held mail, mailDeliveryPaused and the default 100 do not change. Update only the docs of the count.

## Tests (fixed order, limit 3)

- [x] Fixed-order test: a chain of mail-only answers in which each answer starts a new background run reaches the limit and pauses.
- [x] Fixed-order test: many mail-only answers that start no new background run (child messages and settlements only) do not pause.
- [x] a. A chain: each mail-only answer calls a background tool that continues past the settle period (held at a gate). Its terminal starts the next answer. After 3 run-starting answers, Router holds the next run mail and sends mailDeliveryPaused.
- [x] b. One background run posts 10 messages one at a time (ToolContext.message). Each message starts a mail-only answer that starts no run, then the terminal comes. No pause, and Router delivers all mail.
- [x] c. Run-starting answers mixed with message-only answers pause after 3 run-starting answers (the count stays).
- [x] d. A run that settles in the settle period does not count: 5 such mail-only answers, no pause.
- [x] e. User mail sets the count to 0 (keep or confirm the existing test).
- [x] f. A tool body (a runCode stand-in) starts an inner background run on its ToolContext, returns inline with no pending envelope and keeps that run open at a gate. The terminal of that run starts the next mail-only answer, which does the same. With limit 3, Router holds the 4th run mail and sends mailDeliveryPaused.

#elicitation-phase-3

## Review Findings (2026-10-16 02:49)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:58` `reuse/reuse` — `makeFixture(limit:callsTool:)` duplicates the thin wrapper `makeFixture(tool:gates:callsTool:)` in `MailOnlyAnswerCountTests`. Both only forward to `Fixtures.Session.make` with a per-suite `prefix`. The shared fixtures file already owns the session construction, so each suite keeps a copy of the forwarding. Move a shared `makeFixture` into `MailOnlyAnswerFixtures`, taking `prefix`, `limit`, `callsTool`, and the tool and gates, with the default `limit` and tool-name parameters. Have both suites call it and delete the two private copies.
- [x] `Tests/FoundationModelsRouterTests/MailOnlyAnswerLimitTests.swift:76` `reuse/reuse` — `startTheChain(on:)` reimplements `answerTheFirstPrompt(on:)` from `MailOnlyAnswerCountTests`. Both send `firstPrompt` with `respond(to:)` and then `#expect(await ...pumpEnds())`. The two suites share `MailOnlyAnswerFixtures` but each keeps its own copy, so the answer-to-first-prompt step has two implementations that can drift apart. Move one shared helper, such as `MailOnlyAnswerFixtures.Session.answerFirstPrompt(_:)`, into `MailOnlyAnswerFixtures.swift`. Pass the prompt as a parameter and have both suites call it, then delete both private copies.
