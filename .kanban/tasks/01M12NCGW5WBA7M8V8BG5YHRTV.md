---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m136ansy8zh6syr0aj1fc3qs
  text: |-
    Research done.

    Findings:
    - `ModelRef` (Sources/FoundationModelsRouter/Core/ModelRef.swift) splits on the first `@`. `revision` is `nil`, a commit hash, a branch, or a tag. No helper classifies it yet, so the reader must add one.
    - `RepoMetadataReader` has no inbound callers in the call graph other than its own `footprint(for:)`, so the change is local to `Sizing/RepoMetadata.swift`.
    - The file already holds a private file-level logger, `repoMetadataCacheLogger`, made with `makeModuleLogger(category:)`. The fallback log line follows that pattern.
    - Three tests in `RepoMetadataTests.swift` pin the old cache-first order with revisions that are NOT full commit hashes, so they must move to a real 40-character hash to keep their intent:
      - `cacheHitFetchesOnce` and `metadataReFetchesOnStaleSchemaCacheEntry` use `org/model@abc123`.
      - `cacheKeySeparation` uses `rev1` and `rev2`.
    - The existing `StubMetadataSource` counts fetches but cannot fail. It gets a failure mode so the offline fallback is testable.
    - No `ARCHITECTURE.md` in the repo, so there is nothing to reconcile.
  timestamp: 2026-08-28T03:24:01.726958+00:00
- actor: claude-code
  id: 01m136svhgvcaapyr98cvgkx94
  text: |-
    Implementation landed, TDD order kept.

    RED first. The new tests failed 7 times against the old cache-first order: the 5 moving-revision cases, the offline fallback, and the cache-update test. Then the code made them pass.

    What changed in `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`:
    - `RepoMetadataReader.revisionCanMove(_:)` classifies the revision. It returns `false` only for a revision of `commitHashLength` (40) characters, each of them in `commitHashCharacters` (lowercase hex).
    - `metadata(for:)` now dispatches on that: `pinnedMetadata(for:)` keeps the old cache-first order; `refreshedMetadata(for:)` fetches first, and reads the cache only when the fetch throws.
    - `parseAndCache(_:for:)` holds the parse and the cache write that both paths share.
    - The fallback logs through a new file-level `repoMetadataReaderLogger`, at `notice`. An offline machine is a normal condition, not an error.
    - Doc comments on `RepoMetadataReader` and `RepoMetadataCache` state the rule.

    Only the fetch call sits inside the `do`, as the card says. A parse failure after a good fetch throws; it does not fall back.

    Interesting points for the next agent:
    - Three existing tests pinned the old order with revisions that are not commit hashes. They now use real 40-character hashes, which keeps what each one tests: `commitPinnedReferenceFetchesOnce` (was `cacheHitFetchesOnce`), `cacheKeySeparation`, and `metadataReFetchesOnStaleSchemaCacheEntry`.
    - The `magic-numbers-swift` validator reports a numeric literal in a call argument. The first version of `movingRevisionUpdatesTheCache` built its stale entry with `RepoMetadata(numHiddenLayers: 4, ...)`, which would have reported. It now writes a JSON fixture, `movedPastCacheJSON`, and follows the pattern `staleSchemaCacheJSON` already set in this file.
    - The classifier was proved by an experiment, not by reading: with `revisionCanMove` forced to `false`, `movingRevisionUpdatesTheCache` fails on `metadata.weightBytes`. The file was restored after.
  timestamp: 2026-08-28T03:32:19.120477+00:00
- actor: claude-code
  id: 01m136tdhrnsmf1tb765a8y2wp
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift, Tests/FoundationModelsRouterTests/RepoMetadataTests.swift. `swift build` complete. `swift test`: 1069 tests in 108 suites passed with the 2 known issues the baseline also has, plus 83 eval tests passed. The baseline on a stashed tree is 1065 tests, 2 known issues, 83 eval tests, so there is no new failure.
    - next: /review
  timestamp: 2026-08-28T03:32:37.560449+00:00
- actor: claude-code
  id: 01m13735ywkya8mz5v20tef9yk
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit aec0218). 0 findings from 7 validator runs, 0 failed. 2 files reviewed: Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift and Tests/FoundationModelsRouterTests/RepoMetadataTests.swift. All items in the description are marked done.
    - next: none. The task moved to the done column.
  timestamp: 2026-08-28T03:37:24.700647+00:00
- actor: claude-code
  id: 01m1373p9aeaaxzhxa7naazr9e
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files (Sizing/RepoMetadata.swift, RepoMetadataTests.swift)
    - test: green — swift test, 1069 tests in 108 suites passed, plus 83 eval tests; baseline was 1065 with the same 2 known issues
    - commit: aec0218
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted, 0 failed
    - next: none — the task is in done
  timestamp: 2026-08-28T03:37:41.418839+00:00
position_column: done
position_ordinal: ffff9180
title: Stop RepoMetadataCache from serving stale metadata for moving revisions
---
## What

`RepoMetadataReader.metadata(for:)` (Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:349) reads the cache first for every reference. A reference with a `nil` revision, a branch, or a tag is mutable on the Hub, so a cached entry can pin stale sizing metadata forever. Only a full commit hash is immutable.

Change the read order by revision kind:

- Add a private helper that classifies a revision: immutable when it is a full 40-character lowercase hex commit id; mutable for `nil`, a branch, or a tag.
- Immutable revision: keep the current order. Read the cache first; fetch and save on a miss.
- Mutable revision: fetch first. On success, parse, save to the cache, and return. On a fetch failure, load the cached entry; if one exists, log the fallback and return it. If none exists, throw the fetch error.
- The offline case must keep working: a machine that resolved once and then lost the network still resolves, from the fallback read.
- Update the doc comments on `RepoMetadataReader` and `RepoMetadataCache` (lines 326-343 and 370-374) to state the rule.

## Acceptance Criteria
- [x] A reference pinned to a commit hash never refetches after the first fetch.
- [x] A reference with a `nil`, branch, or tag revision fetches on each call and updates the cache.
- [x] A mutable-revision fetch failure returns the cached entry when one exists, with a log line.
- [x] A mutable-revision fetch failure with no cached entry throws the fetch error.

## Tests
- [x] Extend `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift` with a counting stub `MetadataSource`.
- [x] Assert each acceptance criterion above with the stub: fetch counts, cache updates, the offline fallback, and the no-entry throw.
- [x] Run `swift test`. All tests pass.

## Workflow
- [x] Use `/tdd` — write failing tests first, then implement to make them pass. #router #cleanup