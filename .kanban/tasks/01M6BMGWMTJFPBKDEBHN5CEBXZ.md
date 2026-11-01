---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Size a CoreML embedding repo in the router
---
Check that RepoMetadata and Footprint.embedder(weightBytes:) size a CoreML repo (.mlpackage or .mlmodelc files) correctly. Fix them if they do not. Decide how joint fit counts an ANE model against the memory budget. Add unit tests with stub repo metadata. Context: the default embedding model will be erjigit17/embeddinggemma-300m-ane-coreml. This task does not depend on the Extras API.