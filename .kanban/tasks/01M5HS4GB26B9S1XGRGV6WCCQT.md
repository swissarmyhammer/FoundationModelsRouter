---
assignees:
- claude-code
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