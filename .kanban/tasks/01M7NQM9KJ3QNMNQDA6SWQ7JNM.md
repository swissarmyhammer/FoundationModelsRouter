---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqptptakea9mbjzmg5wesk
  text: The Extras task for `SessionName.default` is 01M7NQMD2D1N7W7WXV4ZX2NJ0A (Extras board). Start this task when it is done.
  timestamp: 2026-11-17T21:48:16.474329+00:00
- actor: claude-code
  id: 01m7qbmj04gvehzqakzccqqjhj
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — not started. `SessionName.default` is not in FoundationModelsExtras (no match in `FoundationModelsExtras/Sources`). Extras task 01M7NQMD2D1N7W7WXV4ZX2NJ0A is in `doing` on the Extras board. This task must not write a local copy of the rule.
    - next: start again when the Extras task is done and the Router pin of Extras includes it.
  timestamp: 2026-11-18T12:55:47.972266+00:00
- actor: claude-code
  id: 01m7qf287ar76w02n8p6386qap
  text: |-
    Research and design (implement step):
    - `session/new` of a client and the `start session` tool are in the host packages. In the Router, each new root session reaches the directory through `register(_:kind:parentID:requestedByClient:)` (vend in `RoutedLLM.registerVendedSession`, restore in `SessionTreeRestoration`, and `admit` for a session of another router). Thus the default name is given in `register`, before the `started` event, and only for the kind `root`. `start(_:)` and `startAgent` go through `launch` -> launcher -> `register`.
    - `complete(facts:with:)` now sets `facts.title = request.title ?? facts.title`: the session is new, thus its title is the request title or the default name. A launcher that drops the request title still gets it (test `startWritesTheFactsALauncherDidNotCopy`).
    - New lock `naming` (Mutex<Void>) holds the naming and the registration in one step, so two sessions in one folder never get one name. It is always taken before the registry lock, never under it.
    - `register` is synchronous, thus the host recording roots (async closure) cannot be read there. Used names = live sessions + sessions recorded in the recording root of the new session + the usage-store roots.
    - A recorded root session with no title (or an empty title) that is not live gets its default name in `recordedSummaries()` (oldest first), and the name is written to its `index.md`. `changeRecordedRecord` names an untitled record first.
    - Agent name for the rule: `agentName`, else `agentID`, else empty (gives "session").
    - Two tests of `RouterSessionDirectoryRecordedTests` asserted `title == nil` for a record with no title; they now expect the fallback default name "session".
  timestamp: 2026-11-18T13:55:42.446012+00:00
- actor: claude-code
  id: 01m7qf83tdpn798yrbftj4ga30
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/SessionDefaultTitle.swift (new), Sources/FoundationModelsRouter/Directory/RecordedSessions.swift; Tests/FoundationModelsRouterTests/RouterSessionDirectoryDefaultNameTests.swift (new, 13 tests, RED then GREEN), RouterSessionDirectoryRecordedTests.swift, SessionIndexRecordingTests.swift, RouterSessionDirectoryMessageTests.swift (3 old tests expected no title; they now expect the default name). `swift test`: 2864 tests in 332 suites passed, plus 48 and 19; 0 failures; only the known bundle "missing creator" warning.
    - Note: the recording roots of the host are async and `register` is sync, so a new session counts only the recorded sessions in its own recording root and in the usage-store roots. A read (`recordedSummaries`) counts all roots.
    - next: review
  timestamp: 2026-11-18T13:58:54.541311+00:00
- actor: claude-code
  id: 01m7qfhrhm7ck4z4fzpk78r210
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 40391155): 3 findings (3 confirmed, 2 refuted). Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:364, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:382, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1046
    - next: implement the 3 open items in "Review Findings (2026-11-18 07:59)", then review again.
  timestamp: 2026-11-18T14:04:10.676944+00:00
