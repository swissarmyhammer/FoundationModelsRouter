---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f7gcwpyf8qr5xv9m0gvvzv
  text: |-
    Notes:
    - Name difference: EXTRAS-3 ships the origin enum as `SessionDirectoryOrigin`, not `SessionOrigin` (its own doc says so because of the FoundationModelsHooks clash). `SessionFacts.origin` is `FoundationModelsExtras.SessionDirectoryOrigin?`, spelled qualified as the card asks. No clash remains with Hooks' `SessionOrigin`.
    - Extras pin: the local Package.resolved already names bd34b20 (EXTRAS-3, has Sources/FoundationModelsExtras/Sessions/). Package.resolved is gitignored, so the pin is not in the commit.
    - schemaVersion: `public let schemaVersion`, `public static let currentSchemaVersion = 1`; an absent key decodes as 1 and an absent `tags` as []; a newer version throws `RecordingSchemaVersionError.recordingFromNewerRouter`, the sidecar's rule.
    - write uses `Data.write(options: .atomic)`; encoder is pretty-printed, sorted keys, ISO 8601 dates.
    - The public surface test reaches the origin through `.client` (implicit member) because the public-surface target links Router alone and Router does not re-export `SessionDirectoryOrigin`; re-exporting it is a separate API decision, not taken here.
  timestamp: 2026-10-21T12:38:18.262946+00:00
- actor: claude-code
  id: 01m5f7gf4rpm74mbj0gwcb61ay
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Recording/SessionFacts.swift, Tests/FoundationModelsRouterTests/SessionFactsTests.swift (9 tests), Tests/FoundationModelsRouterPublicSurfaceTests/SessionFactsPublicSurfaceTests.swift (1 test). RED: build failed "cannot find 'SessionFacts' in scope". GREEN: `swift build --build-tests` clean (only the pre-existing "missing creator for mutated node" build-system note); full `swift test`: 1950 tests / 243 suites passed with 9 known issues; 28 tests / 16 suites; 19 tests / 3 suites.
    - next: review
  timestamp: 2026-10-21T12:38:20.568387+00:00
- actor: claude-code
  id: 01m5g78w2pejz8a11njxw7aweq
  text: |-
    ### review — findings
    - evidence: review sha f09c5935~1..f09c5935 — 1 finding (confirmed 1, refuted 3); Sources/FoundationModelsRouter/Recording/SessionFacts.swift:123 (reuse/reuse)
    - next: implement the open Review Findings item, then re-review
  timestamp: 2026-10-21T21:53:26.102524+00:00
- actor: claude-code
  id: 01m5g7e9epf61f9t1nmsy6dnrx
  text: |-
    Fixed reuse/reuse finding (SessionFacts.swift:123 — Reimplements JSONDecoder creation already done by JSONLines.makeDecoder). Removed both private helpers from SessionFacts: read now uses JSONLines.makeDecoder(), write now uses JSONLines.makeEncoder() (the duplicated encoder setup was the same cause). Consequence: facts.json is now one compact line (sorted keys, RFC 3339 dates, unescaped slashes) instead of pretty-printed; decoding is format-agnostic so earlier pretty files still read. SessionSidecar's own pretty encoder was left alone (it has no date strategy, different contract, outside this file). New test SessionFactsTests.theFileIsWrittenInTheSharedRecordEncoding pins the bytes (RED: got pretty-printed output with escaped slashes; GREEN after the change). JSONLines doc now names SessionFacts as a user.

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Recording/SessionFacts.swift, Sources/FoundationModelsRouter/Recording/JSONLines.swift, Tests/FoundationModelsRouterTests/SessionFactsTests.swift; `swift build --build-tests` clean (only the pre-existing "missing creator for mutated node" build-system note); `swift test --filter "SessionFacts|SessionSidecar"` 46 tests / 4 suites + 1 public-surface test passed
    - next: review
  timestamp: 2026-10-21T21:56:23.638881+00:00
