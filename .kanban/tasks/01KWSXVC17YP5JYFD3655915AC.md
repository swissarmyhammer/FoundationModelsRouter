---
comments:
- actor: claude-code
  id: 01kwsy85m1xdw0kcv6812nfjpg
  text: |-
    Implemented the fix in Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:

    - RepoMetadataCache.load(repo:revision:) now wraps the JSONDecoder().decode(RepoMetadata.self, ...) call in a do/catch. Any decode failure (stale schema like the missing numFullAttentionLayers key, or genuine corruption) logs a diagnostic via a new `repoMetadataCacheLogger` (os.Logger, subsystem moduleName, category "RepoMetadataCache") and returns nil — a clean cache miss — instead of throwing. A file-read failure (Data(contentsOf:) throwing, e.g. permissions/I-O) is untouched and still propagates, since that's not a decode problem.
    - RepoMetadataCache.fileURL(repo:revision:) changed from `private` to internal (no modifier) so tests in RepoMetadataTests.swift (same module, @testable import) can compute the exact on-disk cache path to pre-seed a stale-schema fixture at. RepoMetadataCache itself is already internal (non-public), so this doesn't broaden the public API surface.
    - No changes to the happy path: a current-schema cache hit still decodes and returns directly; the do/catch only changes behavior on decode failure.

    Added two tests to Tests/FoundationModelsRouterTests/RepoMetadataTests.swift:
    - `loadTreatsStaleSchemaEntryAsCacheMiss`: writes a pre-fix-schema JSON blob (missing numFullAttentionLayers) directly to the cache's computed fileURL, then asserts RepoMetadataCache.load returns nil.
    - `metadataReFetchesOnStaleSchemaCacheEntry`: seeds the same stale entry for a RepoMetadataReader's cache dir, then asserts reader.metadata(for:) re-fetches from the stub source (fetchCount == 1) and returns correct freshly-parsed metadata rather than throwing, and that a second read then hits the cache (fetchCount stays 1).

    TDD verified: reverted just the catch-block fix and confirmed both new tests failed with an uncaught DecodingError.keyNotFound (RED), then restored the fix and reran to green (GREEN).

    Full verification: `swift build` — 0 errors, 0 warnings. `swift test` — 164 tests passed across 21 suites (1 gated real-model integration test skipped as expected, unrelated to this change). LSP diagnostics check on the working tree: 0 errors, 0 warnings.

    Spawned the double-check adversarial reviewer per really-done; awaiting its verdict before final handoff. Task left in `doing` per /implement process — not moving to review myself.
  timestamp: 2026-07-05T20:06:53.825104+00:00
- actor: claude-code
  id: 01kwsyaw9213jchmkasgcb1k08
  text: |-
    Adversarial double-check (independent review) returned PASS, no findings. It independently confirmed: the do/catch in load only wraps the decode call (Data(contentsOf:) read failures still propagate unchanged); the stale-schema fixture genuinely omits numFullAttentionLayers (non-optional field) so it exercises a real DecodingError.keyNotFound, not a trivial/tautological case; fileURL's private→internal change is the minimal necessary visibility change (Swift's `private` is file-scoped even under @testable import) and has no other call sites; the cache-hit fast path is structurally unchanged; the new Logger matches Router.swift's manifestLogger convention exactly; RepoMetadataCache.load has a single caller (RepoMetadataReader.metadata(for:)), no other sizing/Router path is affected; and it independently reran swift build and swift test, reproducing the same 164 tests passed / 1 gated test skipped result.

    Task complete and green. Leaving in `doing` per /implement process for /review to pick up.
  timestamp: 2026-07-05T20:08:22.562688+00:00
position_column: done
position_ordinal: a480
title: Fix stale RepoMetadataCache entries breaking decode after numFullAttentionLayers field addition
---
## What
`RepoMetadata` (`Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`) recently gained a new, non-optional `numFullAttentionLayers: Int` field (to support hybrid linear/full-attention KV-cache accounting for models like Qwen3.5). `RepoMetadata` is `Codable` and `RepoMetadataCache` persists it to disk keyed by `(repo, revision)` (`RepoMetadataCache.save`/`.load`, hashed into `repo-metadata-<sha256>.json` under the cache dir).

Any cache entry written **before** this field existed lacks the `numFullAttentionLayers` key. `RepoMetadataCache.load(repo:revision:)` does a plain `JSONDecoder().decode(RepoMetadata.self, from: data)` with no migration/back-compat handling, so decoding a stale entry throws a `DecodingError.keyNotFound` instead of returning `nil` (a clean cache miss that would trigger a re-fetch).

That decode error then propagates up through `RepoMetadataReader.metadata(for:)` (which does `if let cached = try cache.load(...)`) and, at the resolver layer, appears to get generalized into a misleading **"metadata unavailable"** failure — masking the real cause (a stale/incompatible cache entry) behind what looks like a genuine sizing-metadata problem with the repo itself.

### How this was found
Discovered on 2026-07-05 while retrying `mlx-community/Qwen3.5-2B-mxfp4` as the gated integration suite's test model in the sibling `FoundationModelsMultitool` repo (kanban task `exbtj1n`) — a `CLISmokeTests` run intermittently hit a confusing "metadata unavailable" resolution failure that a fresh cache directory (clearing `~/Library/Caches/FoundationModelsRouter`) made disappear, isolating it to a stale on-disk cache entry rather than the model/config itself.

## Acceptance Criteria
- [ ] `RepoMetadataCache.load` treats a decode failure caused by a missing/changed schema as a cache miss (return `nil`, triggering a clean re-fetch) rather than throwing and surfacing as "metadata unavailable" — OR the cache is versioned/invalidated so old entries are never handed to a decoder that expects the new schema (e.g. a schema-version tag in the cache filename or payload, bumped whenever `RepoMetadata`'s `Codable` shape changes).
- [ ] A decode failure for a genuinely corrupt/unreadable cache file still surfaces distinctly from a normal cache miss vs. don't silently swallow real corruption forever — use judgment on the right balance (e.g. log a diagnostic on the fallback-to-refetch path).
- [ ] No regression to the existing cache-hit fast path when entries are already in the current schema.

## Tests
- [ ] Unit test: `RepoMetadataCache.load` given a cached JSON file missing `numFullAttentionLayers` (i.e. the pre-fix schema) returns `nil` instead of throwing.
- [ ] Unit test: `RepoMetadataReader.metadata(for:)` given the same stale cache entry re-fetches from the source and re-caches successfully, rather than throwing "metadata unavailable".
- [ ] Existing `RepoMetadata`/`RepoMetadataCache` test suite remains green.
