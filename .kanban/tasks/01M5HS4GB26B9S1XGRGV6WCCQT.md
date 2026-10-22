---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5j2y7wfsxn3r5dcayt1sye8
  text: 'Owned by the Extras session: Extras board card 01M5J2XR7WFPCA2702K78MQP3H. Closes when it lands and Router''s pin is bumped.'
  timestamp: 2026-10-22T15:16:12.303808+00:00
- actor: wballard
  id: 01m5j8n5ft2c4qy8vre1qe58hy
  text: |-
    Landed in Extras: 41c8ca2, on origin/main at 827bdae.
    - API: save(to:) and rendered() take Encodable metadata; errors are FrontmatterDocumentSaveError.
    - How it saves: hidden temp file in the same folder, fsync, atomic rename; keeps the existing file's permissions and follows a symlink.
    - Limits: the folder is not fsynced after the rename; a document decoded as the default YAMLValue can't be saved (not Encodable).
    Closes when Router's pin is bumped (after ^s9dftdp, so its build isn't disturbed).
  timestamp: 2026-10-22T16:56:06.394396+00:00
position_column: todo
position_ordinal: '9680'
title: 'EXTRAS: FrontmatterDocument save — write to a temp file and swap into place by default'
---
## What
FoundationModelsExtras' `FrontmatterDocument` can split and read markdown with frontmatter, but has no save. Add one. User decision (2026-10-22): the save by default writes to a temp file in the same folder and swaps it into place, so a reader never sees a half-written file.
- Encode `Encodable` metadata as YAML frontmatter, with the internal Yams; no Yams type in the public API. Write the body after it unchanged.
- Reading back gives the same metadata and the exact same body.

## Subtasks
- [ ] Render: metadata to `---` YAML `---`, then the body
- [ ] `save(to:)`: temp file in the same directory, then an atomic replace
- [ ] Failing tests first: round trip of metadata and body (multiline strings, dates, sets, nil); a body with `---` lines survives; no temp file left after the save; a failed save leaves the old file whole
- [ ] `swift test` passes, zero warnings #cross-repo #recording