- actor: claude-code
  id: 01m7qfj7y8t3h6sf98hkps0fpc
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionDefaultTitle.swift (new), RecordedSessions.swift, 4 test files
    - test: green — swift test in the implement step, 2864 tests in 332 suites (+48, +19), 0 failures
    - commit: 40391155
    - review: findings — RouterSessionDirectory.swift:364, RouterSessionDirectory.swift:382, RouterSessionDirectory.swift:1046
  timestamp: 2026-11-18T14:04:26.440157+00:00
- actor: claude-code
  id: 01m7qfvr2m5cyea5qh1gw9nswt
  text: |-
    Review findings (2026-11-18 07:59), implement pass:
    - Finding 1 (:364): `giveDefaultTitle(to:)` now uses `do`/`catch` around `recordOwner(of:)`. The catch logs through `RouterTelemetry.makeLogger(.sessionDirectory)` with the error metadata and the session id, then returns; the registration goes on. No other `try?` is in the file.
    - Finding 2 (:382): new `nonisolated func usageStoreRecordingRoots() -> [URL]`. `allRecordingRoots()` and `recordedSummaries(besides:)` both call it.
    - Finding 3 (:1046): new `SessionDefaultTitle.given(_:)` (an empty title counts as no title). `complete(facts:with:)` uses it, and so do `isMissing(in:)`, the live summary (`summary(of:in:usage:)`, which before gave an empty title as is), and `RecordedSessions.summary(of:)` (which had its own inline copy of the rule). Thus all reads of a title use one rule. New test `aStartWithAnEmptyTitleGivesTheDefaultName`: RED (title was ""), then GREEN.
  timestamp: 2026-11-18T14:09:37.876590+00:00
- actor: claude-code
  id: 01m7qfvvj43sx8nc4nzcrn333t
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/SessionDefaultTitle.swift, Sources/FoundationModelsRouter/Directory/RecordedSessions.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryDefaultNameTests.swift (+1 test). `RouterSessionDirectoryDefaultNameTests`: 14 tests passed. Full `swift test` (one run): 2865 tests in 332 suites, 1 test failed with 2 issues (`ConsecutiveRecoveryBudgetTests/keyReorderedRepeatIsNoProgress`: "call 4 held for a stop, and no stop of the session came inside 10.0 seconds"); +48 and +19 passed; only the known bundle "missing creator" warning. That suite alone passed (6 tests, 0.087 s). The test waits on a 10-second time limit and does not touch the default name; recorded as ^jrcr4ge.
    - next: test, then review
  timestamp: 2026-11-18T14:09:41.444258+00:00
- actor: claude-code
  id: 01m7qg95ak18ydgn8c19y2c5jy
  text: |-
    ### review — findings
    - evidence: review sha 40391155..dc87bbf7 — 3 findings (3 confirmed, 1 refuted). The 3 items of 2026-11-18 07:59 are checked. New items: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:372 (duplication/duplication), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:372 (reuse/reuse), Tests/FoundationModelsRouterTests/RouterSessionDirectoryDefaultNameTests.swift:283 (reuse/reuse).
    - next: Put the logger call and metadata merge in one private helper that giveDefaultTitle and recordedSummaries both call. Make one parameterized test over the titles nil and "", or one shared helper for the two tests. The task stays in review.
  timestamp: 2026-11-18T14:16:57.427165+00:00
- actor: claude-code
  id: 01m7qg9tyva6ed0f5z6hp8hhxk
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionDefaultTitle.swift, RecordedSessions.swift, RouterSessionDirectoryDefaultNameTests.swift (+1 test)
    - test: green — swift test, 2865 tests in 332 suites (+48, +19), 0 failures (after the fix of ^jrcr4ge, commit fe50197d)
    - commit: dc87bbf7
    - review: findings — RouterSessionDirectory.swift:372 (x2, one cause), RouterSessionDirectoryDefaultNameTests.swift:283
  timestamp: 2026-11-18T14:17:19.579386+00:00
