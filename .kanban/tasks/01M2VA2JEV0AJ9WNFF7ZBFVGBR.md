---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A test doc comment names a restoreSessionTree signature that does not exist
---
## What

`Tests/FoundationModelsRouterTests/PerSessionRecordingRootTests.swift` has a doc link to `restoreSessionTree(root:recordingRoot:tools:)`. That signature does not exist. The real signature is `restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:)`.

## The work

1. Change the link in `PerSessionRecordingRootTests.swift` to the real signature.
2. Search the repository for other stale `restoreSessionTree(` and `restoreSession(` links, and correct each one.

## Where it was found

Found during `^ebftpem`, when the DocC links for the new `toolOutputProtection:` parameter were updated.