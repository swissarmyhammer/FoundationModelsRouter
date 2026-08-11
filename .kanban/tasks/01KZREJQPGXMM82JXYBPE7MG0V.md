---
assignees:
- claude-code
position_column: todo
position_ordinal: a180
title: 'Example ergonomics: progress as an AsyncSequence, tree access off the profile'
---
## Problem

Two pieces of boilerplate repeat in every example, so every new user will copy them:

1. **Progress polling.** `ResolutionProgress` is `@Observable`, designed for SwiftUI binding. A CLI caller must write a fifteen-line polling `Task` with a sleep loop to print phase transitions — both examples carry the identical block (Examples/MultiModelGeneration/main.swift:58-73, Examples/CompactionDemo/main.swift:128-143).
2. **Recording path math.** The CompactionDemo composes the router directory by hand — `recordingsDir.appendingPathComponent(profile.standard.routerId.description)` — to load a `TranscriptTree` (Examples/CompactionDemo/main.swift:271-273). User code should never build recording paths from parts; the layout is the router's private convention.

## Proposed solution

1. Add an `AsyncSequence` view of resolution progress — for example `progress.phases` yielding each `(phase, fraction)` transition and finishing at `.ready`/`.failed`. The `@Observable` surface stays for SwiftUI; the sequence serves CLI and tests. Both examples shrink to a three-line `for await` loop.
2. Add tree access to the profile or the routed model — for example `profile.standard.transcriptTree()` returning the loaded `TranscriptTree` for this router's recording root (and throwing the existing typed errors). The CompactionDemo's path math is deleted.
3. Update both examples and the Usage guide to the new forms — the examples are the product's first impression, and they must show the shortest correct code.

## Acceptance

- Neither example contains a polling loop or a hand-built recording path.
- The `for await` progress loop prints the same phase transitions the polling loop printed.
- `ExamplesTests` stays green. #api