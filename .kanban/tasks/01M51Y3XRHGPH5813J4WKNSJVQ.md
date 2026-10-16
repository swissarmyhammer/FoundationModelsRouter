---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51y75k1bt3mxatrra8n44rw
  text: |-
    ### Step lead decisions (2026-10-16)
    - The step lead accepts the design.
    - (a) Extras does E1 and E2 first. Start the Router code only after Extras reports E1 and E2 pushed and green.
    - (b) Change: a relaying level keeps the relayed question in its journal (for the order rules) and in its event feed. It does NOT put the question in the prompt text of its model, because a relayed answer makes no mail at that level. Only the level that asked sees the question and the answer in its prompt. Add a test for this.
    - (c) Accept the race of a root answer and a child end. Document it in the doc of SubagentQuestionRelay. Keep the test that each level has one outcome.
    - (d) The target holds a strong reference to the parent. Document this on SubagentQuestionTarget. Agents drops the target after drive (part of Agents 45).
    - (e) A child that is not a Router session gets no elicitationEnded when the parent ends its question. Document this as a limit.
    - (f) Open questions are not recovered after a restart. This is outside the plan.
    - (g) The step lead gives the ACPAgent card (send agentPath and source to the client) to ACPAgent after the Router push.
    - Conformers that the new openElicitationIds() requirement breaks: only FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/Support/CloseCountingRoutedSession.swift:26. It needs one forward in the same push window. Do not add a default implementation in a protocol extension.
  timestamp: 2026-10-16T08:45:51.073184+00:00
- actor: claude-code
  id: 01m520gzkjbgbpv4frymv8js62
  text: |-
    ### implement — research
    - Extras checkout is at 11b7c7e: ElicitationRequest.agentPath, .source, relayed(by:askedBy:) and RunPlane.endElicitation(_:with:) are there. ToolContext.holdingRunToken and ToolContext.runPlane are internal to Extras, so the relay keys its work flag on ToolContext.completionToken (the token of the background run R) and reaches the run plane of the parent through the RoutedSessionActor of the target.
    - Decision (b) in code: the outbox makes no run mail for an elicitation event whose request has a non-empty agentPath. The journal still records the event and the feed still gets elicitationRequested. Its origin is then the origin of the poster: the relay posts under Origin.system. respond(elicitationId:response:) posts no elicitationAnswer mail for a relayed question (AskedQuestions relayed flag from agentPath).
    - The relay waits after each relayed question until the parent journal recorded it, or until its task T_q ended. I do not end this wait at the close of the parent: the journal records the question also after close, and an end of the wait before the question is open in the run plane can leave the question open forever (the end of the child feed then finds no question, and the drain of the parent waits for the run body that waits for finish()). This is the only change from section 1 step 5.
    - RunPlane.awaitAnswer does not check that the run is open, so the order "recorded first" is what lets endElicitation always find the question.
    - Test fixture plan: one background tool "subagent_job" whose role comes from a box keyed by the session id (relay, or ask). BackgroundingBackend calls each fixture tool on the first call of each session, also of a fork. The test reads child feeds that the box opens before the first mail of the child. holdLaterAnswers makes the "no mail at a relaying level" check deterministic.
  timestamp: 2026-10-16T09:26:09.778888+00:00
