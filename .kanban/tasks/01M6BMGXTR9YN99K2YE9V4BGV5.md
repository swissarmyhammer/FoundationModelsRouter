---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Detect a CoreML embedding model in the router
---
Report from the repo metadata if a ref is a CoreML (ANE) embedding model. Use the Extras detection when it exposes one. Do not write a second detector. Make resolution of the embedding slot use this check. Add unit tests. Depends on the Extras tasks for ANE embedding support (foundationmodelsextras-47 will send the API names).