---
depends_on:
- 01M5J0J48N3D4539V5D57DTGHB
position_column: todo
position_ordinal: 9c80
title: 'ROUTER: host gives the Hugging Face token; Router shows its metadata cache folder'
---
## Goal
The router takes the Hugging Face token from the host, for both model downloads and sizing metadata, and shows the host its metadata cache folder. Requested by ACPAgent (AgentHome, f7f9932): a host with its own home must not depend on `~/.cache/huggingface/token`, and ACPAgent wants to test that the metadata cache follows its local home.

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: `public init(reporting:cacheDirectory:tokenProvider: TokenProvider = .environment)` passes it to `MLXModelLoader(cacheDirectory:tokenProvider:)` (Extras card ^d7dtghb, this card depends on it). Expose swift-huggingface's `TokenProvider` to Router's public API (add the product dependency if Router does not have it).
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`, `HuggingFaceMetadataSource`: `init(endpoint:session:tokenProvider: TokenProvider = .environment)`; each GET sends `Authorization: Bearer <token>` when the provider gives a token. Gated repos size today only by luck.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Router.swift`: a read-only `public nonisolated let cacheDirectory: URL`, the resolved metadata cache folder (`cacheDir` or the default under the user caches folder).

## Subtasks
- [ ] Failing test first: `HuggingFaceMetadataSource` with `.fixed(token: "t")` sends `Authorization: Bearer t` (URLProtocol stub); with `.none` it sends no header.
- [ ] `LiveModelLoader(tokenProvider:)` passes the provider to the Extras loader.
- [ ] `Router.cacheDirectory` returns the given `cacheDir`, and the default folder when none was given.
- [ ] Public surface test without `@testable` for the three.

## Acceptance Criteria
- [ ] A host can give one token provider to downloads and to sizing.
- [ ] A host can read the router's metadata cache folder.

## Tests
- [ ] `swift test` passes.

## Workflow
- Use `/tdd`. #hosting #router-api