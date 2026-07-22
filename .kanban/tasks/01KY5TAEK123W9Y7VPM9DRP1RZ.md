---
depends_on:
- 01KY5TAEDY4T6P7F7848CWWVAJ
position_column: todo
position_ordinal: 8d80
title: Inject pending events into the next turn as preamble + persisted custom segment
---
## What

Deliver a session's pending turn-riding events to the model at the next turn boundary, composed into that turn's prompt, and make them durable in the transcript.

- Drain-on-turn: at the start of `respond(to:)`/`streamResponse(to:)` (`Sources/FoundationModelsRouter/Session/RoutedSession.swift`, inside the serial-gated chokepoint so drains never interleave with a concurrent turn), call the outbox's `drainForDispatch()` and compose the turn's prompt as `[pending event segments…] + the caller's prompt segments` — the pending material only becomes part of a `Transcript.Entry` here, by being sent.
- Model-legible rendering: tool-event segments render as a plain text preamble, one line per event, e.g. `[shell] command 3 (swift test) completed: exit 0, 2481 lines` / `[shell] command 3 running: 812 lines so far` — the model reads text, not JSON blobs.
- Durable recording: the same events are recorded as a typed `OperationEventSegment: PersistableCustomSegment` (content = the `OperationEvent`), registered in `CustomSegmentRegistry` so recorded transcripts round-trip through `TranscriptEntryMapper.entry(from:kind:registry:)`. Investigate delivery mechanics: the backend today takes a `String` prompt (`LanguageModelSessionBackend`), while `Transcript.Prompt` supports custom segments (see `Recording/TranscriptEntryMapper.swift` `rebuildPrompt`) — either extend the backend to accept a segmented prompt (preamble text segment + `.custom` segment), or prepend the preamble to the prompt string and record the custom segment alongside; choose based on the backend surface and document the choice.
- Empty outbox → byte-identical behavior to today.

## Acceptance Criteria
- [ ] A pending `.completed` event lands in the next turn: the model-visible prompt begins with the rendered preamble, and the recorded transcript for that turn contains the typed custom segment
- [ ] `OperationEventSegment` round-trips: record → rebuild via `CustomSegmentRegistry` reproduces the event content
- [ ] Multiple pending events render in outbox order (coalesced progress last-value only)
- [ ] Empty outbox → recorded transcript and prompt identical to a no-events session
- [ ] Public API documented; `swift test` green

## Tests
- [ ] Unit tests in `Tests/FoundationModelsRouterTests/` against the repo's fake/recording backend: prompt composition, preamble rendering, segment recording, registry round-trip, empty-outbox no-op
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running