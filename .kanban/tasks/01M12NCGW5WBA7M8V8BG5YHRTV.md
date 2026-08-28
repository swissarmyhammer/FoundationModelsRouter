---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
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
- [ ] A reference pinned to a commit hash never refetches after the first fetch.
- [ ] A reference with a `nil`, branch, or tag revision fetches on each call and updates the cache.
- [ ] A mutable-revision fetch failure returns the cached entry when one exists, with a log line.
- [ ] A mutable-revision fetch failure with no cached entry throws the fetch error.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift` with a counting stub `MetadataSource`.
- [ ] Assert each acceptance criterion above with the stub: fetch counts, cache updates, the offline fallback, and the no-entry throw.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #cleanup