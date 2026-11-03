---
comments:
- actor: claude-code
  id: 01m6gt45rctcvvfp24zqa2hk7n
  text: |-
    DESIGN (no code written yet).

    Add to `RouterSessionDirectory`:

        public nonisolated func session(id: ULID) -> (any RoutedSession)?

    It is the public form of the private `liveSession(_:)` (RouterSessionDirectory.swift:1463). It reads `state.withLock { $0.entries[id]?.session }`. `Entry.session` is `weak` (line 107), so the call does not keep a session alive. The directory is flat: every vended session has one entry, so depth 1, 2 and 3 use the same path. The private `liveSession` is renamed to this public method (one name, no duplicate).

    Why not a `started` event that carries the session: the event is Sendable data that a host can keep, and it would hold a strong reference.

    Why not a public event feed accessor: the host also needs `respond(elicitationId:response:)`, and `streamSessionEvents()` is already on `RoutedSession`. One object gives both.

    Rules:
    - A session that closed gives `nil` (`unregister` removes the entry on `close()`, RoutedSessionActorClosing.swift:129).
    - A host reads `started` from `events()` and then calls `session(id:)`. The session is registered before `started` goes out, so the call finds it, unless the session closed already.
    - No change to root-session behavior.

    Elicitation (verified): `askedBy` of `ElicitationRequest.relayed(by:askedBy:)` is a TOOL name, not a session id. So the host attaches its projector to the CHILD session from this accessor, reads the original `elicitationRequested` in the child feed (same `elicitationId`), and answers with `child.respond(elicitationId:response:)`. The test must show: the child run continues, and the relayed copy in the parent ends once. If a host answers at both levels, the first answer wins; the test records what happens.

    Tests (`SubagentSessionAccessTests`): depth 1, 2, 3 live lookup; `nil` after close; no retain (weak probe after the last strong reference is gone); child question answered through the child.
  timestamp: 2026-11-03T13:38:36.940889+00:00
- actor: claude-code
  id: 01m6gt7ff4172vb81cqm83d9rc
  text: 'REVIEW NOTE (coordinator, 2026-11-03): in the tests read "depth 1, 2, 3" as "a chain of three sessions, the same rule at every level". Add one test: a RESTORED session (not only a new one) is found by `session(id:)`.'
  timestamp: 2026-11-03T13:40:25.188927+00:00
- actor: claude-code
  id: 01m6gy1mydpgjvkewck0kz6ey3
  text: |-
    ### implement - changed
    - Added public `RouterSessionDirectory.session(id:)`. It replaces the private `liveSession(_:)`. All callers use the new name.
    - New tests: `SubagentSessionAccessTests` (9 tests): chain of three, unknown id, nil after close, no retain, restored session, child feed carries the original id, answer through the child, parent copy ends once, answer at both levels.
    - RED: the tests did not compile (`session(id:)` missing). GREEN: all 9 pass. Full `swift test`: 2238 tests in 274 suites passed, no warnings.
    - FINDING (current behavior, recorded in the tests): an answer through the child does NOT reach the parent copy. The parent copy stays open until the relay ends (the child closes). It then ends once, origin system, with cancel "run cancelled". Until then the user still sees an open question at the parent.
    - If the host answers at both levels (child first, then the parent copy): the parent takes the second answer (`.delivered`). The relay sends it down. The child has no question any more, so the run of the child keeps the first answer only.
    - UNDECIDED: should an answer in the child end the parent copy at once? That needs a relay change (new child event, or a settle of the parent copy when the child answer comes). Not done, because the card says only "ends once".
  timestamp: 2026-11-03T14:47:08.493642+00:00
- actor: claude-code
  id: 01m6h1zzns0w25ne7hp0z251sz
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD, 0 findings on this card
    - next: none, moved to done
  timestamp: 2026-11-03T15:56:08.249811+00:00
position_column: done
position_ordinal: ffffffffdb80
title: Give a host a public way to get the live session (or its event feed) of a sub-agent session
---
## What
A host such as FoundationModelsACPAgent must project a sub-agent session to its client as an ordinary session (ACP v2 "Subagent Sessions" RFD: each sub-agent is a child session with its own session id). To do that the host attaches a projector to the session: it reads `session.streamSessionEvents()` and it answers elicitations through the session. For a root session the host holds the `RoutedSession`. For a sub-agent session it cannot get it.

