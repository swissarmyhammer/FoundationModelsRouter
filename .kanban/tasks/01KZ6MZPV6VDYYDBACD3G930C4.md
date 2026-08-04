---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz6zn8rdspfhykyb68d85hmj
  text: |-
    Research findings before implementation:

    - ULID machinery: `Core/ULID.swift` does `@_exported import ULID` (yaslab) and adds `ULID.generate()`; `SessionOutbox.ItemID` wraps `ULID.generate()`. SessionMailbox will mint completion tokens via a `makeCompletionToken()` helper returning `ULID.generate().description`.
    - `OperationOutcome` (Hosting/OperationOutcome.swift) already carries the honest `.stopped`/`.cancelled`/`.lost` distinction; a swiftTask cooperative canceler honestly reports `.cancelled` ("requested; work may continue").
    - `ElicitationRequest`/`ElicitationResponse`/`ElicitationMode` exist in Hosting/Elicitation.swift (dependency task landed). `elicitationId: ULID` on both modes.
    - Journal path for close(): terminal events will be recorded through the recorder as `.toolOutput`-kind `TranscriptEvent`s whose `entry` is a real `Transcript.Entry.toolOutput` carrying a `.custom(OperationEventSegment(content: event))` segment. Rationale: reconstruction (`TranscriptTree.effectiveTranscript`) throws `legacyEventMissingPayload` for any entry-kind event with `entry == nil`, so a payload-less journal line would break restore; OperationEventSegment-on-entry is precisely the existing journaling shape used for turn-drained events (PendingEventInjection), so restore behavior/registry requirements stay identical to the existing precedent.
    - Reentrancy hazard found and handled in sweep(): `await canceler()` suspends the actor, so a run can settle naturally mid-sweep; sweep re-checks the parked map after each await and reuses the natural terminal event instead of synthesizing a second one (exactly-one-terminal invariant).
    - Task<Success, Never>.value is not interruptible by cancelling the awaiting task, so wait(completionToken:seconds:) uses parked CheckedContinuations resumed by a settlement observer, with a deadline task that expires the waiter — never a task-group race on `.value`.
    - Wiring sites confirmed: RoutedLLM.swift:203 (`let outbox = SessionOutbox()`), RoutedSession.swift:1903 (fork `childOutbox`), SessionTreeRestoration.swift:278; plus `makeRoutedSessionActor` and `RoutedSessionActor.init` both take `outbox:` params to mirror for `mailbox:`.
    - Test scaffolding: copy PendingEventInjectionTests' Router+stub pattern (BasicLLMContainer/StubProbe/StubMetadataSource/StubModelLoader + InMemoryRecorder); StubSessionBackend supports makeFork(tools:) so the fork-fresh-mailbox test works against stubs.
  timestamp: 2026-08-04T18:13:02.861801+00:00
- actor: claude-code
  id: 01kz70xdkbwk8w7r70h2hejb3k
  text: |-
    Implementation landed (TDD: SessionMailboxTests written first, RED confirmed via compile failure naming the missing type, then GREEN).

    What was built:
    - `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift` — new actor. Parked runs keyed by completionToken (ULID string via `makeCompletionToken()`, same machinery behind `SessionOutbox.ItemID`); `RunKind` enum ships `.swiftTask` as the phase-2/4 seam; `park/updateProgress/status/wait/cancel`; pending-elicitation registry (`awaitAnswer/respond/complete/pendingElicitationIds`) with URL-mode entries staying open past accept; `sweep()` with exactly-one-terminal invariant.
    - `RoutedSession` protocol gains `nonisolated var mailbox: SessionMailbox` (beside `outbox`) and `func close() async`; `RoutedSessionActor.close()` sweeps and journals each terminal event as a `.toolOutput`-kind recorded event carrying an `OperationEventSegment`; `deinit` doc states it cannot/does not sweep (`.lost` restoration territory). Fresh mailbox wired at all three creation sites (RoutedLLM.makeSession, fork, SessionTreeRestoration) plus `makeRoutedSessionActor`/init.
    - `CustomSegmentRegistry.routerDefault` now registers `OperationEventSegment` so a default-registry restore of a closed session succeeds.

    Double-check (adversarial verify) returned 7 findings; every one implemented:
    1. close() records the `.session` meta line before journaling and journals nothing (not even meta) when the sweep is empty — asserted in tests.
    2. Restore decision made explicit: journaled terminal events rebuild as toolOutput entries; OperationEventSegment added to routerDefault; new close→restoreSessionTree default-registry test proves it; decision stated in close()'s doc comment.
    3. wait(seconds:) clamps untrusted deadlines (NaN/negative → immediate elapse, cap at waitSecondsCeiling = 86_400 s) — parameterized test over -1, 0, .nan.
    4. sweep() reentrancy-guarded via isSweeping; concurrent + sequential double-close test asserts one canceler invocation and one journaled terminal per run.
    5. cancel() on a settled run reports `.alreadySettled(terminal)` instead of lying with `.unknownToken` — tested.
    6. park() refuses a duplicate token (`ParkResult.duplicateToken`), never silently orphaning the incumbent — tested.
    7. settledTerminalEvents retention bounded (FIFO, settledTerminalEventRetentionLimit = 128, documented); eviction test.

    Evidence: `swift build --build-tests` clean (0 errors, 0 compiler warnings); `swift test --filter SessionMailbox` → 20 tests passed; full `swift test` → 652 + 18 + 12 = 682 tests, all green.

    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift (new), Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift, Tests/FoundationModelsRouterTests/SessionMailboxTests.swift (new); swift test 682/682 green
    - next: /review
  timestamp: 2026-08-04T18:34:58.539521+00:00
