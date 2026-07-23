---
comments:
- actor: claude-code
  id: 01ky63ej2p05rwb55m0qj7tf4x
  text: |-
    Implementation landed and green.

    Research: confirmed `LanguageModelSession.respond(to:)`/`streamResponse(to:)` only accept `PromptRepresentable` (String/Prompt/Array), and `Transcript.Prompt` is not itself `PromptRepresentable` — there is no public SDK path to submit a `.custom` segment as part of what actually reaches the model. So chose option 2 from the task's escape hatch: prepend the preamble to the plain `String` prompt sent to the backend (no `LanguageModelSessionBackend` signature change), and separately attach the `OperationEventSegment`s only onto the *persisted* `.prompt` entry payload — never into the SDK's own live transcript.

    Changes:
    - `Sources/FoundationModelsRouter/Session/OperationEventSegment.swift` (new): `OperationEventSegment: PersistableCustomSegment` wrapping one `OperationEvent`, plus `renderedLine(for:)` — the shared one-line text renderer used both for the turn preamble and the segment's `description`. Format: `[tool] op (correlationID) completed|running: detail`.
    - `Sources/FoundationModelsRouter/Session/RoutedSession.swift`: `generate(grammar:_:)` -> `generate(grammar:prompt:_:)`. Drains `outbox.drainForDispatch()` inside the serial gate (right after `recordSessionMetaIfNeeded()`), composes the model-visible prompt via `composePrompt(pendingEvents:prompt:)` (no-op when empty), threads `pendingEvents` through `finishTurn`/`recordTranscriptDelta`, which appends one `OperationEventSegment` per drained event onto the turn's first `.prompt`-kind diff partial via new `appendingOperationEventSegments(_:to:)`. The drained `.prompt` (queued-prompt dispatch) is intentionally left untouched — that's the separate follow-on task (nothing calls `enqueue(prompt:)` in production yet, so it's always nil today); documented inline.
    - `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`: added `appendingSegments(_:)` to append segments to an existing payload without disturbing other fields.
    - `Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift`: widened `segmentPayload(_:)` from `private` to internal so the chokepoint can reuse the exact same segment-encoding path for a segment that was never part of a live `Transcript.Entry`.
    - Updated `SessionOutbox.swift`'s doc comment cross-reference (previously said "a follow-on task"; now points at the actual implementation).
    - New tests: `Tests/FoundationModelsRouterTests/PendingEventInjectionTests.swift` (7 tests, TDD'd — watched RED via missing-symbol compile failure before writing production code): rendering format, empty-outbox byte-identical no-op, single event -> preamble + persisted segment, drained event doesn't reappear next turn, multiple events preserve outbox order with progress-coalescing, `CustomSegmentRegistry` round-trip, unregistered-discriminator throws.

    Verification: `swift build`, `swift build --build-tests`, `swift test` all green — 391 unit tests + gated integration suite (15 skipped, as expected with no GPU/network), zero failures, only the known pre-existing `mlx-swift_Cmlx.bundle` warning. Adversarial double-check dispatched before final hand-off.
  timestamp: 2026-07-22T23:44:21.078690+00:00
- actor: claude-code
  id: 01ky656enr6cy38dmy8wexb2jn
  text: |-
    Adversarial double-check (via the `double-check` agent) found a real high-severity bug before hand-off: `drainForDispatch()` destructively removes pending events from the outbox *before* the turn runs, but if the turn's diff produces no `.prompt`-kind partial at all (e.g. any `.ebnf`-guided session — `MLXFoundationModelsSessionBackend.respond(to:following:maxTokens:)` calls `grammar.validateForXGrammar()` and throws before ever touching its live session, so the SDK transcript never gains anything), the drained events had nowhere to attach and were silently lost forever — never delivered to the model, never persisted, never returned to the outbox.

    Reproduced with a red test first (`Tests/FoundationModelsRouterTests/PendingEventInjectionTests.swift::pendingEventSurvivesThrowBeforeAnyTranscriptAppend`, using a dedicated `ThrowsBeforeAppendingBackend` that always throws before appending anything — the existing `StubSessionBackend`'s guided path couldn't reproduce this since it records the prompt *before* validating/throwing, the opposite order of the real backend) — watched it fail exactly as predicted, then fixed:

    - `recordTranscriptDelta` now returns `(diffIncludedResponse: Bool, pendingEventsAttached: Bool)` instead of just a `Bool`; `pendingEventsAttached` is `true` whenever `pendingEvents` is empty (nothing to lose) or a `.prompt`-kind partial was found to attach to, `false` otherwise (the shrink-guard branch, or a diff with no `.prompt`-kind partial at all).
    - `finishTurn` threads that third field through.
    - `generate(grammar:prompt:_:)` now calls a new `requeueUnattachedPendingEvents(_:)` on both the success and throwing exits whenever `pendingEventsAttached` is `false`, re-posting the drained events back onto `outbox` via `SessionOutbox.post(_:)` so a future turn gets another chance instead of the drain silently destroying state a failed turn never got to deliver.
    - Updated `generate`'s doc comment to describe this re-queue behavior and fixed a stale `recordTranscriptDelta(grammar:since:usage:)` doc-link (missing `pendingEvents:`).

    Re-verified: `swift build`, `swift build --build-tests`, `swift test` all green — 392 unit tests (391 + this new regression test) + 15 gated integration tests correctly skipped, zero failures, only the known pre-existing `mlx-swift_Cmlx.bundle` warning. Local `review working` engine also reports zero findings. Task remains in `doing`, ready for `/review`.
  timestamp: 2026-07-23T00:14:52.600193+00:00
- actor: claude-code
  id: 01ky66fykxb1qwmqa2sxk7bkdp
  text: |-
    Pulled back from `review` into `doing` to address the 3 open review findings. All fixed by finding the root duplication and deduping properly (not just patching cited lines):

    1. `RoutedSession.swift` requeue-check duplication: extracted a new private helper `finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:)` that calls `finishTurn` and does the `if !pendingEventsAttached { await requeueUnattachedPendingEvents(pendingEvents) }` check exactly once. Both the success and catch branches of `generate(grammar:prompt:_:)` now call this single helper instead of duplicating the check — the success path discards its unused `(diffIncludedResponse, usage)` return, the catch path uses `diffIncludedResponse`/`usage` for the bodyless-close decision as before. Verified via `grep code` there is now exactly one occurrence of the requeue-check pattern in the file.

    2. `SessionOutbox.swift` append duplication: extracted `private func appendNewPendingEvent(_ event: OperationEvent)` wrapping `events.append(PendingEvent(id: ItemID(), event: event))`, called from both the `.completed` case and the `.progress` case's no-match-found branch in `post(_:)`. Exactly one `PendingEvent(id: ItemID(), event:` construction now exists in the file (inside the new helper).

    3. `PendingEventInjectionTests.swift` `@unchecked Sendable`: added a doc comment above `ThrowsBeforeAppendingBackend` explaining the invariant — the type carries no stored state at all, every method is a pure function of its arguments (always throws `Failure.boom` or returns a fixed empty/`nil` value), so there is nothing to race on. Matched the existing convention used elsewhere in the test suite (e.g. `GuidedGenerationTests.swift`'s `MaxTokensRecordingBackend` comment) rather than inventing new phrasing style.

    Verification (really-done): `swift build` — green (only the known pre-existing `mlx-swift_Cmlx.bundle` warning). `swift build --build-tests` — green, no "unsealed contents" issue this run. `swift test` — 392 tests / 42 suites passed, plus 15 gated integration tests correctly skipped (no GPU/network), zero failures — matches the prior verified baseline exactly.

    Note: `diagnostics check working` (SourceKit) reported 3 stale "cannot find OperationEventSegment in scope" errors on `RoutedSession.swift` — a stale sourcekit-lsp index predating these edits (server had been running since before the session started); not real, since `swift build`/`swift test` compiled and ran clean. Treating the build/test commands as authoritative per the task's own instructions.

    Also ran `review working` after the fixes: it reported zero recurrence of any of the 3 original findings, but surfaced one new, unrelated finding — `respond(to:maxTokens:)` has two near-duplicate `generate(...)` call branches differing only in grammar/no-grammar backend dispatch. This is pre-existing code, not introduced by this task, so per "no unrelated refactors" I did not fix it here — logged as new task ^ajkr5dd ("Dedupe generate() calls in RoutedSession.respond(to:maxTokens:)") instead.

    Leaving this task in `doing` for `/review` to pick back up.
  timestamp: 2026-07-23T00:37:32.413792+00:00
depends_on:
- 01KY5TAEDY4T6P7F7848CWWVAJ
position_column: doing
position_ordinal: '80'
title: Inject pending events into the next turn as preamble + persisted custom segment
---
## What

Deliver a session's pending turn-riding events to the model at the next turn boundary, composed into that turn's prompt, and make them durable in the transcript.

- Drain-on-turn: at the start of `respond(to:)`/`streamResponse(to:)` (`Sources/FoundationModelsRouter/Session/RoutedSession.swift`, inside the serial-gated chokepoint so drains never interleave with a concurrent turn), call the outbox's `drainForDispatch()` and compose the turn's prompt as `[pending event segments…] + the caller's prompt segments` — the pending material only becomes part of a `Transcript.Entry` here, by being sent.
- Model-legible rendering: tool-event segments render as a plain text preamble, one line per event, e.g. `[shell] command 3 (swift test) completed: exit 0, 2481 lines` / `[shell] command 3 running: 812 lines so far` — the model reads text, not JSON blobs.
- Durable recording: the same events are recorded as a typed `OperationEventSegment: PersistableCustomSegment` (content = the `OperationEvent`), registered in `CustomSegmentRegistry` so recorded transcripts round-trip through `TranscriptEntryMapper.entry(from:kind:registry:)`. Investigate delivery mechanics: the backend today takes a `String` prompt (`LanguageModelSessionBackend`), while `Transcript.Prompt` supports custom segments (see `Recording/TranscriptEntryMapper.swift` `rebuildPrompt`) — either extend the backend to accept a segmented prompt (preamble text segment + `.custom` segment), or prepend the preamble to the prompt string and record the custom segment alongside; choose based on the backend surface and document the choice.
- Empty outbox → byte-identical behavior to today.

## Acceptance Criteria
- [x] A pending `.completed` event lands in the next turn: the model-visible prompt begins with the rendered preamble, and the recorded transcript for that turn contains the typed custom segment
- [x] `OperationEventSegment` round-trips: record → rebuild via `CustomSegmentRegistry` reproduces the event content
- [x] Multiple pending events render in outbox order (coalesced progress last-value only)
- [x] Empty outbox → recorded transcript and prompt identical to a no-events session
- [x] Public API documented; `swift test` green

## Tests
- [x] Unit tests in `Tests/FoundationModelsRouterTests/` against the repo's fake/recording backend: prompt composition, preamble rendering, segment recording, registry round-trip, empty-outbox no-op
- [x] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running

## Implementation notes (see task comments for full detail)

Chose to prepend the rendered preamble to the plain `String` prompt sent to the backend (no `LanguageModelSessionBackend` signature change — there is no public SDK path to submit a `.custom` segment as part of what actually reaches the model), and to attach `OperationEventSegment`s only onto the *persisted* `.prompt` entry payload, never the SDK's own live transcript. New type `Sources/FoundationModelsRouter/Session/OperationEventSegment.swift`; wiring in `Sources/FoundationModelsRouter/Session/RoutedSession.swift`'s `generate(grammar:prompt:_:)` chokepoint; new tests in `Tests/FoundationModelsRouterTests/PendingEventInjectionTests.swift` (8 tests). An adversarial double-check caught and this fixed a real data-loss bug: events drained from the outbox are now re-queued (`requeueUnattachedPendingEvents(_:)`) if a turn's diff produces no `.prompt`-kind partial to attach them to (e.g. any `.ebnf`-guided turn, whose backend throws before touching its live session at all), instead of being silently lost.

## Review Findings (2026-07-22 19:19)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:483` — Verbatim copy of the pending-event requeue check appears in both the success and error paths of `generate()`. Lines 483–485 (success path) and lines 502–504 (error path) are identical: `if !pendingEventsAttached { await requeueUnattachedPendingEvents(pendingEvents) }`. If the requeue logic changes, both copies must be updated or one will silently diverge. Move the requeue check outside the success/error branching or extract a shared helper function to eliminate the duplication. For example, restructure to call `finishTurn()` once and then unconditionally check `pendingEventsAttached` before the success/error fork, or extract the requeue logic into a private method both paths call.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:110` — Verbatim copy of `events.append(PendingEvent(id: ItemID(), event: event))` appears again at line 119. This pattern is repeated in two branches of the `.progress` case logic — the append when completed and the append when no existing progress entry matches. Copies drift out of sync when one is updated and the other is missed. Extract a helper method `private func appendNewPendingEvent(_ event: OperationEvent)` that wraps the append, then call it from both the `.completed` case (line 110) and the `.progress` case (line 119) to eliminate the duplication.
- [x] `Tests/FoundationModelsRouterTests/PendingEventInjectionTests.swift:212` — @unchecked Sendable conformance requires a documented synchronization invariant explaining why the type is safe to send across isolation boundaries. Add a comment above or on the same line documenting why this class is safe to send unchecked. For example: `// Stateless stub with no mutable state; safe to send across isolation boundaries` or similar documentation of the invariant.