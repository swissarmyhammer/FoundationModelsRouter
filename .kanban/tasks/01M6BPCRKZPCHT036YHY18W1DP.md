---
comments:
- actor: claude-code
  id: 01m6c0dx2ck40vcy416g6xn4mw
  text: |-
    ### implement - changed
    - Extras updated to 77c41b1 (swift package --manifest-cache local update FoundationModelsExtras, repo sourcekit-lsp stopped first).
    - Design: LocalModelPath (Core/LocalModelPath.swift) decides local by the form of the repo string: starts with /, ~ or ./. A Hub id never has these forms, so the two stay apart. The router changes ~ and ./ to an absolute path in Router.resolve (ProfileDefinition.resolvingLocalModelPaths), then Extras sees an existing directory and loads it.
    - Sizing: RepoMetadataReader.metadata(for:) reads a local folder with RepoMetadata(localDirectory:) (Sizing/LocalRepoMetadata.swift). No Hub call, no cache. Format = HubModelFormat.detect(paths:) on the TOP-LEVEL names, the same input Extras HubModelLoader.format(of:) uses, so router and loader agree. Weight bytes use the same rules as a Hub tree (largest .mlpackage for Core ML, root *.safetensors for MLX); symlinks are followed (Hub snapshot folders hold links). RepoMetadata.init(raw:) was split so that both paths share init(entries:format:configJSON:repo:).
    - Not done on purpose: ~user forms are not local; they stay Hub-like. A plain relative name is a Hub id even when a folder of that name exists (Extras alone would treat it as local; that is Extras behaviour).
    - Tests: LocalModelPathTests, LocalRepoMetadataTests, ResolveLocalModelTests (+ TempModelFolder helper). ~ and ./ are tested with injected home and working folders.
    - Docs: README section "Local models"; docs/ane-embedding.md section "A model in a local folder".
    - Full suite once: 2222 tests in 272 suites passed. The only warning in the build output is the existing "missing creator for mutated node" build-system line.

    step: implement
    outcome: changed
    evidence: 13 files - Sources/FoundationModelsRouter/{Router.swift,Core/LocalModelPath.swift,Sizing/RepoMetadata.swift,Sizing/LocalRepoMetadata.swift}, Tests/FoundationModelsRouterTests/{LocalModelPathTests,LocalRepoMetadataTests,ResolveLocalModelTests,TempModelFolder}.swift, README.md, docs/ane-embedding.md; swift test: 2222 tests passed
    task: ^y18w1dp
  timestamp: 2026-11-01T16:52:35.020517+00:00
- actor: claude-code
  id: 01m6c0qj545zd0gpnm2ddpy1vb
  text: |-
    ### review - findings
    - evidence: review sha HEAD~1..HEAD; 5 findings, 5 confirmed, 2 refuted. LocalModelPath.swift:46, :79, :99; ResolveLocalModelTests.swift:15, :28.
    - next: implementer fixes all 5 items and checks the boxes. Task stays in review.
  timestamp: 2026-11-01T16:57:51.524286+00:00
- actor: claude-code
  id: 01m6c0trhvkrm3101fj556yymq
  text: |-
    ### implement - changed (review fixes)
    - LocalModelPath: the default home and working folder are now two static members (defaultHome, defaultWorkingDirectory); all three functions use them.
    - ResolveLocalModelTests: removed the private container, probe and metadata copies; the suite uses the shared BasicLLMContainer, StubEmbeddingContainer, RouterTestFixtures.stubProbe and RouterTestFixtures.rawMetadata. The two recording stubs stay, because they add recording that no shared stub has.
    - Ran only LocalModelPathTests, LocalRepoMetadataTests, ResolveLocalModelTests: 25 tests passed.

    step: implement
    outcome: changed
    evidence: 2 files - Sources/FoundationModelsRouter/Core/LocalModelPath.swift, Tests/FoundationModelsRouterTests/ResolveLocalModelTests.swift; 25 tests in 3 suites passed; 5 of 5 findings checked
    task: ^y18w1dp
  timestamp: 2026-11-01T16:59:36.379668+00:00
- actor: claude-code
  id: 01m6c0whzqxjv31efywdtdqsbh
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 22f63923), 0 findings, 7 checks attempted, 0 failed. All prior findings are checked.
    - next: none. Task moved to done.
  timestamp: 2026-11-01T17:00:35.191336+00:00
position_column: done
position_ordinal: ffffffffda80
title: ModelRef accepts a local model path
---
The agent config must take a local path as a model reference, and the format (CoreML or MLX) is found by itself. ModelRef parses owner/name@revision only. Let ModelRef hold a local directory path (an absolute path, or a path that starts with ~ or ./) and keep it apart from a Hub repo id. Pass the path to the Extras loader. Depends on Extras card ^3mnxzqf (HubModelLoader detects the model format from a local path). Related Router card ^zpcsp86 (LiveModelLoader uses HubModelLoader). The ACP agent card in FoundationModelsACPAgent waits for these cards.

## Review Findings (2026-11-01 10:53)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified.

- [x] `Sources/FoundationModelsRouter/Core/LocalModelPath.swift:46` `duplication/duplication` — The default `workingDirectory` expression `URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)` is copied verbatim into three functions in this file. The matching `home` default is copied the same way. A later change to either default must be made in three places, or the functions will disagree. Move both defaults into one place, such as `private static var defaultHome: URL` and `private static var defaultWorkingDirectory: URL` on LocalModelPath, and use them as the default values in all three functions.
- [x] `Sources/FoundationModelsRouter/Core/LocalModelPath.swift:79` `duplication/duplication` — The default `workingDirectory` argument is repeated here. It is the same copy as in `directory(of:)`, so it can drift out of sync with the other copies. Use one shared default, as described for line 46, and remove this copy.
- [x] `Sources/FoundationModelsRouter/Core/LocalModelPath.swift:99` `duplication/duplication` — The default `workingDirectory` argument is repeated here. It is the same copy as in `directory(of:)` and `resolved(_:)`, so it can drift out of sync with the other copies. Use one shared default, as described for line 46, and remove this copy.
- [x] `Tests/FoundationModelsRouterTests/ResolveLocalModelTests.swift:15` `reuse/reuse` — StubLLMContainer repeats a stub generation container that already exists in other test files. Its behavior is identical, so a new copy adds maintenance without adding coverage. Move the stub into Tests/FoundationModelsRouterTests/Helpers and use it from this suite, or use the existing shared stub.
- [x] `Tests/FoundationModelsRouterTests/ResolveLocalModelTests.swift:28` `reuse/reuse` — StubEmbeddingContainer repeats an embedding stub that already exists in several test files. Its embed behavior is the same, so the copy duplicates an existing capability. Use one shared embedding stub from the Helpers folder for this suite instead of defining a private copy.
