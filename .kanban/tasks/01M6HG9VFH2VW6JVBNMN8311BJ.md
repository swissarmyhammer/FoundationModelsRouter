---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6hjhwn5th5vr123k8tx31xe
  text: |-
    ### implement - changed
    - Hooks checkout updated to 35e8810 (contains d9019ab). HookParent carries rootSessionID and gives the kind. HookLineage.make passes kind and rootSessionID to HookSession.
    - SessionHooks.end(reason:): close sends completed, suspend() sends suspended, deinit sends released. The first end wins; later ends do nothing.
    - Root of a live sub-agent: parentCall.rootSessionID, else the recorded AgentSpawn.rootSessionId. Restored sub-agent: recorded AgentSpawn.rootSessionId. Restored fork: root of the restored fork parent.
    - Files: Session/SessionHooks.swift, Session/RoutedSessionActorClosing.swift, Session/RoutedSession.swift, RoutedLLM.swift, Recording/SessionTreeRestoration.swift, Router.swift, Tests/HookLineageTests.swift.
    - Tests: swift test full run, 2414 + 38 + 19 tests, all passed. HookLineageTests has 22 tests, 11 new or changed.
    - Note: the Router has its own SessionEndReason type (ended marker), so the Hooks type is named FoundationModelsHooks.SessionEndReason.
    - Note: after suspend(), the dispatcher gets no more event of that session (the session phase is ended).
    - next: review
  timestamp: 2026-11-03T20:45:32.197922+00:00
position_column: review
position_ordinal: '8180'
title: Router sends SessionEnd with reason suspended or released, and HookSession kind and rootSessionID
---
## What
Request from the ACP session (2026-11-03). Hooks main d9019ab has `SessionEnd(reason: completed|suspended|released)`, `HookSession.rootSessionID` and `HookSession.kind` (root, subagent, fork). Read the pushed Hooks sources in `.build/checkouts/FoundationModelsHooks` (after `swift package --manifest-cache local update` for Hooks only; stop this repo's sourcekit-lsp first) to get the exact types.

## Do
1. `suspend()` (and `suspendLiveSessions()`) sends `SessionEnd` with reason `suspended`. A normal `close()` keeps its current reason (`completed`; check what the Router sends today: grep `SessionEnd` in `Sources/FoundationModelsRouter/Session`).
2. A session that is released by its last reference (`deinit` of `RoutedSessionActor`, or the equivalent release path) sends `SessionEnd` with reason `released`. Check that sending from `deinit` is safe (no `await`, no strong capture; use the existing hook sink the way the current end event does) and that it is sent once per session.
3. `HookSession.kind`: pass it explicitly: `root` for a root session, `subagent` for a sub-agent session (also a RESTORED sub-agent session: from the recorded `agentSpawn`), `fork` for a forked session (a session with a fork parent in its record).
4. `HookSession.rootSessionID`: the root of the family, for all kinds. For a restored sub-agent it comes from the recorded `AgentSpawn.rootSessionId`; for a fork from the fork parent chain.
5. No Bool and no shim; no backward compatibility. Update docs and tests that build a `HookSession` or assert `SessionEnd`.

## Acceptance Criteria
- [ ] suspend sends SessionEnd(suspended) once; close sends the same reason as before; deinit sends released once and never after a close or suspend already sent an end.
- [ ] kind is root, subagent or fork as above, also after a restore.
- [ ] rootSessionID is the family root for root, sub-agent (live and restored) and fork.

## Tests
- [ ] One test per case in the existing hook tests; full `swift test` once.

## Workflow
- Use `/tdd`. Queue: after the `markEnded`-on-suspended card (audit item 5). #subagents