depends_on:
- 01KZ6MY4E1H1RG9SCY8YR4A48H
- 01KZ6N038H8VC4C5CXQXYKSGNS
position_column: doing
position_ordinal: '80'
title: '[Router] SessionMailbox actor in Hosting/'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"Elevation: waitSeconds and the completion token" (mailbox paragraphs) and §"Consolidation of the siblings" ("Processes and tasks stay different kinds"; "The run plane and the content plane are different surfaces").

## What
Create `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift`: an actor with the same scope rule as `SessionOutbox` — one per session, a fork gets its own fresh one, never shared. It owns parked runs and pending elicitations.

Parked-run entry (keyed by `completionToken`, a ULID string that IS the run's event `correlationID` — reuse the ULID machinery behind `SessionOutbox.ItemID`): the op string, a run-kind discriminator (phase 1 ships `swiftTask`; the enum is the seam where `process` and `mcpRequest` land in phases 2/4), latest progress detail, the settling `Task` handle, and a canceler closure carrying the kind's own semantics (Swift task → cooperative cancellation; the honest-outcome distinction `OperationOutcome` already makes mandatory).

API surface:
- `park(...)` — register a detached run (called by ElevatingTool, next tasks).
- `status()` — snapshot of pending runs: token, op, latest progress. Run plane only: the mailbox carries envelopes and outcomes, never bulk output.
- `wait(completionToken:seconds:)` — await settlement with a deadline. Its result is the run's terminal event `detail` — the (already capped) output tail plus the run's identifier — never a capability's full store. This is the single `wait()` contract; the sandbox-globals and exit tasks use the same wording.
- `cancel(completionToken:)` — invoke the canceler, return the honest `OperationOutcome`; unknown token is a safe, reportable no-op.
- Pending-elicitation registry keyed by `elicitationId` (ULID, distinct from the run's `completionToken`), typed with `ElicitationRequest`/`ElicitationResponse` from the elicitation-envelope task: holds a `CheckedContinuation` for a form answer; URL-mode entries stay open past `accept` until `complete(elicitationId:)` arrives; unknown and already-completed ids are safe no-ops per the MCP spec.
- `sweep()` — deterministic session-teardown sweep: for each parked run, invoke its canceler with that kind's semantics, ensure exactly one terminal event is posted (journal complete before close — no orphans, no holes); reject all pending elicitations.

Teardown entry point (finding from double-check: no such hook exists today — `RoutedSessionActor` has only `deinit`, which cannot await an actor or journal events): add an explicit async teardown requirement to `RoutedSession` (e.g. `func close() async`), whose default implementation runs `mailbox.sweep()` and drains the resulting terminal events into the journal before returning. Name its call sites: host apps ending a conversation, `multitool-cli` teardown, and fork/restore paths that discard a session. Document on `deinit` that it cannot and does not run the sweep — an unclosed crashed session is the `.lost` restoration task's territory.

Wire the session: `RoutedSession` protocol gains `nonisolated var mailbox: SessionMailbox` alongside `outbox` (RoutedSession.swift:116), created fresh at the three sites that create a `SessionOutbox` today (RoutedLLM.swift:204, RoutedSession.swift:1904 fork, SessionTreeRestoration.swift:279).

## Acceptance Criteria
- [ ] One mailbox per session; a fork's mailbox is a distinct instance; restore creates fresh instances
- [ ] `park`/`status`/`wait`/`cancel` round-trip a fake parked Task; `cancel` returns the outcome the canceler reports, not a guess
- [ ] `wait()` on a run whose fake body produced large output returns a bounded result carrying the run identifier, not the full output
- [ ] `RoutedSession.close()` runs the sweep: every parked run cancelled cooperatively, exactly one terminal event each, journaled before `close()` returns — asserted through `close()`, not by calling `sweep()` directly
- [ ] Unknown `completionToken` / `elicitationId` operations are no-ops that report "unknown", never throw or crash
- [ ] `swift test` green

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/SessionMailboxTests.swift`: park/status/wait/cancel lifecycle; wait deadline elapse; bounded wait-result; cancel-while-waiting; `close()`-driven sweep with multiple parked runs asserting one terminal event each in the journal; fork gets fresh mailbox; unknown-id no-ops
- [ ] `swift test --filter SessionMailbox` green, full suite green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first