Today (checked in the code, 2026-11-03):
- `RouterSessionDirectory.liveSession(_:)` is private (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1463`), and `makeEventFeed(of:)` is private and static (line 1926). It works only for a `RoutedSessionActor`.
- The directory holds each session weakly (`Entry.session` is `weak`, line 107). So a public accessor that reads `entry.session` does not keep the session alive.
- `RouterSessionDirectory.events()` is public and gives `started(SessionSummary, requestedByClient:)` with `kind` (`.subagent`) and `parentID`, but not the session or its feed.
- `AgentRun` in FoundationModelsAgents has no public session (`sessionID` and `heldSession` are internal). The run event observer gives `(AgentRun, SessionOutput)`, so events can be read, but the host has no session object for the answer path.
- `registerVendedSession` (`RoutedLLM.swift:321`) registers each vended session with `kind` and `parentID` (`.subagent` when `subagentParentID` is set), so the directory already holds the live session of every sub-agent.

Add one public, narrow accessor. Chosen shape: `RouterSessionDirectory.session(id: ULID) -> (any RoutedSession)?`, a public wrapper of `liveSession(_:)`. It is `nonisolated` and uses the same lock. It gives only a live session, does not keep it alive (the entry is weak), and works for a nested sub-agent at any depth (the directory is flat: every session has an entry). Reason: the host can call `streamSessionEvents()` on the session, and it has the answer path (`respond(elicitationId:response:)`) on the same object. A `started` event that carries the session is worse: the event is `Sendable` data and would hold a strong reference. Race note: the host reads `started` and then calls `session(id:)`. The session is registered before `started` is sent, so the call finds it, unless the session closed already (then `nil`).

## Elicitation path (checked in the code, and the card text was wrong)
- `ElicitationRequest.relayed(by:askedBy:)` is in FoundationModelsExtras (`Elicitation.swift:109`). `askedBy` is a TOOL name (`event.tool` of the child run, `SubagentQuestionRelay.swift:285`). It is NOT a session id. The request has two public fields: `agentPath: [String]` (agent names, nearest the user first) and `source: String?` (the tool that asked). Neither names the child session id.
- So the relayed request in the parent feed does not identify the asking child session. Do not rely on it.
- Better path for the host: attach the projector to the CHILD session (through the new accessor). The child feed carries the original `elicitationRequested` with the same `elicitationId`, and the host knows the child session id there. The host asks the user under the child session id and answers with `child.respond(elicitationId:response:)`. The relay then settles the parent copy (same id) and ends it. Test this: answer through the child, and check that (a) the child run continues, (b) the parent copy ends once, with no double answer.
- Open question for the test: if the host answers at the parent (relayed copy) and at the child, the first answer wins. Document the result in the test.
- Optional addition (decide in the Router change): a public `askingSessionID: ULID?` on the relayed request. It needs a change in FoundationModelsExtras, so do it only if the child-feed path is not enough.

Consumer: FoundationModelsACPAgent board, tag `subagents`, task "Register a nested sub-agent as an ordinary ACP session with a parent link" (`n3hb9sv`) and the request attribution task (`my9mbdf`). Until this card is done the host feeds the projector from the run event observer with no session, and a child question reaches the user under the parent id.

## Acceptance Criteria
- [ ] A host can get the live `RoutedSession` of a started sub-agent session by its id (`RouterSessionDirectory.session(id:)`), for a chain of nested sessions, with the same rule at every level.
- [ ] The accessor gives `nil` after the session closed, and it does not keep the session alive.
- [ ] A host that reads the feed of the child session sees the question of the child with the original `elicitationId`.
- [ ] An answer through the child session reaches the child run, and the relayed copy in the parent ends once.
- [ ] No change to the existing root-session behavior.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/SubagentSessionAccessTests.swift`: live accessor for a chain of three sessions, `nil` after close, no retain.
- [ ] A test of the child question: read it in the child feed, answer through the child, check the child run and the parent copy.
- [ ] Run `swift test --filter SubagentSessionAccessTests`. All pass. (The filter must match a real suite name: a wrong filter exits 0 with no tests.)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents