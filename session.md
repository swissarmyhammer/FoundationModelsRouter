# Session directory: the Router part of the session plan

Status: plan. It changes no code. Status of each change: agreed.

Language: ASD-STE100 Simplified Technical English.

## 1. Purpose

This plan holds only the Router part of the session directory. Use it to make the kanban tasks of FoundationModelsRouter.

The session directory lets a model and a UI find, start, tag, message and archive sessions. The model uses the `sessions` tool of FoundationModelsMultitool. The UIs use the `sessions` GraphQL endpoint. Both call one directory, and the Router owns it (D23).

The whole design is in `../FoundationModelsMultitool/session.md`: the tool, the risk check, the graph schema and its resolver rules, the launcher in ACPAgent, the tab rule, and the tests of the other packages. This plan refers to the sections of that file as "plan section N". The design documents are in `../TestudoApp/features/` (the decisions are in `decisions.md`, the Router changes are in `packages/foundationmodels-router.md`).

## 2. What Router has today

- **The `Router` actor** (`Sources/FoundationModelsRouter/Router.swift:36`). Its public surface is `init`, `resolve` and `useLogger` (`Router.swift:120-219`). It holds no list of live sessions.
- **How a session starts.** `RoutedLLM.makeSession(configuration:)` (`Sources/FoundationModelsRouter/RoutedLLM.swift:101`) vends a new session. `fork(workingDirectory:)` (`Session/RoutedSessionActorForking.swift:22`) vends a fork. `restoreSession` (`Recording/SessionRestoration.swift:145`) and `restoreSessionTree` (`Recording/SessionTreeRestoration.swift:223`) vend restored sessions. These are the points where a session must register in the directory.
- **The session configuration.** `SessionConfiguration` (`Session/SessionConfiguration.swift:10`) has `workingDirectory` and `agentSpawn`. It has no agent id, no tags and no title.
- **The sidecar.** `SessionSidecar` (`Recording/SessionSidecar.swift:11`) records `workingDirectory` (`:86`) and `agentSpawn` (`:43`, `:90`). The sidecar is write-once: `write(_:to:)` uses `.withoutOverwriting` (`:225-235`). Thus a fact that changes later (tags, title, the archive state) cannot go in it.
- **The session.** `RoutedSession` is an actor protocol and a `MailSink` (`Session/RoutedSession.swift:47`). `RoutedSessionActor` (`Session/RoutedSessionActor.swift`) implements it. The mail queue and its records are in `Session/RoutedSessionActorMailRecords.swift`, `Session/RoutedSessionActorQueueing.swift`, `Session/MailQueueDepth.swift` and `Session/SessionOutbox.swift`.
- **The session events.** `SessionEvent` (`Session/SessionEvent.swift:13`) has `submissionStarted` (`:184`), `submissionEnded` (`:191`), `answered` (`:196`), `elicitationRequested` (`:323`) and `mailDelivered` (`:351`).
- **The mail types are in FoundationModelsExtras.** `Mail`, `MailSender` with `.session(ULID)`, `MailBody.agentMessage(from:content:)`, `MailSink`, and `Origin.mail(Set<MailID>)` (`FoundationModelsExtras/Sources/FoundationModelsExtras/Mail/`). Router has a file `Session/SessionMessage.swift`, but no type with the name `SessionMessage`. Thus the new Extras type has no clash.
- **The transcripts.** `TranscriptRecorder` (`Recording/TranscriptRecorder.swift:25`), `JSONLAppend.swift`, `TranscriptFileDiscovery.swift` and the other files of `Recording/` write and read the transcript of each session on disk.
- **The record of past sessions is not in Router.** ACPAgent keeps it in `FoundationModelsACPAgent/Sources/FoundationModelsACPAgent/Transcripts/`: `SessionIndex.swift` (the file `sessions.jsonl`), `ProjectRegistry.swift` (the file `projects.jsonl`), and their helper `JSONLines.swift`. `TranscriptStore.swift` uses them for `session/list` and `session/resume`. These types have no ACP type.
- **No GraphQL.** The Router package does not link GraphQL, and this plan does not add it (D74). The `sessions` GraphQL endpoint (`SessionsGraph`) is in the FoundationModelsMultitool library target, next to the `sessions` tool (MT-10). It uses only the Extras `SessionDirectory` protocol, so it needs no Router type.
- **Test support.** `Tests/FoundationModelsRouterTestSupport` has the scripted models. The new tests use them, and no test needs a real model.