- actor: claude-code
  id: 01m5223rq83v3gkznjwch3gw12
  text: |-
    ### implement — changed
    - evidence:
      - New: Sources/FoundationModelsRouter/Session/SubagentQuestionRelay.swift (SubagentQuestionHost task-local, public SubagentQuestionTarget, public SubagentQuestionRelay, internal SubagentQuestionLink), Sources/FoundationModelsRouter/Session/RoutedSessionActorRelayedQuestions.swift (RelayedQuestions table, ElicitationRequest.isRelayed, actor side of the relay, feedWithWorkPhase()), Tests/FoundationModelsRouterTests/SubagentQuestionRelayTests.swift (SubagentQuestionRelayTests 15 tests, RelayedQuestionsTableTests 6 tests), Tests/FoundationModelsRouterTests/Helpers/SubagentRelayFixtures.swift.
      - Changed: RoutedSession.swift (requirement openElicitationIds(), docs of awaitIdle() and respond), RoutedSessionActor.swift (relayedQuestions, relayChildren, relayChanges, openElicitationIds()), RoutedSessionActorAnswerExecution.swift (binds SubagentQuestionHost.session next to SessionOwnWork), RoutedSessionActorQueueing.swift (no answer mail for a relayed question, URL accept goes down at once), RoutedSessionActorRunJournal.swift (endedHere mark before the run resumes), RoutedSessionActorWorkEvents.swift (AskedQuestions relayed flag, recorded signal), RoutedSessionActorIdle.swift (child work rule), SessionOutbox.swift (no run mail for a relayed question), SessionEvent.swift (docs), RouterTelemetry.swift (log category SubagentQuestionRelay), FoundationModelsRouter.docc/RoutedSession.md, generation-queue.md (section 5.4).
      - Red first: all new tests failed to compile (no SubagentQuestionTarget, SubagentQuestionRelay, RelayedQuestions, openElicitationIds). Behavior red with the relay up path in place and the three rules not yet in place: aRelayingLevelKeepsTheQuestionOutOfThePromptOfItsModel failed (origin .mail([m]) and an elicitation run mail waited at the root), aRootAnswerReachesTheRunThatAskedAndMailsOnlyThatLevel failed (the root and the middle level each held answer mail, depth total 3), aParentIsNotIdleWhileItsChildWorksWithAnOpenQuestion failed (the suite reported its fifth issue: isIdle() true while the child worked). Then green: 21 tests in 2 suites passed.
      - Full run, one time: swift test → 1791 tests in 217 suites passed (1 known issue, the existing RealModelHarness withKnownIssue), 26 tests in 14 suites passed, 19 tests in 3 suites passed. Only warning: the known mlx-swift_Cmlx bundle line.
      - IntegrationTests: swift build --build-tests --manifest-cache local → Build complete, 0 warnings.
    - Decisions inside the design (for review):
      - (b) is done in the outbox: an elicitation event whose request has a non-empty agentPath makes no run mail. The journal and the feed still get it. Its origin at a relaying level is Origin.system (the relay posts under .system), not .mail([m]); test 1 and the (b) test check this.
      - Section 1 step 5: the relay waits until the parent recorded the question or the task of the question settled. It does not stop the wait at the close of the parent, because the journal records the question also after close, and a stop before the question is open in the run plane can leave it open forever (finish() then waits for a task that nobody answers).
      - The relay keys the work flag on ToolContext.completionToken of the target (ToolContext.holdingRunToken is internal to Extras). For a background run R this is the token of R.
      - Test 3 checks "only the asking level gets answer mail" with holdLaterAnswers and mailQueueDepth (no elicitationAnswer kind, nothing running at the root and the middle level) plus the answer text in the leaf prompt, in place of the mailDelivered sender check.
      - The headless test makes the child an interactive root session from the parent profile, because a fork keeps the headless presence of its parent.
      - ToolContext.elicit throws no error now; the relay still handles a throw with assertionFailure, an error log (new log category SubagentQuestionRelay) and the cancel of a stopped run.
    - For the step lead (API changes): new public SubagentQuestionTarget, SubagentQuestionRelay; new RoutedSession requirement openElicitationIds() with no default implementation (ACPAgent CloseCountingRoutedSession needs its forward); no new SessionEvent case or field; changes of meaning as the design lists (relayed elicitationRequested with origin .system and no run mail, same id at each level, no answer mail at a relaying level, .system origin for an end that came up).
    - next: review
  timestamp: 2026-10-16T09:53:53.896644+00:00
position_column: doing
position_ordinal: '80'
title: 'Elicitation phase 4: subagent questions (design for Router tasks 12, 13, 14)'
---
Design only. This card holds the design of phase 4 of `/Users/wballard/github/swissarmyhammer/elicitation-plan.md` (Router tasks 12, 13, 14; Agents tasks 45, 46). The step lead splits the checklist at the end into implementation cards. File references use `file:line` of Router head `fd148614`, Extras head `2935533` and Agents head `bf9bbe9`.

## What

### 0. Facts in the code that set the design

