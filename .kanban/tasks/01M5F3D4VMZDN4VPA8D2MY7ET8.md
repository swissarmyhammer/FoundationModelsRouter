---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
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