## 3. Dependencies that come first

These changes are in FoundationModelsExtras. Router cannot start the directory before EXTRAS-3.

| Change | What | Needed by |
|--------|------|-----------|
| EXTRAS-3 | `Sources/FoundationModelsExtras/Sessions/`: the `SessionDirectory` protocol and its value types (plan section 6). `Sendable` and `Codable`, no Router type, no ACP type. | ROUTER-1 (the enums of kind and origin), ROUTER-3 and all later changes |
| EXTRAS-4 | `InMemorySessionDirectory`, a public test double in the existing Extras library target (no test-support product, D73). | Not Router. The tests of the `sessions` tool and of `SessionsGraph` in Multitool use it. |

EXTRAS-2 (`GraphQLEndpoint`), EXTRAS-5 (`GraphQLViewer`) and EXTRAS-6 (the GraphQL toolkit) are not needed by Router. MT-10 in Multitool uses them.

The protocol, as EXTRAS-3 defines it:

```swift
public protocol SessionDirectory: Sendable {
    func sessions(matching query: SessionQuery) async throws -> [SessionSummary]
    func summary(of id: ULID) async throws -> SessionSummary?
    func start(_ request: SessionStartRequest) async throws -> SessionSummary
    func addTags(_ tags: Set<String>, to id: ULID) async throws -> SessionSummary
    func removeTags(_ tags: Set<String>, from id: ULID) async throws -> SessionSummary
    /// Sets the title of `id` (Rename, a control action: TestudoApp D84).
    func setTitle(_ title: String, of id: ULID) async throws -> SessionSummary
    func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt]
    func inbox(of id: ULID, markRead: Bool) async throws -> [SessionMessage]
    func archive(_ id: ULID, by: SessionMessageSender) async throws -> SessionSummary
    func events() -> AsyncStream<SessionDirectoryEvent>
}
```

The states are `working`, `needsInput`, `idle` and `archived`. The events are `started`, `factsChanged`, `stateChanged`, `messageDelivered` and `archived`.

## 4. When to build

- ROUTER-1, ROUTER-2 and ROUTER-3 are part of Step 3 of the build (work from the board, `../TestudoApp/features/roadmap.md`). The kanban trigger handler (APP-10) tags each task session with `kanban:<task id>` and finds it again. EXTRAS-3 is also in Step 3.
- All other changes come after Step 3, in the group "Agents that work together".

## 5. Changes, in build order

### 5.1 ROUTER-1 Session facts

- **Spec:** Keep the sidecar as it is: it already has `workingDirectory` and `agentSpawn`, and it stays write-once. Add a second, mutable file `facts.json` in the recording directory of each session, next to `session.json`. It holds `agentID`, `agentName`, `tags`, `title`, `startedBy`, `origin` and `archivedAt` (nil until an archive). Router writes it atomically (a write to a temporary file, then a rename). `SessionConfiguration` gets the same fields, so the first `facts.json` comes from the configuration. A restore reads `facts.json`. A session with no `facts.json` (a session from before this change) gets empty facts and a log warning, not an error. The kind (root, subagent, fork) comes from `agentSpawn` and the fork link. It is not a stored fact.
- **The agent id.** Router stores only a resolved agent id. The launcher (ACPAgent, ROUTER-8) resolves it by D71. The id is an id of the agent catalog (`default` for the root `Agents/AGENT.md`), or `folder:<absolute path>` for a folder agent that is not in the catalog. Router never reads an `AGENT.md` and never resolves an agent.
- **Why:** D23 (Router owns the session facts), D61 (a session is an agent plus a working folder, so the agent id is a fact of the session), D71 (the resolved agent), D68 and D72 (the archive state).
- **Depends on:** EXTRAS-3 (the `SessionOrigin` enum).
- **Tests:**
  - A new session writes `facts.json` with the facts of its configuration. The sidecar has no new key.
  - A fact change rewrites `facts.json`, and the sidecar does not change.
  - A restore reads the facts back. A session with no `facts.json` restores with empty facts.
  - A `folder:` agent id survives the round trip.

