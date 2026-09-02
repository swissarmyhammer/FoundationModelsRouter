# Upstream asks — FoundationModelsRouter

Requests from FoundationModelsACPAgent. Each ask names its motivation, its source task on the ACPAgent board, and the file:line evidence at the pinned Router commit 87c660b. Asks 4 and 6 belong to FoundationModelsMultitool — see `../FoundationModelsMultitool/UPSTREAM_ASKS.md`; Ask 4 has a Router-side half recorded here.

## Ask 1 — a public live elicitation signal

From: FoundationModelsACPAgent, task ^2z6qtqy. Motivation: FoundationModelsACPAgent plan.md §16 and §21.

`ToolContext.elicit(_:)` posts an `OperationEvent` with kind `.elicitation` to the session outbox. But a host has no public live signal that this elicitation is pending:

- `SessionEvent` has no case for it (Sources/FoundationModelsRouter/Session/SessionEvent.swift:9-62).
- `runSettled(OperationEvent)` goes live only for kind `.completed` (Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift:16-17).
- `SessionMailbox.pendingElicitationIds()` is internal (Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:242).
- `TranscriptEvent.operationEvents` is a recorded read, not a live one.
- `ToolContext.elicit` suspends in the mailbox (Sources/FoundationModelsRouter/Hosting/ToolContext.swift:168, :178).

Please supply one of these two:

1. A `SessionEvent` case on `streamEvents()` / `streamSessionEvents()` that carries the `.elicitation` `OperationEvent`.
2. A public `RoutedSession.pendingElicitations()` read, plus a wakeup signal.

The answer side is ready: `RoutedSession.respond(elicitationId:response:)` (RoutedSession.swift:344) and `RoutedSession.complete(elicitationId:)` (RoutedSession.swift:350) are public. Only the request side is missing. Until this lands, the ACP agent cannot relay `elicitation/create` to its client, and a tool that elicits stays suspended until the session closes.

**Answer:** Router commit ef772c0 adds the public case `SessionEvent.elicitationRequested(OperationEvent)` in `Sources/FoundationModelsRouter/Session/SessionEvent.swift`. The case carries the `.elicitation` `OperationEvent` at the moment the session journals it. It is always on `streamSessionEvents()`, and on the turn's stream when the elicitation is raised inside a turn. The suites `ElicitationRoutingTests`, `SessionProjectionTests`, and `TurnOutcomeTests` in `Tests/FoundationModelsRouterTests` show this. Known limit: an elicitation posted through `ToolContext.mount(_:op:as:postingTo:)` with a sink that does not forward to the session outbox never reaches the session journal, so it never reaches this event.

## Ask 2 — expose the subagent spawn fact on TranscriptEvent

From: FoundationModelsACPAgent, task ^nh9myws.

A host can learn that a run spawned a subagent only from `session.json`. Please expose the spawn fact on `TranscriptEvent`, so a live consumer sees it without a file read.

**Answer:** Router commit 1e4552b adds the public field `TranscriptEvent.agentSpawn` and its partial `TranscriptEvent.Partial.agentSpawn` in `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift`. The recorder stamps the value on the `.session` event only. The value is the same `SessionSidecar.AgentSpawn` that `session.json` holds. The suites `TranscriptEventSchemaTests`, `SessionSidecarTests`, and `MergedAndRedactionTests` in `Tests/FoundationModelsRouterTests` show this. Known limit: the `.session` event lands at the first turn, not at `makeSession`, so a live sink sees the spawn fact when the first turn starts. A fork carries `nil`.

## Ask 3 — a public read of the resolved standard-slot context in tokens

From: FoundationModelsACPAgent, task ^f40jzjy.

The resolved working context in tokens is not public at commit 87c660b:

- `RoutedModel.resolution` has `package` access (Sources/FoundationModelsRouter/LanguageModelProfile.swift:28).
- `SlotResolution` is a `package struct` (Resolution/SlotResolution.swift:89) and its `contextTokens` has `package` access (:104).
- `RoutedModel` shows only `chosen` (:22) and `footprintBytes` (:25) publicly.
- `ProfileDefinition.context` (Core/ProfileDefinition.swift:44) is the requested value, not the resolved value; the resolution ladder can select a smaller context (Resolution/JointFit.swift:548).
- `RestoredSession.ContextMismatch.resolved` (Recording/SessionRestoration.swift:26) is public, but only a restore that finds a mismatch supplies it.
- `TurnOutcome.contextFill` and `SessionEvent` usage give fractions after a turn, not a token limit before `makeSession`.

Please supply a public read — for example a public `RoutedModel.contextTokens`, or a public `SlotResolution.contextTokens` together with a public `RoutedModel.resolution`.

Motivation: the ACP agent must build `TokenBudget(limit:)` at `session/new`. The config `compaction:` section carries only fractions (`trigger`, `target`, `hardCeiling`) and `toolOutputLimit`; the limit must come from the model's resolution. Today `budget:` stays `nil` in the agent's `SessionSetup.swift` and automatic compaction is off.

**Answer:** Router commit 591504a adds the public read `RoutedModel.contextTokens` in `Sources/FoundationModelsRouter/LanguageModelProfile.swift`. `RoutedLLM` and `RoutedEmbedder` are aliases of `RoutedModel`, so each has `contextTokens`. The value is the context the resolution ladder selected, in tokens. It can be smaller than `ProfileDefinition.context`. Build the budget with `TokenBudget(limit: model.contextTokens)` before `makeSession`. The suite `ResolveTests` in `Tests/FoundationModelsRouterTests` and the file `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RoutedModelContextTokensSurfaceTests.swift` show this. Known limit: none.

