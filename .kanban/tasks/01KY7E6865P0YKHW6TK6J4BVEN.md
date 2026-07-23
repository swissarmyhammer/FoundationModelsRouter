---
position_column: todo
position_ordinal: '9680'
title: 'Session creation metadata: durable cwd + parent session id + parent ToolCallID'
---
Harness plan §7 creation-metadata ask. Record at session creation, alongside recording identity: the session's workingDirectory (so a caller restoring a stored session can reassemble its own side — config, AGENTS.md instructions, confinement: composition-layer concerns) and, when spawned from inside a parent turn (the agents tool), the parent session id + the parent's tool-call correlation id — so a transcript browser reconstructs the parent→child agent tree from recordings alone. Complements existing fork parentId lineage.