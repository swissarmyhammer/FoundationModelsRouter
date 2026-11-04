---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6jkdvsgkr2masr1pcvkt8qk
  text: 'Research. Restore picks the handle from the RECORDED slot of each node, not from the handle it is called on. So a restore on another slot never threw modelMismatch before; it restored onto the old slot. New rule with switchingModel: the root and each recorded fork restore onto THIS handle. Without the flag the old rule stays (modelMismatch against the resident model of the recorded slot). Bug found in RouterSessionDirectory.register: a second object with the id of a live (suspended) session took the keep path. It kept the feed task and inbox watcher of the old object and kept the id in suspendedIDs, so markEnded of the restored session threw sessionSuspended. Fix: the keep path needs the same object. Restore calls no compaction. It re-applies the recorded budget as is (limit in tokens, not scaled to the new model). The doc says so.'
  timestamp: 2026-11-04T06:20:03.248308+00:00
- actor: claude-code
  id: 01m6jkgw81czy56bc9ejwgfvm4
  text: |-
    ### implement — changed
    - evidence: 16 new tests in ModelSwitchRestoreTests.swift. RED run: 8 of 16 failed (the other 8 passed before the code, as they test what must stay). GREEN run: 16 of 16 pass. Full suite run once: 2440 tests, 1 issue (SuspendingCloseTests, "throw lost"). Cause: Extras a87982e makes AnyOperation rethrow CancellationError and LostRunError, so the one outcome rule gives cancelled and lost. The old test said failed and never lost. I changed the test expectation and its doc (cancelled only for CancellationError; cancelled or lost for LostRunError). Router needs no code change: ToolCallHooks already uses OperationOutcome(thrown:). That test passes alone. Extras is now at 0b45545 (a87982e is an ancestor).
    - public names: restoreSession(..., switchingModel: Bool = false); TranscriptEvent.Kind.modelChanged. restoreSessionTree takes the same switchingModel (internal).
    - fix on the way: RouterSessionDirectory.register replaces an entry when another object has the id (before: the suspended old object kept the feed and the suspended mark).
    - next: /review
  timestamp: 2026-11-04T06:21:42.017394+00:00
- actor: claude-code
  id: 01m6jksnp9tcx2zbaw6qtnrc2y
  text: |-
    ### review — findings
    - scope: review sha HEAD~1..HEAD (30014aa6), counts: 1 finding, 1 confirmed, 0 refuted
    - [ ] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:734` `reuse/reuse` — `recordModelChange(of:to:)` rebuilds the same `TranscriptEvent.Partial` (routerId, sessionId, parentId, slot, model, kind, text) and appends it to `node.directory` through `routedLLM.recorder.append` as the existing divergence write does. Two copies of the restore-event write path will drift apart when the event shape changes. Extract one helper on the restore path, for example `appendRestoreEvent(kind:text:of node: SessionNode, on routedLLM: RoutedLLM, slot:model:)`, that builds the `Partial` and performs the append. Call it from both `recordModelChange(of:to:)` and the divergence write, passing the kind and the text in each case.
    - next: implementer fixes the finding, then re-run review.
  timestamp: 2026-11-04T06:26:30.217615+00:00
- actor: claude-code
  id: 01m6jkwb4s4ym7w7acp8jwrwe2
  text: |-
    ### implement — changed
    - finding fixed (checked): `SessionTreeRestoration.swift` recordModelChange(of:to:) and the divergence write built the same TranscriptEvent.Partial and appended it. Now one helper, appendRestoreEvent(kind:text:of:on:slot:model:), builds the Partial and does the append. Both callers use it. The file holds no other recorder.append call, so no other copy remains.
    - evidence: full suite 2440 tests in 287 suites passed, 38 and 19 in the other two runs, zero failures. (The suite was run twice by mistake: the first output was cut by tail.)
    - next: /review
  timestamp: 2026-11-04T06:27:57.721653+00:00
- actor: claude-code
  id: 01m6jkyb9cy80etamzmwdd5sjq
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (6331c9c3): findings 0, confirmed 0, refuted 0; 1 file reviewed; the one prior finding (appendRestoreEvent helper) is checked
    - next: card moved to done; commit is local, not pushed
  timestamp: 2026-11-04T06:29:03.404133+00:00
position_column: done
position_ordinal: ffffffffec80
title: 'Answer: keep the session id across a model-slot switch (plan only, no code)'
---
The ACP agent host asks (for the user) whether a replacement session can keep the id of the session it replaces. The user chose: Router keeps the id. This card holds the answer and a plan. Write no code until the user allows it.

## Facts from the code
- `RoutedModel.makeSession` always makes a new id (`ULID.generate()`, RoutedLLM.swift:242). The recording folder is `<recordingRoot>/<sessionId>/`. There is no way to give an id.
- A session is bound to one model: the RoutedModel that made it. `SessionRecord.model` is one value, set from that model.
- `restoreSession(id:)` keeps the id and appends to the existing transcript and folder. It refuses a different model: `SessionTreeRestorationError.modelMismatch` (SessionTreeRestoration.swift:373).
- `markEnded` refuses a suspended session. `suspend()` writes no ended marker.
- Each submission already records `model.ref` in its span, so the model of each answer is known.

## Answer to Q1
Not today. No public API gives an id to a new session, and restore refuses another model.

## Answer to Q2 (for the recommended shape below)
One id has one folder. The old session is suspended, not ended, so it has no ended marker. The lineage (parent, forks, children) stays, because it is the same node. A new transcript event records the change of model. The `record.model` field takes the new model. The model history stays in the events. If a second session were made with the same id by hand, two live sessions would share one folder and one directory key. That is wrong, so Router must not allow it.

## Answer to Q3: advice
Option A (recommended): a restore that allows a model change. `restoreSession(id:..., switchingTo: <slot or model>)` on the RoutedModel of the new slot, after the host suspends the old session. It reuses the proven restore path: same id, same folder, history rebuilt from the transcript, forks and children restored. Cost: small. Add the parameter, relax the mismatch check only when asked, append a `modelChanged` event, update `record.model`, and test a restore in the same process after a suspend. Limits: the host swaps its object reference; the history may not fit in the context of the new model, so compaction can run; open runs follow the existing orphan rules.

Option B: change the model of a live RoutedSession in place. The object and the id stay, and the host swaps nothing. Cost: large. The outbox, the backend session, the mounted tools and the token counter all bind to the model. A switch in the middle of a submission needs new rules. It touches the cancellation invariants (see memory). Do this later only if the host needs the same object.

Option C: makeSession with a given id. Not advised: it does not carry the history, and it can collide with the old session.

## Plan if the user chooses A
1. Tests first: id equal after a switch; one folder; no ended marker on the old session; transcript has a `modelChanged` event; `ToolContext.sessionID` equals the old id; a read by that id returns the whole history; a restore with a different model but no switch flag still throws `modelMismatch`.
2. Implement the parameter and the event.
3. Run the full suite once, review, local commit. Push only on the words of the user. #subagents

## Review Findings

- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:734` `reuse/reuse` — `recordModelChange(of:to:)` rebuilds the same `TranscriptEvent.Partial` (routerId, sessionId, parentId, slot, model, kind, text) and appends it to `node.directory` through `routedLLM.recorder.append` as the existing divergence write does. Two copies of the restore-event write path will drift apart when the event shape changes. Extract one helper on the restore path, for example `appendRestoreEvent(kind:text:of node: SessionNode, on routedLLM: RoutedLLM, slot:model:)`, that builds the `Partial` and performs the append. Call it from both `recordModelChange(of:to:)` and the divergence write, passing the kind and the text in each case.