### 5.2 ROUTER-3 Session directory

- **Spec:** `RouterSessionDirectory`, an actor that conforms to the Extras `SessionDirectory`. The `Router` actor holds one (`router.sessionDirectory`). Each session that a profile of this router vends (new, restored, forked, subagent) registers itself at the vend points of section 2. The directory holds weak references to the live sessions, so it does not keep a closed session alive. `sessions(matching:)` filters by `workingDirectory`, `agentID`, `tag`, `kind`, `state`, `parentID` and `startedBy`, and it sorts the newest first. With `includesRecorded`, it also gives the sessions on disk.
- **The record of past sessions moves into Router.** Move `SessionIndex` (with `SessionIndexRecord`, `SessionIndexWarning`, `SessionIndexError` and `SessionIndexReadResult`) and `ProjectRegistry` (with `ProjectRegistryRecord`) from ACPAgent `Transcripts/` into Router `Recording/`. Move the `JSONLines` helper with them, or use `JSONLAppend.swift` of Router in its place. The file names `sessions.jsonl` and `projects.jsonl` and their formats do not change, so the files on disk of a user stay valid. The directory reads recorded sessions through these types. There is no `RecordedSessionCatalog` port. ACPAgent then uses Router for `session/list` and `session/resume` (ACPA-14).
- **Events:** `started` when a session registers (new, restored, forked, subagent), before its first `stateChanged`. Each `events()` call gives a new `AsyncStream` with `.bufferingNewest(256)`. The events of one session come in order (plan section 7).
- **Why:** D23 (Router owns the directory; today the live list is per connection in ACPAgent), D72 (Router owns the record of past sessions; it has no ACP concept).
- **Depends on:** EXTRAS-3, ROUTER-1.
- **Tests:**
  - A vended session is in the directory. A subagent has `kind = subagent` and the parent id. A fork has `kind = fork`.
  - A closed session leaves the live list. The directory does not keep it alive.
  - Each filter of the query. The newest session comes first.
  - With `includesRecorded`, a new process finds the sessions on disk through `SessionIndex`.
  - The moved `SessionIndex` and `ProjectRegistry` tests pass in Router. They read files that the old ACPAgent code wrote.
  - The order rule and the buffer rule of the event stream.

### 5.3 ROUTER-2 Session tags

- **Spec:** Tags at creation (`SessionConfiguration.tags`). Later changes only through `addTags` and `removeTags` of the directory. Each change writes `facts.json` and sends `factsChanged`. A tag has 1 to 64 characters: letters, digits, `-`, `_`, `:` and `.`. Another tag gives `invalidTag`. Examples: `reviewer`, `travel`, `kanban:task-42`. `setTitle` changes the title in the same way: it writes `facts.json` and sends `factsChanged`. Rename and tags are control actions, so a UI can call them through the `sessions` graph (TestudoApp D84).
- **Why:** D23. One path for each change, so that each change gives an event.
- **Depends on:** ROUTER-1, ROUTER-3.
- **Tests:** add, remove, persist to `facts.json`, read back after a restore, an invalid tag, the `factsChanged` event, and the query by tag.

### 5.4 ROUTER-8 Session launcher port

- **Spec:**

  ```swift
  public protocol SessionLauncher: Sendable {
      func launchRootSession(_ request: SessionStartRequest) async throws -> any RoutedSession
      func restoreSession(_ id: ULID) async throws -> any RoutedSession
  }
  ```

  The host sets the launcher with `directory.useLauncher(_:)` after it makes both objects. The directory releases it at shutdown, to break the reference loop at run time (the directory holds the launcher, and the launcher makes surfaces that hold the directory). With no launcher, `start`, and a send that needs a start or a restore, throw `noLauncher`.