## Ask 4 (Router half) — carry the structured per-call file-change record on the live event surface

From: FoundationModelsACPAgent, task ^9jfmhh0. The primary half belongs to FoundationModelsMultitool (see its UPSTREAM_ASKS.md): make `FileChange`/`FileChangeSet` public and drain the `FileChangeJournal` at the end of each tool call.

Router / Extras half: carry that structured record on the live event surface — a structured payload beside `OperationEvent.detail` (FoundationModelsExtras OperationEvents/OperationEvent.swift:36 is the tool-owned JSON slot), or a `SessionEvent` case. Today `SessionEvent.toolCall` carries only the `code` snippet JSON, `toolStatus` output is the model-facing answer, a succeeded run's `OperationEvent.detail` is the rendered output string (Hosting/ToolRun.swift:196-197), `OperationOutcome` has no payload, and `ToolInvocationRecord` carries identities and timestamps only.

Motivation: the ACP agent must fill `tool_call_update.locations` (plan.md §11.5/§11.6, §20.1 proof 3), and the model-facing rendered string is not a permitted source.

**Answer:** The Router half is complete. Router commit a2de0d0 adds the public type `ToolCallAttachment` in `Sources/FoundationModelsRouter/Hosting/ToolCallAttachment.swift` and the public method `ToolContext.attach(_:)` in `Sources/FoundationModelsRouter/Hosting/ToolContext.swift`. Router commit b3cff6e adds the public type `ToolCallReport`, the public case `SessionEvent.toolCallReport(ToolCallReport)` in `Sources/FoundationModelsRouter/Session/SessionEvent.swift`, and the Router-internal `SessionOutbox.post(report:)`. Router commits ab8a85a and 1472eda add the Router-internal `ToolCallReportSink` route from `ToolRun` and `ContextBindingTool`, and the nested-mount forwarding through `MountedRunUpstreamSink`. A call that closes with at least one attachment posts one `ToolCallReport` after its close record. The suites `ToolContextTests`, `RunToCompletionRunnerTests`, `BackgroundToolRunnerTests`, `ToolMountingTests`, `ToolInvocationLivenessTests`, and `ToolContextMountTests` in `Tests/FoundationModelsRouterTests`, and the file `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/ToolCallAttachmentSurfaceTests.swift`, show this. Known limit: the Multitool half must still call `attach(_:)` with its `FileChangeSet` record at the end of each tool call. A nested mounted call's attachments land on the mounting run's report, under the mounting run's token.

## Ask 5 — forward a nested background run's terminal event to the session outbox

From: FoundationModelsACPAgent, task ^yx45q1q.

A nested background run — `tools.shell.execute` started inside a `runCode` snippet — never gets a `runSettled` event. The drop path at commit 87c660b:

- Multitool's `RunBinding` mounts inner tools through the re-stamping `ToolContext.mount(_:op:as:)` overload (Multitool Invocation/RunBinding.swift:156; Router Hosting/ToolContext.swift:300, :429-431).
- `ToolContext.post(_:)` re-stamps each event with the mounting run's tool, op, and completionToken (Hosting/ToolContext.swift:131-143). The nested run's own token does not go upstream.
- The mounting run settles first, so its `RunEventFunnel.post` drops the copy (Hosting/ToolRun.swift:311). Router documents this drop as intended (ToolContext.swift:267-274).
- `runSettled` fires only on outbox delivery of a `.completed` event (Session/RoutedSessionActorRunJournal.swift:16-18); `claimJournalWrite` admits one terminal for each correlation (:41-44).
- The true terminal, with the nested token and the real outcome, goes only to the mailbox (Hosting/BackgroundToolRunner.swift:120-127). The mailbox does not forward it. Only the `close()` sweep writes it, at session end.

Please forward the nested run's terminal `OperationEvent` to the session outbox under the run's own `completionToken`, so `runSettled` fires for nested runs too. A possible seam: at mailbox settlement, hand the terminal to the outbox journal the way the `close()` sweep already does — `claimJournalWrite(for:)` refuses a duplicate terminal per correlation, so the write is safe.

Motivation: plan.md §8.4 maps `runSettled` to the terminal `tool_call_update`. Today a client shows a nested run as `in_progress` forever, and tier-2 proof 7 cannot assert the `completed` status.

**Answer:** Router commits cbe41e1 and 6ddc873 make `SessionEvent.runSettled` fire for a nested run under the run's own `completionToken`. The mailbox forwards each settled run's terminal event through the Router-internal `BackgroundRunSettlementObserver` in `Sources/FoundationModelsRouter/Session/OperationEventJournal.swift`. `SessionMailbox.markSettled` hands the bounded terminal to the observer, and the session writes it with `SessionOutbox.journalWithoutStaging(event:)` in `Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift`. The journal refuses a second terminal for the same correlation, so the write is safe. The suites `NestedRunTerminalForwardingTests`, `SessionMailboxTests`, and `MountedRunSweptTerminalTests` in `Tests/FoundationModelsRouterTests` show this. Known limit: a run that the `close()` sweep already removed drops its late natural terminal, and the sweep's built terminal is the one the journal holds.
