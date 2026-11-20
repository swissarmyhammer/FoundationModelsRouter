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
position_column: doing
position_ordinal: '80'
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