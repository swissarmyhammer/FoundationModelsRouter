---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bjrkwvwjzt08nykbrh8whf
  text: |-
    ## Audit at `dd55fcd2c` — LIVE

    Re-checked, and the claim holds. `Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording/README.md:121-127` still holds the prose "Re-recording it" paragraph. No generator target exists, and no gated regeneration suite exists.
  timestamp: 2026-08-18T23:19:35.067523+00:00
position_column: todo
position_ordinal: 8f80
title: Give the checked-in compaction recording a regeneration tool, not a prose recipe
---
Discovered while doing `^pfdrppj`.

`^pfdrppj` checked a real recording into
`Tests/FoundationModelsRouterIntegrationTests/Fixtures/CompactionRecording/` and
`RecordedTranscriptCompactionIntegrationTests` folds it. The fixture itself is inert, which
was the whole point: nothing in Swift states its size, so nothing can silently disagree
with it.

But the way to MAKE another one is prose. The generator was a temporary file in the
integration test target, run once and then deleted, and what survives is the recipe table
in the fixture's own `README.md`.

## Why that matters

A recording carries a `RecordingSchemaVersion`. This one carries version 2.
`TranscriptTree.load(under:)` refuses a recording from a newer router, so a schema bump
makes this fixture unreadable and somebody has to record a new one. At that moment the
recipe is prose, and prose is the thing this card's parent was written to remove.

## What to build

A way to record the fixture again that is code rather than a paragraph. Points to settle:

- Where it lives. An `Examples/` executable target costs `Package.swift` surface. A gated
  suite in the integration target costs a test that asserts little. Neither is obviously
  right.
- Whether it writes into the fixture directory directly, or into a directory the caller
  names and a person then copies.
- How it keeps the redaction guarantees `^pfdrppj` settled: the `recordingRoot:` override
  must stay unset, and `workingDirectory` must be set to a value chosen for the fixture.
  Both are currently facts a person has to read in the README and remember.
- Whether the redaction scan itself becomes code — a check that the recorded bytes carry no
  operator path — rather than a table of what somebody once grepped for.

## Acceptance Criteria

- [ ] The recording can be made again by running something, not by following a paragraph
- [ ] The two redaction settings are in the tool rather than in prose
- [ ] The tool states where it puts its output, and does not silently overwrite the fixture
- [ ] `Fixtures/CompactionRecording/README.md` points at the tool instead of restating the recipe #compaction #test-debt