---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Use a CoreML embedding model through the router
---
Make LiveModelLoader and PooledEmbeddingContainer accept the new Extras CoreML container. Keep the embed span attributes (model.ref, embedding.dimension). Add a unit test with a stub container. Add a gated real-model test in IntegrationTests. Depends on the Extras CoreML container task.