position_column: doing
position_ordinal: '80'
title: 'ROUTER-1: SessionFacts value and the atomic facts.json file'
---
## Goal
Give each recorded session a second, mutable file `facts.json` (next to the write-once `session.json`) that holds the facts that change: agent id, agent name, tags, title, `startedBy`, origin and `archivedAt`.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-1-session-facts
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.1
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 6 (`SessionOrigin`), 13.3, 14 (ROUTER-1)

## External dependency (do not start before it)
EXTRAS-3 (the `SessionDirectory` port and its value types in `FoundationModelsExtras/Sources/FoundationModelsExtras/Sessions/`) is owned by session foundationmodelsextras-a8 in the FoundationModelsExtras repo; it is not planned here. This card needs its `SessionOrigin` enum. EXTRAS-3 must land on Extras `main`, and the Router pin must move to it: run `swift package update FoundationModelsExtras` so `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Package.resolved` names an Extras revision that has `Sessions/` (today it pins `6670bc0`, which has none). The ROUTER-1 spec line says "Depends on: —", but the Router plan (session.md 5.1) names EXTRAS-3 for this enum.

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/SessionFacts.swift`: `public struct SessionFacts: Codable, Sendable, Equatable` with `agentID: String?`, `agentName: String?`, `tags: Set<String>`, `title: String?`, `startedBy: ULID?`, `origin: FoundationModelsExtras.SessionOrigin?`, `archivedAt: Date?`, and a `schemaVersion` (additive, like `SessionSidecar`). `static let fileName = "facts.json"`. `static func read(from directory: URL) throws -> SessionFacts?` gives `nil` when the file is absent. `func write(to directory: URL) throws` writes atomically (temporary file, then rename: `Data.write(options: .atomic)`), and it overwrites, unlike `SessionSidecar.write(_:to:)` in `Recording/SessionSidecar.swift`, which stays write-once with `.withoutOverwriting`.
- The agent id is only a resolved id (D71): a catalog id (`default` for the root agent) or `folder:<absolute path>`. Router never resolves it.
- **Name clash:** `FoundationModelsHooks` already has a public `SessionOrigin` (`FoundationModelsHooks/Sources/FoundationModelsHooks/HookEvents.swift`), and `Session/SessionConfiguration.swift` uses it unqualified for `hookOrigin`. Router imports both modules, so spell the new type `FoundationModelsExtras.SessionOrigin` wherever both are visible.
- `SessionSidecar` gets no new key.

## Subtasks
- [ ] Failing test first: `SessionFactsTests` round trip (write, read back equal), and a read of a directory with no `facts.json` gives `nil`.
- [ ] Bump the Extras pin in `Package.resolved` to the revision with EXTRAS-3, and confirm `swift build` passes.
- [ ] Add `SessionFacts` with atomic overwrite; a second write replaces the first, and `session.json` in the same directory is byte-for-byte unchanged.
- [ ] A `folder:/abs/path` agent id and a `Set` of tags survive the round trip; decoding a file with an unknown extra key succeeds (additive schema).
- [ ] Public surface test that uses `SessionFacts` without `@testable`.

## Acceptance Criteria
- [ ] `SessionFacts.write(to:)` followed by `SessionFacts.read(from:)` returns an equal value, including a `folder:` agent id and `archivedAt`.
- [ ] A second write overwrites `facts.json`; no temporary file stays in the directory; `session.json` does not change.
- [ ] `read(from:)` of a directory with no `facts.json` returns `nil` and does not throw.
- [ ] The Extras pin names a revision that has `Sources/FoundationModelsExtras/Sessions/`.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionFactsTests.swift` (Swift Testing).
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterPublicSurfaceTests/SessionFactsPublicSurfaceTests.swift`.
- [ ] `swift test --filter SessionFacts` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording #blocked-external

## Review Findings (2026-10-21 16:49)

> Scope: `review sha f09c5935~1..f09c5935` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/SessionFacts.swift:123` `reuse/reuse` — Reimplements JSONDecoder creation already done by JSONLines.makeDecoder. Both configure a decoder identically with `.iso8601` date decoding. Should reuse the existing function instead of duplicating the capability. Call `JSONLines.makeDecoder()` instead of duplicating the decoder configuration, or extract both into a shared utility in the Recording module.