- A child session is a full, separate session. A fork gets a new outbox and a new run plane, and keeps only the user presence of the parent (`Session/RoutedSessionActorForking.swift:116-124`). An `AgentRun` child is a new root session from `model.makeSession` (Agents `Run/AgentSessionMaker.swift:64-75`). Thus no event of a child gets to the parent today.
- The parent end of the link is a background run R of the parent: the `start agent` call body waits for the child (Agents `Tool/AgentsToolContext.swift:196-204`, `Tool/AgentsToolOperations.swift:111-129`). `AgentRun.drive` runs detached (Agents `Run/AgentRun.swift:704-717`), so it has no task-local of R. It keeps only `ToolContext` R (`AgentRun.swift:162`, `:290`).
- Today `AgentRun` answers each question of its session with a cancel (Agents `Run/AgentRun+Drive.swift:314-316`, `:347-354`), and each run session is headless (Agents `Run/AgentEnvironment.swift:188-197`).
- `ToolContext.elicit` is the only public way to open a question (Extras `Hosting/ToolContext.swift:345-357`). `RunPlane.awaitAnswer` is internal (Extras `Hosting/RunPlaneActor.swift:484-505`). No public call ends one question: only a run cancel, `cancelOpenElicitations()` and `sweep()` end questions, always with `runCancelledReason` (`RunPlaneActor.swift:433-447`, `:595-598`, `:704-717`, `:1010-1021`).
- `ElicitationRequest` has no field for the agent path or the source (Extras `OperationEvents/Elicitation.swift:22-36`).
- The order rules of an end are at `Session/SessionEvent.swift:401-418`. The run plane posts the end before the run resumes, and the journal records it (`Session/RoutedSessionActorRunJournal.swift:141-146`). `AskedQuestions.end` lets one end event go out for each question (`Session/RoutedSessionActorWorkEvents.swift:176-178`).
- Router binds `ToolContext.current` and `SessionOwnWork` around each model call, and each tool body and each run body gets them (`Session/RoutedSessionActorAnswerExecution.swift:918-945`, `Session/SessionOwnWork.swift:4-24`).

### Separate ask: one Extras card (must land first)

The design needs two small, additive Extras changes. Router cannot do them correctly alone.

- **E1: agent path and source on the request.** In `OperationEvents/Elicitation.swift` add to `ElicitationRequest`:
  - `public let agentPath: [String]` (default `[]`): the agents that relayed the question, from the agent nearest the user to the agent that asked. Empty for a question that a run of this session asked.
  - `public let source: String?` (default `nil`): the tool of the run that asked the question at the level where it was asked (the runCode tool or the MCP server name).
  - `public func relayed(by agent: String, askedBy tool: String) -> ElicitationRequest`: the same `elicitationId`, `agentPath = [agent] + agentPath`, `source = source ?? tool`.
  - Codable: encode the two keys only when they are not empty; a missing key decodes as `[]` or `nil`, so old transcripts decode.
- **E2: end one question.** In `Hosting/RunPlaneActor.swift` add `public func endElicitation(_ elicitationId: ULID, with response: ElicitationResponse) async -> Bool`. It is `cancelQuestions(where:)` for one id, with `response` in place of the fixed `runCancelledReason` cancel: the question leaves `openElicitations()` and goes into `endingElicitations()` in one step, the sink gets `post(elicitationEnded:response:)` after the question post, and the run resumes with `response` only after that post returned. It returns `false` when the question is not open (an answer, a completion or another end came first). An accept in `response` is a programmer error (`precondition`).
- Extras tests (fixed order): a round trip of a request with a path and a source; a decode of a request with no new keys; `endElicitation` ends a form question and an accepted URL question with the given reason, and the run gets the response after the end post; `endElicitation` after `respond` gives `false` and posts no end; `endElicitation` while a completion post is on its way gives `false`.
- No other Extras change. No new `OperationEventSink` method.

### 1. A question goes up, level by level

Router task 12. The same steps run at each level. C is the child, P is the parent, R is the run of P that drives C.

1. A run of C asks question q through `ToolContext.elicit`. C sends `elicitationRequested(e_C)` on its feed, with origin `.mail([m_C])` (`SessionEvent.swift:283-312`).
2. The owner of C started a `SubagentQuestionRelay` before the first mail of C. It took the target inside R with `SubagentQuestionTarget.current`. The relay reads the feed of C in order.
3. For `elicitationRequested(e_C)`, the relay makes `q_P = q.relayed(by: agentName, askedBy: e_C.tool)`. Then it puts q.id in the relay table of P (section 4), and starts task T_q. T_q calls `ToolContext.elicit(q_P)` on the `ToolContext` of R, with `OriginContext` `.system`.
4. The run plane of P links q_P to R. The outbox of P journals the event. P sends `elicitationRequested(e_P)`: its `tool`, `op` and `correlationID` are those of R, and its origin is `.mail([m_P])` with a run mail of P. `AskedQuestions` of P records q as relayed (`agentPath` is not empty). The run mail of the question starts no answer (`RoutedSessionActorWorkEvents.swift:382-397`), so the parent model sees the question in its next answer only.
5. The relay waits, with no clock, until P recorded q, or T_q ended, or P started its close. Only then does it read the next event of C. Thus an end of q in C always finds q_P open in the run plane of P, or already ended.
6. When P is a child too, the relay of P (started by the owner of P) reads the feed of P and does the same steps. Each level adds its own agent name in front of the path. At the root, ACPAgent shows `root › ` and the path joined with ` › `, for example `root › reviewer › linter`, and the source.

