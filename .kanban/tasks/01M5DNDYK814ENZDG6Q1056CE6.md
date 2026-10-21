---
comments:
- actor: wballard
  id: 01m5e1emb84f1mjq75r17mm7dj
  text: |-
    ### Extras is ready
    - FoundationModelsExtras 6670bc0 is pushed. It has `MLXModelLoader.init(cacheDirectory: URL? = nil, tokenizerLoader: (any TokenizerLoader)? = nil)`.
    - With a folder, the download, `weightsLocation` and `footprintBytes` use that folder. With nil, the loader uses `HubCache.default`.
    - Router work: add `cacheDirectory: URL? = nil` to the public `LiveModelLoader` init, and give it to `MLXModelLoader(cacheDirectory:)`. The default init calls `MLXModelLoader()` at LiveModelLoader.swift:985.
    - After the push, send the sha to FoundationModelsACPAgent for card ^8c4f0pa.
  timestamp: 2026-10-21T01:33:14.472978+00:00
- actor: wballard
  id: 01m5e7f3n5svz8yb1ag3ywfjfx
  text: 'Research: (1) Package.resolved now pins FoundationModelsExtras to 6670bc0 (main). The file is in .gitignore, thus no tracked diff. (2) MLXModelLoader(cacheDirectory:tokenizerLoader:) is public in 6670bc0. A given folder is the download folder, the weights folder and the footprint folder, also when HF_HUB_CACHE or HF_HOME names a different folder. The Extras tests prove the HF_HOME part. (3) Router.init(cacheDir:) is public already. It keeps only the sizing metadata (RepoMetadataReader). No Router code reads the Hugging Face cache, thus a host gives the two folders separately: Router(cacheDir:) for the metadata, LiveModelLoader(cacheDirectory:) for the models. (4) LiveModelLoader does not forward footprintBytes(of:) to its model loader. An Extras pool that loads through a LiveModelLoader measures 0 bytes. The Router path does not use that measure (SlotPoolLoader gives footprintBytes to admission.acquire). This is out of scope. A separate card records it. Plan: add cacheDirectory: URL? = nil to the public init, give it to MLXModelLoader(cacheDirectory:), make modelLoader internal for @testable access, test with a fake snapshot in a temporary folder, add a public-surface compile proof.'
  timestamp: 2026-10-21T03:18:21.605509+00:00
- actor: wballard
  id: 01m5e7rqa26t4m4qba6v1f81pn
  text: |-
    ### implement — changed
    - evidence: 4 files. Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift (public init(reporting:cacheDirectory:) gives the folder to MLXModelLoader(cacheDirectory:); modelLoader is internal for @testable access; the doc tells that Router(cacheDir:) takes the sizing metadata folder). README.md (one paragraph on the two folders). New Tests/FoundationModelsRouterTests/LiveModelLoaderCacheFolderTests.swift (2 tests: a given folder is measured also when HF_HUB_CACHE and HF_HOME name a different folder; no folder does not read a temporary snapshot). New Tests/FoundationModelsRouterPublicSurfaceTests/LiveModelLoaderPublicSurfaceTests.swift (plain-import compile proof; the init writes nothing into the folder).
    - RED: compile failure, extra argument cacheDirectory. Mutation check: with MLXModelLoader() in place of MLXModelLoader(cacheDirectory:), the HF_HOME test fails (it measures the environment folder).
    - swift build: Build complete, no warning from the package sources. swift test: 1922 tests in 238 suites passed (9 known issues, all withKnownIssue that existed before), 27 public-surface tests passed, 19 eval tests passed.
    - Router.init(cacheDir:) is public already and the live loader does not use it. No change was necessary there.
    - New card ^5pdsy5g: LiveModelLoader does not forward footprintBytes(of:) to its model loader.
    - next: review. Not committed, not pushed.
  timestamp: 2026-10-21T03:23:36.642245+00:00
- actor: wballard
  id: 01m5e7tzakjwzk251xhjfpxd5k
  text: |-
    ### review — stuck
    - evidence: The review engine did not run. The `review` MCP tool of the calling session is bound to FoundationModelsACPAgent. It cannot find commit 29142e7e ("revspec not found"). The `sah tool review sha review` CLI route has no agent and cannot run the review. The only other method is a second `sah serve` in FoundationModelsRouter. The user prohibits that method (memory "no-cross-repo-review": "do not review another repo").
    - blocker: The request from the FoundationModelsACPAgent session (review commit 29142e7e in this repository) conflicts with the rule of the user. A person must decide.
    - next: Run `/review 1056ce6 29142e7e~1..29142e7e` from a session that started in FoundationModelsRouter. Or, the user can accept the Router test suite as the proof and move this task to done.
  timestamp: 2026-10-21T03:24:50.387587+00:00
- actor: wballard
  id: 01m5ey38803ky55v8f68zer8zn
  text: |-
    ### finish iteration 1 — done
    - implement: changed — LiveModelLoader.swift, README.md, 2 new test files
    - test: green — swift test, 1922 passed (9 known issues from before), 27 public-surface and 19 eval passed
    - commit: 29142e7e
    - review: the engine cannot run on this repository from the ACPAgent session. The user accepted the green suite as the proof and told me to push (2026-10-21).
  timestamp: 2026-10-21T09:53:50.336502+00:00
position_column: done
position_ordinal: ffffffff9b80
title: A host gives the folder for live model downloads (LiveModelLoader)
---
## What
The TestudoApp app keeps each folder in Application Support, never in Caches or in the home folder (ACPA-16, D98). FoundationModelsACPAgent card ^8c4f0pa adds `modelCacheDirectory` to `ComposedAgent.compose`, but ACPAgent cannot give the folder that the live model source downloads to:

- `ComposedAgent.makeRouter` makes `Router(recordingsDir:loader: LiveModelLoader(), hooks:)`.
- `LiveModelLoader.init(reporting:)` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`) is the only public init, and it always uses `MLXModelLoader()`. `init(reporting:modelLoader:)` is `package`.
- In FoundationModelsExtras, `MLXModelLoader` downloads with `#hubDownloader()`, which uses `HubCache.default`, which reads `HF_HUB_CACHE`/`HF_HOME` from `ProcessInfo`. A separate request to the FoundationModelsExtras session asks for a public `MLXModelLoader` init that takes the hub cache folder.

Add a public way to give the folder, for example:

```swift
public init(reporting: ResolutionProgress? = nil, cacheDirectory: URL?)
```

that makes `MLXModelLoader(cacheDirectory:)` (the new Extras API). With nil, the behavior is the same as now. Or make `init(reporting:modelLoader:)` public.

Also note: `Router.init(cacheDir:)` keeps the sizing metadata in `<Caches>/FoundationModelsRouter` by default. Make sure a host can give that folder too, if the live path uses it.

## Acceptance Criteria
- [x] A host gives a folder, and a live download goes into that folder, also when `HF_HOME` is set to another folder.
- [x] With no folder, nothing changes.

## Tests
- [x] A test with a stub downloader or a temporary cache that proves which folder the loader uses.
- [x] `swift test` passes with zero failures and zero warnings.

## Requested by
The FoundationModelsACPAgent session, for its card ^8c4f0pa. The user told the session to work out stuck cards with the peer sessions (2026-10-20). Depends on the FoundationModelsExtras change.