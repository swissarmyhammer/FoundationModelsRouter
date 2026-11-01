---
position_column: todo
position_ordinal: '8580'
title: LiveModelLoader loads CoreML embedding models through HubModelLoader
---
The agent wants erjigit17/embeddinggemma-300m-ane-coreml as the default embedding model. LiveModelLoader now makes an MLXModelLoader only, so a CoreML model cannot load. Extras has HubModelLoader, which picks MLX or CoreML from the files of the repository. Make LiveModelLoader use HubModelLoader, with the same drafterRegistration, cacheDirectory and tokenProvider. An .llm key must still load with MLX. Add a test with a CoreML repository. Also check that RoutedEmbedder and the sizing of the embedding slot work for a CoreML package. Discuss with the owner before the change: this is a Router change that the ACP agent waits for.