For a Router fork, the owner is the tool that made the fork. For an `AgentRun` child, the owner is `AgentRun.drive` of the child, with the target that `StartAgent.execute` took in R.

### 2. The answer goes down; an end with no answer ends each level one time

Router task 13.

**Answer.** The client answers at the root with the one id. At a level where q is relayed:

- `respond(elicitationId:response:)` (`Session/RoutedSessionActorQueueing.swift:169-183`) gives the answer to the run plane of that level, as today. When q is relayed, the level posts **no** `elicitationAnswer` mail (`:178-180`). Only the level whose own run asked q posts the mail, so only that model sees the answer, and only that mail-only count goes to zero.
- A form answer, and a decline or cancel of a URL question, resume T_q. T_q calls `child.respond(elicitationId:response:)` with the answer that `elicit` gave (it is already checked against the schema). That call does the same at the next level, until the run that asked gets the answer.
- A URL accept gives `.acceptedAwaitingCompletion` and does not resume T_q. So `respond` at a relayed level sends the accept down at once: after the run plane of the level accepted, it calls `child.respond` with the accept. The parent accepts first, so a completion from below always finds the parent question accepted.
- A completion from below: the tool that asked calls `ToolContext.complete` in the leaf. Each level sends `elicitationCompleted` on its feed. The relay of each level sees it and calls `complete(elicitationId:)` on the `ToolContext` of R. T_q then gets the accept and calls `child.complete`, which gives `.noPendingElicitation` and does nothing.
- A completion at the root (`complete(elicitationId:)`) resumes T_q with the accept. T_q calls `child.complete` with the same id, level by level.

**End with no answer, at the level where it starts:**

| Start of the end | That level | Levels above | Levels below |
|---|---|---|---|
| Run cancel in C (`ToolContext.cancel`) | Run plane of C: one `elicitationEnded`, origin of the cancelling work, before the `runSettled` of the run (`SessionEvent.swift:410-413`) | The relay sees it and calls `endElicitation(q, with: same response)` on the run plane of P: one `elicitationEnded` at P, origin `.system`. Each level above does the same. | none |
| `cancelAll()` at P | `cancelOpenElicitations()` ends q_P: one end, origin `.signal(s)`, before `signalDone(s)` (`Session/RoutedSessionActorDrain.swift:72-81`) | as above, origin `.system` | T_q resumes. The journal of P marked the entry "ended at this level", so T_q calls `endElicitation(q, with: same response)` on the run plane of C: one end at C, origin `.system`. The cancel of R also cancels the child (Agents), and that end then finds no question. |
| `close()` at P (also a close from the own work of P, which is detached: `RoutedSessionActorForking.swift:373-387`) | one end, origin `.system`, before the feed of P ends (`:431-438`) | as above | as for `cancelAll()` |
| Cancel of run R at P | the run plane ends q_P with the origin of the cancelling work, before the `runSettled` of R (`RunPlaneActor.swift:400-447`) | as above | as for `cancelAll()` |
| Close of C | one end at C, origin `.system`, before the feed of C ends | as above | none |

**Rules that make "exactly one, none left open":**

- In each run plane, the one-step take-off of `respond`, `complete`, the cancel paths and E2 lets exactly one outcome win. `AskedQuestions.end` sends at most one event.
- A relay never sends a question up after it saw its end, because it reads the feed of the child in order (step 5).
- When the feed of C ends, the relay calls `endElicitation(q, with: .cancel(reason: RunPlane.runCancelledReason))` at P for each entry that is still open. Then each T_q ends.
- `finish()` returns only after the feed of C ended and each T_q ended. The owner calls it in the body of R, after it closed C. So each end at P comes before the `runSettled` of R, and before the feed of P ends.

**Order against `runSettled` and the feed end, at each level:** a run cancel gives the end before the `runSettled` of the run that asked; `cancelAll()` gives it before `signalDone`; close gives it before the feed end. These are the rules of `SessionEvent.swift:401-418`, unchanged, because each level uses its own run plane and journal. The only new origin: an end that comes up from a child has the origin `.system` at the parent.

**A known race:** an answer at the root and an end in the child can cross. Then the root gives `.delivered`, and the child sends `elicitationEnded`. Each level still has one outcome.