- actor: claude-code
  id: 01m7qgktzazpze8tb7a3psf48v
  text: |-
    Review findings (2026-11-18 08:14), implement pass:
    - Findings 1 and 2 (:372, one cause): new `private static func logSession(_ level:_ message:session:error:metadata:)` in RouterSessionDirectory.swift. It is the one place that makes the logger of the session directory, merges the error metadata, and adds the session id. `giveDefaultTitle` and `recordedSummaries(besides:)` call it with their own messages. All other copies of the pattern in the file call it too: `writeMissingFacts`, `recordOwner`, `awaitEnd` (debug), `sendArchived` (notice, with `archivedBy`), and `logInbox` (which now only adds the file path, and takes `error:` in place of a prebuilt error metadata). No `makeLogger` or `errorMetadata` call stays in the file outside the helper.
    - Finding 3 (test :283): `aStartWithNoTitleGivesTheDefaultName` is now `@Test(arguments: [nil, ""] as [String?])` with a `title` parameter; `aStartWithAnEmptyTitleGivesTheDefaultName` is removed. The comment names the production change of each case.
  timestamp: 2026-11-18T14:22:47.274245+00:00
- actor: claude-code
  id: 01m7qgkxcedzjcca3w3br2gp3n
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryDefaultNameTests.swift. `swift test --filter FoundationModelsRouterTests.RouterSessionDirectoryDefaultNameTests`: 13 tests passed (the parameterized test has 2 cases). Full `swift test` (one run): 2864 tests in 332 suites passed (one less because two tests became one), plus 48 and 19; 0 failures; only the known bundle "missing creator" warning.
    - next: review
  timestamp: 2026-11-18T14:22:49.742340+00:00
- actor: claude-code
  id: 01m7qgpjs0xph3ghez8m99tzep
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (48a28387). 0 findings (7 attempted, 0 failed). All 6 prior items are checked. The code shows each fix: the do/catch log in giveDefaultTitle, usageStoreRecordingRoots() shared by the two root paths, SessionDefaultTitle.given(request.title) in complete(facts:with:), the logSession helper for the log blocks, and one test with the arguments nil and "".
    - next: task moved to done.
  timestamp: 2026-11-18T14:24:17.184222+00:00
- actor: claude-code
  id: 01m7qgq904w41k7sz4w06qmjyp
  text: |-
    ### finish iteration 4 — clean
    - implement: changed — RouterSessionDirectory.swift (logSession helper), RouterSessionDirectoryDefaultNameTests.swift (one test with nil and "")
    - test: green — swift test, 2864 tests in 332 suites (+48, +19), 0 failures
    - commit: 48a28387
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-18T14:24:39.940730+00:00
position_column: done
position_ordinal: ffffffffffa980
title: Give each new session a default name from its agent (D199 (b))
---
## Goal

The Router owns the session facts (ROUTER-1), thus it owns the default name of a session (D199 (b), TestudoApp `features/decisions.md`, commit 740cd1a). Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, item 4.

## Depends on

FoundationModelsExtras: `SessionName.default(agentName:usedNames:)`. Do not start before it lands. Do not write a local copy of the rule.

## Current behavior

