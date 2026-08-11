---
assignees:
- claude-code
position_column: todo
position_ordinal: a280
title: 'Audit the session plumbing surface: capabilities stay, mechanisms go internal'
---
## Problem

`RoutedSession` publicly exposes its raw plumbing — `outbox` and `mailbox` (Sources/FoundationModelsRouter/Session/RoutedSession.swift:101, :110) — even though neither audience needs the mechanism:

- **Tools** reach every capability ambiently through the per-call `ToolContext` binding (post events, `elicit(_:)`, `isCancelled`, correlation identity). A tool never touches `session.outbox`.
- **Apps** have typed methods for their side: `streamSessionEvents()` to observe operation events, `respond(elicitationId:response:)` / `complete(elicitationId:)` to answer elicitations, `dispatchNextPrompt()` for the queue.

The public properties exist for internal wiring (fork composition, restoration seeding) and for tests. They are the members that make the protocol read as a twenty-member god-surface. This task replaces the namespacing/partition discussion: subtract instead.

## Proposed solution

1. Audit every public member of `RoutedSession` (and `SessionOutbox`/`SessionMailbox`'s own public API) and sort each into one of three bins: app-facing capability (stays public, with a doc stating its audience), tool-facing capability (already served by `ToolContext` — the raw member goes internal), or internal wiring (goes internal; tests use `@testable`).
2. Expected outcome, to verify during the audit: `outbox` and `mailbox` go internal; identity (`id`, `parentId`, `routerId`, `recordingDirectory`, `workingDirectory`), conversation methods, queueing (`dispatchNextPrompt`, prompt enqueue), elicitation answers, `cancelCurrentTurn`, `awaitingUser`, `fork`, `close`, `compact`, and `contextFill` stay.
3. Where an external consumer genuinely needs a raw mechanism, do not keep the property — add the missing typed capability and record why.
4. Record the resulting public surface in the DocC catalog with topic groups by audience (the free documentation partition), so the shrunken protocol also reads as organized.

## Acceptance

- `outbox` and `mailbox` are no longer public on `RoutedSession`, or the audit documents the concrete external consumer that keeps each public.
- Tools and apps pass every existing test through `ToolContext` and the typed methods alone.
- The audit table (member, bin, reason) lands in the task comments or the DocC article. #api