### 3. Task 14: "waiting only for external input" up through the levels

- **Definition.** A session waits only for external input when it has no work (the rule of `awaitIdle()`, `Session/RoutedSession.swift:583-624`) and it has one or more open questions (`openElicitationIds()` is not empty).
- **New rule in `isIdle(startedAt:reading:)`** (`Session/RoutedSessionActorIdle.swift:182-188`). An open run is no work when it has a recorded open question (today), **and** no relay that sends to that run has a child that works. The flag comes from the work events of the child, read by the relay: `workStarted` sets it, `workEnded` clears it. At the start, the relay reads the work phase of a Router child (`workEvents`, `Session/RoutedSessionActor.swift:468`) in the same actor step as the subscription. A child that is not a Router session counts as working until its first `workEnded`.
- **Work events of the parent.** When the child flag goes to "works", the relay calls `noteWorkStarted()` of P (`RoutedSessionActorWorkEvents.swift:307-314`). When it goes to "no work", and when the relay ends, the relay calls `workDidChange()` of P (`:319-322`). Thus P sends `workEnded` after the `elicitationRequested` of the relayed question and after the child went idle, and `workStarted` when the child works again.
- **Through the levels.** The child C waits only for the user, so R is no work at P. When P has no other work, P is idle and sends `workEnded`. The relay of P then marks P as "no work" at its own parent, and so on to the root. ACPAgent reports `idle`.
- **An answer.** `respond` at the root notes the start of work before the run plane resumes T_q (`noteWorkStart(answering:with:)`, `RoutedSessionActorWorkEvents.swift:358-363`). Each level below does the same when T_q calls `child.respond`. The leaf model then answers.
- **A relaying run that has other work** while its child waits only for the user counts as no work. This is the same limit as `RunPlane.runsWaitingOnlyForUser()` (`RunPlaneActor.swift:324-341`).
- **Mail-only count and pause** (`Session/RoutedSessionActorPump.swift:166-170`, `:326-334`, `:354-364`):
  - A relayed question gives run mail at each level. It starts no answer, so it does not count.
  - A relayed answer gives no mail at the relaying levels, so their counts and their pauses do not change. The answer is user-type mail at the level that asked only: there it sets the count to zero and carries the held mail, so it ends a pause at that level.
  - Held mail counts as idle (`RoutedSessionActorIdle.swift:62-67`). Thus a paused level whose children wait only for the user is idle, and its parent can be idle.
  - A paused `AgentRun` waits until each child ended (Agents `1c23d8b`). A child that waits for the user keeps that run waiting until the user answers, or until a cancel or a close. There is no time limit (plan, section 2).
- **Agents end rule.** `AgentRun` must not end while `openElicitationIds()` of its own session is not empty, because its close cancels the question. A relayed question from a grandchild already keeps the run alive, because the child is `.running`.

### 4. Ids, the table, and when entries go

- **Elicitation id:** one ULID for the whole chain, the id that the run that asked gave. Each level registers the same id in its own run plane. The duplicate guard is per run plane (`RunPlaneActor.swift:494-496`), and ULIDs do not collide. The root client answers with that id, and each relay forwards it unchanged. Thus no id map is necessary.
- **Run token:** at each level the question links to R of that level, so `correlationID` of `e_P` is the token of R. The UI links the card to the tool call of R (for example the `start agent` call).
- **MailID:** each level journals its own copy, so each level has its own run mail and its own `MailID`. The origin of `elicitationRequested` at a level is `.mail([MailID of that level])`. A `MailID` never crosses a level.
- **Table:** in the `RoutedSessionActor` of P (new file `Session/RoutedSessionActorRelayedQuestions.swift`, stored state in `Session/RoutedSessionActor.swift` next to `askedQuestions` at `:473`):
  - `relayedQuestions: [ULID: RelayedQuestion]` with the relay id, the child, the token of R, and the state `open`, `endedHere(ElicitationResponse)`, `endedBelow` or `completedBelow`.
  - `relayWork: [RelayID: (runToken: String, childWorks: Bool)]`.
  - `AskedQuestions` gets a `relayed` flag for each question.
- **Removal:**
  - A question entry goes when T_q settled: after it forwarded the answer, or ended the child copy.
  - A relay entry goes when the relay read the end of the feed of the child.
  - The `relayed` flag goes with the question, by the rules of today (`RoutedSessionActorWorkEvents.swift:78-85`).
  - All are bounded by the count of questions and relays.

### 5. Public API for Agents tasks 45 and 46