- **The agent of a start may be nil.** `SessionStartRequest.agentID` and `workingDirectory` are optional. The launcher in ACPAgent (ACPA-9) resolves them: with no folder, the folder of `startedBy` (AG-5); with no agent, the `AGENT.md` of the folder, else the default agent (D71). An unknown agent id throws `unknownAgent` with the near names. The session that the launcher returns has the resolved agent id in its configuration, and the directory writes it to `facts.json` (ROUTER-1).
- **Why:** The Router cannot compose the tools of a session and does not know the agent catalog. A port keeps ACPAgent and FoundationModelsAgents out of Router (constraint 2 of the plan, D23, D61, D71).
- **Depends on:** ROUTER-3.
- **Tests:** `start` calls a fake launcher with the request as it came (a nil agent stays nil). The directory registers the returned session and sends `started`. The first message starts a turn. With no launcher, `start` throws `noLauncher`. Shutdown releases the launcher.

### 5.5 ROUTER-9 Session state and last summary

- **Spec:** The directory maps the session events to `SessionState`: `submissionStarted` gives `working`; `elicitationRequested` gives `needsInput`; `submissionEnded` and `answered` give `idle`; an archive gives `archived`. A rule never asks (D64), so a rule denial (ROUTER-7) does not give `needsInput`. The directory keeps the last final message of each session, cut to 500 characters, as `lastSummary`. Each change sends `stateChanged`.
- **Why:** `check session` of the tool, the `Session.state` field of the graph and the Sessions window (D32) need the state and the summary. D64: rules only deny.
- **Depends on:** ROUTER-3.
- **Tests:** the state events working, needsInput (an elicitation), idle with the last summary, and archived. A rule denial does not change the state. A long final message is cut to 500 characters.

### 5.6 ROUTER-4 Messages between sessions

- **Spec:** `send` resolves the address (plan section 9):
  - a session id: that session;
  - an agent, with a folder as an option: the newest live root session of the agent in that folder (else in the folder of the sender); if there is none, the directory starts one with origin `message` through the launcher, and the message is its first message;
  - a folder: the newest live root session with that working folder (no subagent, no fork); if there is none, `refused` with the hint "Name an agent: @agent:/path." A folder alone does not name an agent (D61);
  - a tag: each live session with the tag, except the sender.

  The directory compares folders after it resolves symbolic links and removes a trailing `/`. It delivers each message as a `Mail` with `MailBody.agentMessage(from:content:)` through `MailSink.mail(_:)`. The sender is a session (`MailSender.session`) or a user through a UI (`MailSender.user`, with the client id in the record). The record keeps `inReplyTo` and the chain depth. `inbox(of:markRead:)` reads the messages that are not read. A `messageDelivered` event follows each delivery. The transcript keeps the sender, so the context renderer can mark the text as a message from another agent (plan section 10.1).
- **Why:** D22 (agents communicate with messages between sessions), D23. The mail types already exist in Extras.
- **Depends on:** ROUTER-3, ROUTER-8 (for the agent address that starts a session).
- **Tests:** each address form; the agent address with no live session starts one; the folder address with no live session is refused; the tag address skips the sender; the record keeps the sender and `inReplyTo`; a UI sender and a session sender.

### 5.7 ROUTER-5 Message delivery and loop guards

- **Spec:** The delivery rules (plan section 10.2), for each sender:
  - An idle target: the message starts a new turn. Receipt `delivered`.
  - A working target, or a target that needs input: the message waits until the current turn ends. Receipt `queued`.
  - A recorded target that is not live: the directory restores it through the launcher (`restoreSession`), and the message starts a turn. If the restore fails, the receipt is `refused`.
  - An archived target: the receipt is `refused` with the reason "archived" (ROUTER-11 sets the state).
  - `inbox` with `markRead` marks the messages read. A read message never starts a turn. Only the unread messages start a turn when the current turn ends.

  The loop guards (plan section 10.3):

  | Guard | Default | Rule |
  |-------|---------|------|
  | Chain depth | 3 | A turn that a message of depth d started gives depth d + 1 to each message that it sends. A user turn and a UI message give depth 1. A send above the limit gives `refused`. |
  | Sends from one turn | 16 | Stops a loop inside one turn. |
  | Targets of one tag send | 8 | More targets give `refused` for the rest. |
  | Message length | 16 KB | A longer text throws `messageTooLong`. |

  The Router computes the depth from the mail ids of the current submission (`Origin.mail(Set<MailID>)`).

  There is no limit on the number of sessions or subagents that work at the same time. No start and no delivery waits for a free slot. The model pool controls the use of the models (D7), and the KV cache on disk lets many sessions wait.
