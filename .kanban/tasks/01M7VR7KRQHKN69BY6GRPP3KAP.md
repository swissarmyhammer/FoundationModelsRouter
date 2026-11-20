---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7vr99jhadypjhj6rcn6rwwk
  text: 'Research: the Extras pin is now 5660d0d in the root and in IntegrationTests (Package.resolved, gitignored). No sourcekit-lsp process had this repo as cwd. `SessionImportProvenance.sourceTitle: String?` is declared after `sourcePath` with the default nil. The existing provenance round-trip tests are in Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift (save and read of `index.md`); the new tests go there.'
  timestamp: 2026-11-20T05:53:48.113901+00:00
- actor: claude-code
  id: 01m7vrhhsz1cke8wkb9q95q0tg
  text: 'Implementation landed. RecordedImportProvenance now has the key `sourceTitle` in CodingKeys, copies it in `rounded(_:)`, decodes it with `decodeIfPresent`, and encodes it with `encodeIfPresent` (no key when nil). The doc comments say that the map has no key for an absent `sourceTitle`. Three tests in SessionIndexFileTests: `theSourceTitleOfTheImportProvenanceSurvivesASaveAndARead` (failed before the change, as expected), `aProvenanceWithNoSourceTitleWritesNoSourceTitleKey` and `aProvenanceWithNoSourceTitleReadsBackWithNoTitle`. The last two passed before the change too, because the old code wrote no key and dropped the value; they guard the choice of `encodeIfPresent` and `decodeIfPresent`. Discovery: each build shows the SwiftBuild line `warning: missing creator for mutated node: (''.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS'')`. It comes from the build system for the mlx-swift bundle of a dependency, not from a compiler diagnostic in this repo, and it was there before the production change.'
  timestamp: 2026-11-20T05:58:18.687462+00:00
- actor: claude-code
  id: 01m7vrhm9975qxpf8h20xwbdnp
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Recording/RecordedImportProvenance.swift, Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift. Extras resolved at 5660d0d (root and IntegrationTests). One full `swift test`: exit 0; 3253 tests in 364 suites, 54 tests in 28 suites, 19 tests in 3 suites passed; 0 failed. Not committed.
    - next: /review
  timestamp: 2026-11-20T05:58:21.225394+00:00
- actor: claude-code
  id: 01m7vrmys0fyc8pm1sxbw70zgx
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (0a1d1ddb); 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift:48 reuse/reuse
    - next: implement the finding (make `provenance` take an optional `sourceTitle` and remove the parallel `titledProvenance` copy), then test, commit and review again.
  timestamp: 2026-11-20T06:00:10.272416+00:00
- actor: claude-code
  id: 01m7vrndcjffaf5th8dr4z3s4k
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 2 files
    - test: green — swift test, 3326 passed, 0 failed
    - commit: 0a1d1ddb
    - review: findings — Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift:48
  timestamp: 2026-11-20T06:00:25.234711+00:00
- actor: claude-code
  id: 01m7vrsjkftb9gjgrb1bmbepgh
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift. The finding is done: `provenance` is now `provenance(sourceTitle: String? = nil)`, the titled case is `provenance(sourceTitle: Self.sourceTitle)`, and `titledProvenance` is removed. The finding is checked. `swift test --filter SessionIndexFileTests`: 20 tests in 1 suite passed. One full `swift test`: exit 0; 3253 tests in 364 suites, 54 tests in 28 suites and 19 tests in 3 suites passed; 0 failed, 0 skipped. The only warning is the SwiftBuild line `missing creator for mutated node` for the mlx-swift_Cmlx bundle of a dependency. That warning was there before this change. Not committed.
    - next: /review
  timestamp: 2026-11-20T06:02:41.647207+00:00
- actor: claude-code
  id: 01m7vrwp6kgh1qjzm3er1pkez4
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (46b69d9d) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed. The prior finding (SessionIndexFileTests.swift:48 reuse/reuse) is checked.
    - next: task is in done. Send the sha to testudoapp-9a after the push.
  timestamp: 2026-11-20T06:04:23.635691+00:00
- actor: claude-code
  id: 01m7vrx6rx1eb22vtw2b0vw8xs
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file
    - test: green — swift test, 3326 passed, 0 failed
    - commit: 46b69d9d
    - review: clean
  timestamp: 2026-11-20T06:04:40.605818+00:00
position_column: done
position_ordinal: ffffffffffc580
title: Keep sourceTitle in the recorded import provenance (D209 follow-up)
---
Extras 5660d0d added the optional `sourceTitle: String?` to `SessionImportProvenance`. Its init argument comes after `sourcePath`, and the default is nil.

In `Sources/FoundationModelsRouter/Recording/RecordedImportProvenance.swift`, `rounded(_:)` and `init(from:)` make a new `SessionImportProvenance` field by field. They do not copy `sourceTitle`, and `encode(to:)` does not write it. So the title is lost after a reload.

- [x] Move the Extras pin to 5660d0d or later (root and IntegrationTests, `swift package --manifest-cache local update FoundationModelsExtras`; stop the sourcekit-lsp of the repo first).
- [x] Add the key `sourceTitle` to `CodingKeys`.
- [x] Copy `sourceTitle` in `rounded(_:)`.
- [x] Decode it with `decodeIfPresent` in `init(from:)`; encode it with `encodeIfPresent` in `encode(to:)` (no key when nil).
- [x] Update the doc comments.
- [x] Add a round-trip test: a provenance with a `sourceTitle` reads back equal after a save and a reload of the record; a provenance with no title writes no key and reads back nil.
- [x] `swift test` passes (one full run).

Requested by testudoapp-9a. Send the sha to it after the push.

## Review Findings (2026-11-19 23:58)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/SessionIndexFileTests.swift:48` `reuse/reuse` — `titledProvenance` rebuilds the whole `SessionImportProvenance` that the existing `provenance` property (lines 37-42) already builds, changing only `sourceTitle`. This is a near-match that was not extended. Giving `provenance` a `sourceTitle` parameter (default nil) would remove the parallel copy, so the field list is kept in one place and a future field added to `provenance` cannot drift from the titled copy. Make `provenance` take an optional title, for example `private static func provenance(sourceTitle: String? = nil) -> SessionImportProvenance`, and build the titled case as `provenance(sourceTitle: sourceTitle)`. Update the existing uses of `provenance` to the new form, or keep a computed `provenance` that calls it with the default. Then delete `titledProvenance`, or keep it as a one-line alias.