New file `Sources/FoundationModelsRouter/Session/SubagentQuestionRelay.swift`:

```swift
/// The run of a Router session that drives a subagent: the place where a
/// relay sends the questions of the subagent.
public struct SubagentQuestionTarget: Sendable {
    /// The target of the tool call or the run body of the calling task, or
    /// `nil` when the task is no tool work of a Router session.
    public static var current: SubagentQuestionTarget? { get }
    /// The user presence of the session of the target. Give it to the
    /// session of the subagent (`SessionConfiguration.userPresence`).
    public var userPresence: UserPresence { get }
    /// The id of the session of the target.
    public var sessionID: ULID { get }
}

/// Sends the questions of one subagent session to its parent, one level up,
/// and sends the answers back down.
public final class SubagentQuestionRelay: Sendable {
    /// Subscribes to the events of `child` before it returns. Call it
    /// before the first mail of `child`, while the run of `target` is open.
    public static func start(
        child: any RoutedSession, agentName: String, target: SubagentQuestionTarget
    ) async -> SubagentQuestionRelay
    /// Waits until the relay read the feed of `child` to its end, and each
    /// question that it sent up ended. Close `child` first. A cancel of the
    /// calling task does not end the wait.
    public func finish() async
}
```

New requirement on `RoutedSession` (`Session/RoutedSession.swift`, after `complete(elicitationId:)` at `:761`):

```swift
/// The ids of the questions of this session that are open now: their
/// `elicitationRequested` went out, and no answer that resumed the run, no
/// completion and no end came yet. A relayed question counts.
func openElicitationIds() async -> [String]
```

Internal only: a task-local with the `RoutedSessionActor` of the call, bound in `submission(of:...)` next to `SessionOwnWork.run` (`RoutedSessionActorAnswerExecution.swift:934-937`). `SubagentQuestionTarget.current` reads it together with `ToolContext.current`.

**What Agents 45 and 46 do with it, with no further Router change:**

1. `StartAgent.execute` stores `SubagentQuestionTarget.current` in `AgentRunRequest`, next to `context` (`Tool/AgentsToolOperations.swift:111-116`).
2. `AgentSessionMaker.makeSession` sets `userPresence: request.questionTarget?.userPresence ?? .headless` (`Run/AgentSessionMaker.swift:75`).
3. `AgentRun.drive` starts the relay before `mailTaskPrompt`, with `agentName: definition.id`. After `session.close()` and `await following`, it calls `await relay.finish()` (`Run/AgentRun+Drive.swift:77-88`). Then it drops the target.
4. `follow` calls `answerQuestion` only when the run has no target (`AgentRun+Drive.swift:314-316`).
5. `acceptedMessagesIfIdle` and `endStateIfDrained` also require `await session.openElicitationIds()` to be empty. `elicitationEnded` and `elicitationCompleted` are added to the events that give an idle check (`AgentRun+Drive.swift:381-402`).

Task 46 needs no own code: the Router relay sends the answers down. Agents 46 is the tests of the answer path through `AgentRun`.

**Public `SessionEvent`:** no new case and no new field. Tell the step lead of these changes of meaning:

- `elicitationRequested` also carries relayed questions. Their `tool`, `op` and `correlationID` are those of the relaying run. `elicitation.agentPath` and `elicitation.source` are the new Extras fields.
- The same `elicitationId` is used at each level.
- `respond` of a relayed question posts no `elicitationAnswer` mail at that level.
- An end that comes up from a child has the origin `.system`.
- The new protocol requirement `openElicitationIds()` breaks each conformer outside Router: ACPAgent `Tests/FoundationModelsACPAgentTests/Support/CloseCountingRoutedSession.swift` must add a forward.

**Follow-up outside Router (not in this card):** ACPAgent sends `agentPath` and `source` to the client in `_meta` of `elicitation/create`, for AgentViewKit task 39.

### Relation to ^hrkxav5 (nested close)

The relay never calls `close()`. It never waits for an answer of a child: `child.respond` only posts mail. Thus phase 4 makes no new deadlock and does not fix ^hrkxav5. `finish()` adds one wait in the body of R, and the close of the child bounds it. So the owner must close the child when R is cancelled. `AgentRun` does this: a cancel of R cancels the child run, and its `drive` closes the child (`Run/AgentRun+Children.swift:128-139`, `AgentRun+Drive.swift:77-88`). The case "a tool of the child closes the parent" stays a deadlock, as `RoutedSession.swift:677-684` tells. The phase 4 tests must not use it. ^hrkxav5 stays a separate card.

