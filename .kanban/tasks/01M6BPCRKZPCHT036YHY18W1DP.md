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
position_column: doing
position_ordinal: '80'
title: ModelRef accepts a local model path
---
The agent config must take a local path as a model reference, and the format (CoreML or MLX) is found by itself. ModelRef parses owner/name@revision only. Let ModelRef hold a local directory path (an absolute path, or a path that starts with ~ or ./) and keep it apart from a Hub repo id. Pass the path to the Extras loader. Depends on Extras card ^3mnxzqf (HubModelLoader detects the model format from a local path). Related Router card ^zpcsp86 (LiveModelLoader uses HubModelLoader). The ACP agent card in FoundationModelsACPAgent waits for these cards.