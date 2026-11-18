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
position_column: doing
position_ordinal: '80'
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