### Files to change (Router)

- New: `Sources/FoundationModelsRouter/Session/SubagentQuestionRelay.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorRelayedQuestions.swift`.
- Change: `Session/RoutedSessionActor.swift` (state, `openElicitationIds()`), `Session/RoutedSessionActorAnswerExecution.swift` (task-local), `Session/RoutedSessionActorQueueing.swift` (no mail for relayed, URL accept down), `Session/RoutedSessionActorRunJournal.swift` (mark `endedHere` in `record(elicitationEnded:)`), `Session/RoutedSessionActorWorkEvents.swift` (`relayed` flag), `Session/RoutedSessionActorIdle.swift` (rule), `Session/RoutedSession.swift` and `Session/SessionEvent.swift` (docs), `FoundationModelsRouter.docc/RoutedSession.md` (the new types).
- `Package.resolved`: adopt the Extras head with E1 and E2. Stop the sourcekit-lsp of the repo, and use `--manifest-cache local` before `swift package update`.

### Risks and open points

- Extras E1 and E2 must land first.
- The answer and child-end race (section 2): the client sees `.delivered`.
- A target keeps a strong reference to the parent actor. Agents must drop it after `drive`, because a retained `AgentRun` can live after its parent closed.
- The parent model sees each relayed question as run mail (tokens, possible confusion). The decision is to keep it, so that the journal and the order rules stay the same at each level. A later card can stop it.
- The work state of a parent follows the events of its child. The order between two feeds is not defined, so a parent `workEnded` can come after the `workEnded` of the child.
- A child that is not a Router session: its copy of a question that the parent ended gets `respond` with the cancel, not E2. Thus that child sends no `elicitationEnded`.
- An interactive child under a headless target: `elicit` at the parent gives a cancel at once, and the relay answers the child with that cancel. Agents prevents this with step 2 of section 5.
- Open questions are not recovered after a restart (not in the plan).
- A relay started after R settled links its questions to a closed run. The contract of `start` forbids it.

## Acceptance Criteria

- [x] A question of a fork child, and of a child two levels down, shows on the root feed one time, with the same `elicitationId`, `agentPath` `["reviewer"]` and `["reviewer", "linter"]`, `source` of the asking tool, and `correlationID` of the relaying run.
- [x] A form answer at the root reaches the run that asked. Only that level gets `elicitationAnswer` mail. No level sends `elicitationEnded`.
- [x] A URL accept at the root reaches the leaf at once. A completion in the leaf gives exactly one `elicitationCompleted` at each level.
- [x] Each end with no answer (run cancel at each level, `cancelAll()` and `close()` at each level, close of the child) gives exactly one `elicitationEnded` at each level, with the origin and the place of `SessionEvent.swift:407-418`, and `.system` for an end that came up. After it, `respond` and `complete` with the id give `.noPendingElicitation` at each level.
- [x] A parent sends `workEnded` and `awaitIdle()` returns `true` while its child waits only for the user. It is not idle while the child works with an open question.
- [x] `openElicitationIds()` lists direct and relayed open questions, and is empty after each end.
- [x] No test uses a time limit, a sleep, a poll or a retry. The full suite runs one time and is green.

## Tests

All in new `Tests/FoundationModelsRouterTests/SubagentQuestionRelayTests.swift`, with fixtures in new `Tests/FoundationModelsRouterTests/Helpers/SubagentRelayFixtures.swift`. Build on `BackgroundingSessionFixture`, `SessionWorkEventTests.AskingTool` (its `askGate` and `returnGate`), `RunLatch`, `SessionWorkEventTests.outputs(...)` and `PendingElicitationFixtures.soleEnd`.

**Setup:** parent P, interactive, with a background `RelayingTool`. Its body reads `SubagentQuestionTarget.current`, forks P (the session comes from a test box), starts the relay with `agentName: "reviewer"`, and mails `ask` to the fork. Then it waits on a gate, closes the fork, calls `finish()`, and returns. On a cancel of its task it closes the fork. The tool acts by `ToolContext.current.sessionID`: it relays in P, asks with `AskingTool` in the leaf, and does nothing at other levels. For two levels, the fork relays again with `"linter"`. The tests read the order of the outputs, not a clock.

Each test is written first and is red: the API does not exist. "Red because" names the production mistake that each test catches.

