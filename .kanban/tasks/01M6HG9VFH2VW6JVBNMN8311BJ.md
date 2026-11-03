---
assignees:
- claude-code
position_column: todo
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