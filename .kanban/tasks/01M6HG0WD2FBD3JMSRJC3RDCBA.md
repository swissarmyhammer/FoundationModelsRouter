---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Cancel the foreground work of a session and spare the detached background runs
---
## What
ACP v2 rule (prompt lifecycle, background work, PR 2743), relayed by the ACP session 2026-11-03: `session/cancel` does not stop work that is in the latest `background` list; the agent stops waiting for the pending requests of the cancelled work and sends `$/cancel_request` for them. Today `RoutedSession.cancelAll()` cancels the queued mail, the model work AND every background tool run (RunPlane).

## Do
Add `RoutedSession.cancelForeground()` (name may change) that:
- cancels the queued mail;
- cancels the model work of the current submission;
- cancels the tool runs that are still INLINE in the submission (within their settle grace, the turn is waiting for them);
- does NOT cancel runs that outlived their settle grace and went to the background (detached);
- ends the open elicitations of the cancelled work (`elicitationEnded`) as today;
- leaves the detached runs with their claims, their journal and their elicitations.
Keep `cancelAll()` for the user `session/close` and the shutdown paths. Look at `performCancelAll()` (Session/RoutedSessionActorClosing.swift and the cancel code it calls), the run plane `cancelAll`/sweep in Extras (`.build/checkouts/FoundationModelsExtras/Sources/FoundationModelsExtras/Hosting/RunPlaneActor.swift`), `BackgroundToolRunner` (how a run is inline versus detached; `runPlane.wait(...)`), and the elicitation ends. Decide how to tell inline from detached with the Router's own public/internal hooks of the run plane; if the Extras run plane gives no way to cancel only the inline runs, STOP and report what is needed (no change in Extras without the coordinator's word).

## Acceptance Criteria
- [ ] Foreground cancel ends the inline call as cancelled.
- [ ] A detached run keeps running and still completes, with its journal and claims.
- [ ] The open elicitations of the cancelled foreground work end; those of the detached runs stay open.
- [ ] `cancelAll()` is unchanged.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/CancelForegroundTests.swift` with a real background run and an inline call (as `SuspendingCloseTests` does). Full `swift test` once.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. Review, commit, push; tell foundationmodelsacpagent-87 and foundationmodelsagents-67. #subagents