- [x] `aChildQuestionGoesUpOneTimeWithThePathAndTheSameId`: read the P feed to `elicitationRequested`. Expect one event, same id as the leaf, `agentPath == ["reviewer"]`, `source == "asking_job"`, `correlationID` = token of R, origin `.mail([m])` with `m` not a mail of the child. Then `workEnded` on P. Red because: no relay, or a new id at each level.
- [x] `aGrandchildQuestionGetsEachLevelInThePath`: the root sees `["reviewer", "linter"]`, the middle feed sees `["linter"]`.
- [x] `aRootAnswerReachesTheRunThatAskedAndMailsOnlyThatLevel`: `respond(accept)` at P gives `.delivered`. The leaf run returns `answered: accept`. The leaf feed has `mailDelivered` of mail with sender `.elicitation(id)`. P and the middle level have no such mail. No `elicitationEnded` at any level. Red because: answer mail at each level.
- [x] `aURLAcceptGoesDownAtOnceAndTheLeafCompletionComesUp`: `respond(accept)` at P gives `.acceptedAwaitingCompletion`. The leaf tool completes after a gate. Exactly one `elicitationCompleted` on each feed. The leaf run resumes with the accept.
- [x] `aRunCancelInTheChildEndsTheQuestionOneTimeAtEachLevel`: cancel the asking run in the child under origin X. Child: one end, origin X, before its `runSettled`. P: one end, same response, origin `.system`. No `runSettled` of R yet.
- [x] `cancelAllOfTheParentEndsEachLevelOneTime`: `s = P.cancelAll()`. P: end with `.signal(s)` before `signalDone(s)`. Child: exactly one end. P: `runSettled` of R after the end.
- [x] `closeOfTheParentEndsEachLevelBeforeEachFeedEnds`: `P.close()` returns. P: end with `.system` before the feed end. Child: exactly one end before its feed end.
- [x] `aCancelOfTheRelayingRunEndsTheParentQuestionBeforeItsRunSettled`: cancel R under origin Y. P: end with origin Y before `runSettled` of R. Child: exactly one end.
- [x] `closeOfTheChildEndsTheParentCopyBeforeTheRunSettled`: open the gate of R, which closes the child. Child end before the child feed end. P end with `.system` before `runSettled` of R.
- [x] `aParentIsIdleWhileItsChildWaitsOnlyForTheUser`: P feed order: `elicitationRequested`, then `workEnded`. `P.awaitIdle()` gives `true`.
- [x] `aParentIsNotIdleWhileItsChildWorksWithAnOpenQuestion`: the child also has a latched second run. Read P to `elicitationRequested`, and expect `isIdle()` of P to be `false`. Open the latch. Then P sends `workEnded`. Red because: "an open question means no work" with no child flag.
- [x] `aRootAnswerStartsTheWorkOfEachLevel`: from the idle state, `respond` at P. P sends `workStarted` before each later P output. The child sends `workStarted`.
- [x] `aHeadlessTargetGivesTheChildQuestionACancelAtOnce`: target headless. No `elicitationRequested` on P. The leaf run gets cancel with `RunPlane.noUserPresentReason`.
- [x] `openElicitationIdsListsDirectAndRelayedQuestions`: one direct question in P and one relayed question. Both are listed, and none after the ends.
- [x] Unit suite `RelayedQuestionsTableTests` (same file): an entry with state `endedHere` makes T_q end the child copy; `endedBelow` and `completedBelow` make it do nothing; the end of the feed ends each open entry.
- [x] Run `swift test` one time (no `--filter` by display name), and read the output for 0 failures and 0 warnings.

## Workflow

- Use `/tdd`: write the failing tests first, then implement to make them pass.
- Order: the Extras card (E1, E2) → Router adopts the Extras head → the checklist below → Agents 45/46 → the ACPAgent wire card.

## Checklist (the step lead splits these into cards)

- [x] Extras card: E1 and E2 with their tests. Router adopts the new Extras head.
- [x] Router: task-local, `SubagentQuestionTarget`, `SubagentQuestionRelay` up path (section 1, ids of section 4). Tests 1, 2 and the headless test.
- [x] Router: answers down (section 2, answer part): no mail for relayed answers, URL accept down, completions up and down. Tests 3 and 4.
- [x] Router: ends at each level (section 2, end part): `endedHere` mark, T_q settle, end of the feed, `finish()`. Tests 5 to 9 and the table unit suite.
- [x] Router: task 14 (section 3) and `openElicitationIds()`: relay work flags, the idle rule, the work events. Tests 10 to 12 and 14. Docs in `SessionEvent.swift`, `RoutedSession.swift` and `RoutedSession.md`. Tell the step lead of the API changes.
#elicitation-phase-4