`complete(facts:with:)` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:929`) sets `facts.title = facts.title ?? request.title`. A session with no title in the request has no title.

## Change

- When the directory registers a new session and the request has no title, set the title to `SessionName.default(agentName:usedNames:)`. `usedNames` are the titles of the sessions in the same folder that are not archived (live and recorded).
- This applies to each start: `session/new` of a client, `start session` of the tool, and `startAgent` (`RouterSessionDirectory.swift:1365`).
- A recorded session with no title (made before D199) gets the default name when the directory reads it.
- Only a rename (`setTitle`, D197, D192 (c)) changes the name.

## Tests

- [x] A new session of the agent `claude-code` has the name `claude-code`.
- [x] A second one in the same folder has the name `claude-code-2`.
- [x] One in another folder has the name `claude-code`.
- [x] An archived session with the name does not block the name.
- [x] A request with a title keeps its title.
- [x] A rename replaces the default name, and the name stays after the next read.
- [x] A recorded session with no title reads with a default name.
- [x] `startAgent` gives the default name. #d199

## Review Findings (2026-11-18 07:59)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 12 not reviewed.

> 12 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 12 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:364` `completeness/public-output-contract` — In `giveDefaultTitle(to:)`, `try? Self.recordOwner(of: session)` discards the error and returns with no log. A root session that is not a `RoutedSessionActor` therefore registers with no default name, and no operator sees why. The sibling path in `recordedSummaries` logs its failure, so this site is inconsistent with the handling the change adds elsewhere. Replace `try?` with a `do`/`catch` that logs through `RouterTelemetry.makeLogger(.sessionDirectory)` with the session id, the same way `recordedSummaries` does, and then returns. The registration must still go on.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:382` `reuse/reuse` — recordedSummaries(besides:) rebuilds the usage-store recording-root list inline (`currentUsageStore()?.usages().values.compactMap(\.recordingRoot)`). That is the same gathering that allRecordingRoots() already does for the usage store. A second copy can drift from the first, for example if the root rule changes, and only one of the two copies gets fixed. Pull the usage-store root extraction out of allRecordingRoots() into a small non-async helper, for example `usageStoreRecordingRoots()`, and call it from both allRecordingRoots() and recordedSummaries(besides:). The sync and async paths then share one rule.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1046` `completeness/invariant-propagation` — The title rule in `complete(facts:with:)` takes `request.title ?? facts.title`. An empty request title (`""`) is not `nil`, so it replaces the default name that `giveDefaultTitle(to:)` gave at registration. The live facts then hold an empty title. `SessionDefaultTitle.isMissing(in:)` treats an empty title as no title, so the empty-title rule is applied at that site but not at this one. A live session can end with an empty title, while a recorded read of the same session names it. Treat an empty request title as no title in `complete(facts:with:)`, for example `if let title = request.title, !title.isEmpty { facts.title = title }`. Add one test that starts a session with `title: ""` and asserts the live summary title is the default name `claude-code`.

## Review Findings (2026-11-18 08:14)

> Scope: `review sha 40391155..dc87bbf7` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:372` `duplication/duplication` — The new error-log block in giveDefaultTitle copies the log block of recordedSummaries. Both call RouterTelemetry.makeLogger(.sessionDirectory).error and merge RouterTelemetry.errorMetadata(error) with the session id key. Only the message text differs. A later change to the log key or metadata shape must be made in both places, or they drift apart. Extract one private helper, for example logDefaultNameFailure(_ message: String, _ error: Error, session: any RoutedSession), that makes the logger and builds the metadata. Call it from giveDefaultTitle with the new message, and from recordedSummaries with its existing message. Keep the two messages as parameters.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:372` `reuse/reuse` — The new error log in `giveDefaultTitle` rebuilds the same logger call and metadata merge (`makeLogger(.sessionDirectory).error(...)`, `errorMetadata(error).merging([sessionId: ...])`) that already exists unchanged in `recordedSummaries`. This is a parallel copy of a near-match, not an extension of a shared helper, so the two copies can drift apart. Extract one private helper, for example `logSessionFailure(_ message: String, _ error: any Error, session: any RoutedSession)`, that holds the logger call and the metadata merge. Have `giveDefaultTitle` (line 372) and `recordedSummaries` (line 397) both call it with their own message.
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryDefaultNameTests.swift:283` `reuse/reuse` — The new test `aStartWithAnEmptyTitleGivesTheDefaultName` repeats the body of the existing `aStartWithNoTitleGivesTheDefaultName`. The only difference is `title: ""` in the request. A near-match was copied instead of being extended, so the fixture setup, the start call and the assertion now exist twice. Parameterize the existing test over the title (for example with a `arguments:` list of `nil` and `""`), or move the shared start-and-assert steps into a private helper that both tests call. Keep the production change that each case guards documented in the comment.
