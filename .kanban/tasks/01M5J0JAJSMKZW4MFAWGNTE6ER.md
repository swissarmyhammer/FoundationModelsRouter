---
comments:
- actor: claude-code
  id: 01m5jn3pkpm2z7va2c1s5v1d9g
  text: 'Picked up. Research: Extras pin 447344d has `MLXModelLoader(cacheDirectory:tokenProvider:tokenizerLoader:)`; its internal `hubClient()` returns a swift-huggingface `HubClient` whose `bearerToken` reads the provider, so a unit test with `@testable import FoundationModelsExtras` can prove LiveModelLoader passes the provider on. Extras declares `.package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0")`, product `HuggingFace`; Package.resolved already holds 0.13.0. The `MockURLProtocol` stub of HuggingFaceMetadataSourceTests is private to that file with one global handler slot; the public-surface target needs the same stub, so it moves to FoundationModelsRouterTestSupport keyed by host (so suites in two targets never share a slot). `Router.init` already resolves `cacheDir ?? defaultCacheDir()` into a local; it becomes the stored `cacheDirectory`.'
  timestamp: 2026-10-22T20:33:45.590941+00:00
- actor: claude-code
  id: 01m5jnj2tz207expa0jjpqjy0s
  text: 'Implementation landed (TDD). RED 1: compile failure, `Router` has no member `cacheDirectory`. RED 2 (params accepted, behavior absent): the fixed-token header tests (unit + public surface) failed with no Authorization header, and `LiveModelLoaderTokenProviderTests` failed with `bearerToken != "host-token"`; the `.none` tests passed as expected. GREEN after: `HuggingFaceMetadataSource` stores the provider, reads `getToken()` once per fetch and sends `Authorization: Bearer <token>` on both GETs (`URLRequest` + `session.data(for:)`); `LiveModelLoader` passes the provider to `MLXModelLoader(cacheDirectory:tokenProvider:)`; `Router.cacheDirectory` stores `cacheDir ?? defaultCacheDir()` and feeds the metadata reader. Package.swift: `swift-huggingface` from 0.9.0 (same URL/requirement as Extras), product `HuggingFace` on the library, the unit test target and the public-surface target; the public-surface target also links TestSupport. Test infra: the private `MockURLProtocol`/`RequestRecorder` of HuggingFaceMetadataSourceTests moved to `Tests/FoundationModelsRouterTestSupport/StubURLProtocol.swift` as public `StubURLProtocol` (one handler per host, `Mutex`) and `RequestRecorder` (records `URLRequest`s), so the unit suite and the public-surface suite share one stub without sharing a handler slot. Existing unit metadata-source tests now default to `.none` so no test reads the user''s real token. The duplicated `mlxLoader(of:)` helper became `LiveModelLoader.requireMLXModelLoader()` in `LiveModelLoaderMLXModelLoader.swift`. README documents `Router.cacheDirectory` and the shared `TokenProvider`. Note: the `missing creator for mutated node ... mlx-swift_Cmlx.bundle` build warning and the 9 known issues predate this change (seen in earlier shell history).'
  timestamp: 2026-10-22T20:41:36.863568+00:00
- actor: claude-code
  id: 01m5jnj790kmqa5xhkrvvdkbqe
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean (only the pre-existing mlx bundle build-system warning); `swift test`: 2143 tests / 262 suites passed (9 pre-existing known issues), 39 tests / 23 suites passed, 19 tests / 3 suites passed. 12 files — Package.swift, README.md, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift, Tests/FoundationModelsRouterTestSupport/StubURLProtocol.swift (new), Tests/FoundationModelsRouterTests/HuggingFaceMetadataSourceTests.swift, Tests/FoundationModelsRouterTests/LiveModelLoaderTokenProviderTests.swift (new), Tests/FoundationModelsRouterTests/LiveModelLoaderMLXModelLoader.swift (new), Tests/FoundationModelsRouterTests/LiveModelLoaderCacheFolderTests.swift, Tests/FoundationModelsRouterPublicSurfaceTests/HostTokenPublicSurfaceTests.swift (new), Tests/FoundationModelsRouterPublicSurfaceTests/RouterCacheDirectoryPublicSurfaceTests.swift (new)
    - next: /review
  timestamp: 2026-10-22T20:41:41.408135+00:00
- actor: claude-code
  id: 01m5jnwq5hfzp2m8rjey9mb1gc
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (7c42e271): 0 findings, 0 confirmed, 0 refuted; 14 attempted, 0 failed; 11 files reviewed; not reviewed: .kanban/ (2, .reviewignore), README.md (no validator matches)
    - next: done
  timestamp: 2026-10-22T20:47:25.361605+00:00
- actor: wballard
  id: 01m5jnxn9hnb0a44ds7jz8qg46
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — tokenProvider on LiveModelLoader and HuggingFaceMetadataSource; Router.cacheDirectory; direct swift-huggingface dependency
    - test: green per implementer — swift test 2143 passed, 9 known issues
    - commit: 7c42e271
    - review: clean — 0 findings; card in done
  timestamp: 2026-10-22T20:47:56.209221+00:00
depends_on:
- 01M5J0J48N3D4539V5D57DTGHB
position_column: done
position_ordinal: ffffffffbb80
title: 'ROUTER: host gives the Hugging Face token; Router shows its metadata cache folder'
---
## Goal
The router takes the Hugging Face token from the host, for both model downloads and sizing metadata, and shows the host its metadata cache folder. Requested by ACPAgent (AgentHome, f7f9932): a host with its own home must not depend on `~/.cache/huggingface/token`, and ACPAgent wants to test that the metadata cache follows its local home.

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`: `public init(reporting:cacheDirectory:tokenProvider: TokenProvider = .environment)` passes it to `MLXModelLoader(cacheDirectory:tokenProvider:)` (Extras card ^d7dtghb, this card depends on it). Expose swift-huggingface's `TokenProvider` to Router's public API (add the product dependency if Router does not have it).
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`, `HuggingFaceMetadataSource`: `init(endpoint:session:tokenProvider: TokenProvider = .environment)`; each GET sends `Authorization: Bearer <token>` when the provider gives a token. Gated repos size today only by luck.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Router.swift`: a read-only `public nonisolated let cacheDirectory: URL`, the resolved metadata cache folder (`cacheDir` or the default under the user caches folder).

## Subtasks
- [x] Failing test first: `HuggingFaceMetadataSource` with `.fixed(token: "t")` sends `Authorization: Bearer t` (URLProtocol stub); with `.none` it sends no header.
- [x] `LiveModelLoader(tokenProvider:)` passes the provider to the Extras loader.
- [x] `Router.cacheDirectory` returns the given `cacheDir`, and the default folder when none was given.
- [x] Public surface test without `@testable` for the three.

## Acceptance Criteria
- [x] A host can give one token provider to downloads and to sizing.
- [x] A host can read the router's metadata cache folder.

## Tests
- [x] `swift test` passes.

## Workflow
- Use `/tdd`. #hosting #router-api