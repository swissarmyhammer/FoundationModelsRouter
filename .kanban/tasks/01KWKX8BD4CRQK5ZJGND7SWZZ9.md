---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Add tests for HuggingFaceMetadataSource against a mocked URLSession
---
Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:336-390 (`HuggingFaceMetadataSource.fetchRawMetadata` / `optionalData`)

Coverage: 0% for this struct — uncovered lines 366-375, 383-389.

`HuggingFaceMetadataSource` is the live `MetadataSource` implementation. Its constructor already takes an injectable `session: URLSession = .shared` specifically so it can be pointed at a fake session — unlike `LiveModelLoader` (real MLX/GPU/multi-GB downloads, rightly left to the gated integration suite), this is two small HTTP GETs whose logic (URL construction, and mapping an HTTP 404 to `configJSON == nil` vs. surfacing other errors) is pure routing logic that does not need real network access.

Add a test (e.g. in RepoMetadataTests.swift or a new file) that constructs `HuggingFaceMetadataSource(endpoint:session:)` with a `URLSession` configured with a custom `URLProtocol` subclass that returns canned responses, and verifies:
- A 404 response for `config.json` → `RawRepoMetadata.configJSON == nil`, `treeJSON` still populated from the tree response.
- A 200 response for `config.json` → `configJSON` populated with the response bytes.
- The requested URLs match the expected shape: `{endpoint}/{repo}/resolve/{rev}/config.json` and `{endpoint}/api/models/{repo}/tree/{rev}`, including the `revision ?? "main"` default-revision fallback.
- A non-404 transport error (e.g. 500, or a thrown `URLError`) propagates rather than being swallowed.