- **Why:** D22, D72 (the user: "i don't want a limit, that's why we added cache to disk"), rule 5 of "Rules for agents that work together". The old limit of 4 came from the subagent cap of FoundationModelsAgents (AG-7 removes it).
- **Depends on:** ROUTER-4, ROUTER-8.
- **Tests:** a send to an idle session starts a turn; a send to a working session waits until the turn ends; `inbox` with `markRead` stops a later turn; a send to a recorded session restores it and starts a turn; each loop guard, for a UI sender and for a session sender; many sessions (more than 4) start and work at the same time, and no receipt is `queued` because of a slot.

### 5.8 ROUTER-11 Archive a session

- **Spec:** `RouterSessionDirectory.archive(_:by:)` ends a session. It stops a running turn of the session (as a cancel does), removes the session from the live list, writes `archivedAt` to `facts.json`, and sends `archived(id:)`. A later send to the session gives `refused` with the reason "archived", and the directory does not restore it. `by` is the session or the user that archives it, for the audit. An archive of a session that is already archived gives its summary again and sends no event.

  The `archive session` operation of the `sessions` tool and the `archive` mutation of the `sessions` graph (Session > Archive in the app; both in Multitool) call it. Both can archive any session that the caller can see. Router has no built-in limit for an archive. Only a deny rule (D64) can stop a model call, through the risk check of the `runCode` snippet (MT-1, in Multitool).
- **Why:** D68 (Close Tab closes only the view; only Session > Archive ends a session), D72 (Q-S5: archive in the tool and the graph, for any session, rules only).
- **Depends on:** ROUTER-1, ROUTER-3, ROUTER-5 (the archived refusal is a delivery rule).
- **Tests:** an archive of a working session stops its turn, removes it from the live list and sends `archived`; after a restart, the facts have `archivedAt` and the state is `archived`; a send to it is refused with the reason "archived"; the query finds it only with `includesRecorded`; a second archive sends no event.

## 6. What other packages do (not in this plan)

- **FoundationModelsMultitool:** the `sessions` tool (MT-2), its mount (MT-9), and the `sessions` GraphQL endpoint `SessionsGraph` (MT-10), all over the Extras protocol (D74).
- **FoundationModelsAgents:** `send agent` and `send caller` call `SessionDirectory.send` (AG-1). AG-7 removes the subagent cap.
- **FoundationModelsACPAgent:** the launcher (ACPA-9), the attach of a live session on `session/resume` (ACPA-11), the viewer of the tunnel (ACPA-13), the use of the Router record for `session/list` and `session/resume` (ACPA-14), and messages in the transcript (ACPA-6).
- **TestudoApp:** the endpoint registry (APP-16) and the trigger handler (APP-10).

## 7. Open questions that touch Router

- **Q-S2. The tab rule.** Does each `start session` of a model open a tab? A coordinator can start many sessions. Proposal: `openInTab` is true for the first 3 starts of one turn, and false after that. The answer changes the `openInTab` resolver of MT-10 (in Multitool).
- **Q-S8. Trust of an external client.** Is the visibility rule of MT-10 correct for an `external` client? Can it see sessions that the user started on the Mac?
- **Q37 (design). Can a profile get to its `Router`?** ROUTER-3 says that each session that a profile of this router vends registers itself. Sessions come from `RoutedLLM.makeSession` through `owningProfile`. Nobody has confirmed that a profile can get to its `Router`. If it cannot, ROUTER-3 must add that link.
- **Q1 (design).** Can a session on one server send to a session on another server (D17)? ROUTER-4 covers one server only.

Q-S9 and Q12 do not touch Router: Q-S9 is about the launcher in ACPAgent, and Q12 is about ACPA-6.
