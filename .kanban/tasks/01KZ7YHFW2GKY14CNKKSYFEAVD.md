---
assignees:
- claude-code
position_column: todo
position_ordinal: '9480'
title: '[Router] Align OperationEventSegment declaration spelling with CompactionSegment (explicit Sendable restatement)'
---
Discovered while fixing ^6e7h2q6's review finding (explicit `Sendable` on `CompactionSegment`). `Session/OperationEventSegment.swift` declares `public struct OperationEventSegment: PersistableCustomSegment, Equatable, CustomStringConvertible` with no explicit `Sendable` — the same declaration shape the review engine flagged on `CompactionSegment`.

Important premise (verified 2026-08-04): the conformance is NOT missing. `PersistableCustomSegment` refines Apple's `Transcript.CustomSegment`, which itself refines `Sendable` (see the SDK swiftinterface), so both segment types are already `Sendable` and the explicit restatement is documentation-only. There is no concurrency risk either way.

## What
- Add `, Sendable` to `OperationEventSegment`'s declaration so both `PersistableCustomSegment` conformers spell their declarations the same way.
- Sweep `Session/OperationEventSegment.swift` for any sibling types with the same implicit-spelling shape.

## Acceptance Criteria
- [ ] `OperationEventSegment` declaration matches `CompactionSegment`'s explicit spelling
- [ ] `swift build` and `swift test` green #router-first