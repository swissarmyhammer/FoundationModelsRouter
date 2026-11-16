---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j2zp7qbcxje64gf1jph10h
  text: |-
    ### design — decided by the orchestrator
    - Protocol is SYNCHRONOUS and `Sendable`, so the nonisolated summary paths of `RouterSessionDirectory` (under its `Mutex`) can read it:
      ```swift
      public struct SessionUsage: Sendable, Codable, Equatable { public var pinnedAt: Date?; public var lastUsedAt: Date?; public var recordingRoot: URL? }
      public protocol SessionUsageStore: Sendable {
          func usages() -> [ULID: SessionUsage]
          func usage(of id: ULID) -> SessionUsage?
          @discardableResult func setPinned(_ pinned: Bool, of id: ULID, recordingRoot: URL?, at time: Date) throws -> SessionUsage
          @discardableResult func markUsed(_ id: ULID, recordingRoot: URL?, at time: Date) throws -> SessionUsage
      }
      public final class JSONFileSessionUsageStore: SessionUsageStore  // Mutex inside, `init(fileURL: URL, maximumRecentCount: Int = defaultMaximumRecentCount)`, default 100
      ```
    - Keep `pinnedAt` (not a Bool) because the Extras port has `SessionSummary.pinnedAt` and `SessionOrder.pinOrder` (first pin first). A second pin keeps the first time; an unpin sets nil. A nil `recordingRoot` argument keeps the stored root.
    - An entry with no pin and no last use is removed (unpin of a never-used session).
    - Trim: keep all pinned entries + the `maximumRecentCount` newest `lastUsedAt` entries that are not pinned.
    - File format: a versioned JSON object, e.g. `{"version":1,"sessions":{"<ulid>":{...}}}`. ISO 8601 dates.
    - Load lazily at the first read; missing/damaged → empty + `RouterTelemetry.makeLogger(.sessionDirectory).warning(...)` for damaged (missing is silent or debug). Create the parent folder on write. Write with `.atomic`.
    - Do NOT run swift format. Files are 4-space indent. Write comments in ASD-STE100 Simplified Technical English, as the repo does.
  timestamp: 2026-11-16T11:48:23.415261+00:00
- actor: claude-code
  id: 01m7j39egv7ja6z60we5x65502
  text: |-
    ### research
    - Reuse `MillisecondDate` (Recording/MillisecondDate.swift) for the ISO 8601 dates, as `ProjectRecord` does. Dates are rounded to the millisecond on write, so a usage reads back equal.
    - `ULID` is Codable as a string, but `[ULID: X]` encodes as a JSON array with JSONEncoder. The file keeps `sessions` as `[String: SessionUsage]` and converts the keys.
    - Log pattern: `RouterTelemetry.makeLogger(.sessionDirectory).warning(msg, metadata: RouterTelemetry.errorMetadata(error) + filePath)` as in ProjectStore.
    - Test log capture: `TelemetryCapture.run(forbidding: [])` sees the logs of a synchronous call in the same task (ProjectStoreTests pattern).
    - Lazy load is modelled as an enum state (`unread` / `read(entries)`) inside a `Mutex`, not an Optional that a later call fills.
    - A write computes the new entries, writes the file, and only then changes the memory, so a failed write leaves file and memory as they were.
  timestamp: 2026-11-16T11:53:43.195827+00:00
- actor: claude-code
  id: 01m7j796s6rym90cs4tbcjcz3y
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Directory/SessionUsageStore.swift (SessionUsage, SessionUsageStore), Sources/FoundationModelsRouter/Directory/JSONFileSessionUsageStore.swift, Tests/FoundationModelsRouterTests/JSONFileSessionUsageStoreTests.swift. `swift test --filter JSONFileSessionUsageStoreTests`: 14 named tests passed (RED was a compile failure: the types did not exist). One more test (a key that is not a ULID) was added after GREEN. Full `swift test`: 2747 tests in 323 suites passed, 0 failures; no warning in the new files (one SwiftPM "missing creator for mutated node" mlx bundle warning, not from this change).
    - discovery: the local `.build/checkouts/FoundationModelsExtras` was behind (`PendingRunEnvelope.waitingStatusPrefix` missing, HEAD did not build). Package.resolved is gitignored. Fix: stop the repo's sourcekit-lsp, `swift package --manifest-cache local update FoundationModelsExtras` (now 65543a6).
    - decisions: a failed write leaves the file and memory as they were; an unknown version, a non-ULID key, or two keys that give one ULID make the file "damaged" (empty store + warning `a session usage file cannot be read; the store starts empty`); `maximumRecentCount` must not be negative (precondition); trim order is newest lastUsedAt first, then the greater ULID.
    - next: /review
  timestamp: 2026-11-16T13:03:29.574339+00:00
position_column: doing
position_ordinal: '80'
title: 'Session usage store: SessionUsageStore and the JSON file store (ROUTER-3, D186)'
---
## What
Add `SessionUsageStore`, a protocol of Router, and `JSONFileSessionUsageStore`, its JSON file implementation, in `Sources/FoundationModelsRouter/Directory/`.

- The store keeps one `SessionUsage` for each session id: `pinnedAt` (the pin, the first pin time), `lastUsedAt` and `recordingRoot`.
- The store keeps a maximum number of entries that are not pinned (`maximumRecentCount`). It removes the oldest last use first. It never removes a pinned entry.
- A write is atomic (`Data.write(options: .atomic)`).
- A missing or damaged file gives an empty store and a log warning, not a failure.

## Acceptance criteria
- [x] A pin, an unpin and a last use go to the file and come back after a new store reads the same file.
- [x] A second pin keeps the first pin time.
- [x] Above the limit, the oldest entry that is not pinned goes. A pinned entry stays.
- [x] A missing file and a damaged file give an empty store, and a write after a damaged file works.

## Tests
- `Tests/FoundationModelsRouterTests/JSONFileSessionUsageStoreTests.swift`
- Run: `swift test --filter JSONFileSessionUsageStoreTests` #router-3