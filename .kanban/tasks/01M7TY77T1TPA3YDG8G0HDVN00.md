---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tykr3am309300g6pphe01m
  text: |-
    Unblocked: Extras D209 is on origin/main at 4f3afb5 (code commit f3e7cfe), from foundationmodelsextras-9e on 2026-11-19.
    - `SessionDirectoryOrigin.import` (raw "import"); `SessionImportProvenance` (`agent`, `sourceID`, `sourcePath`, `sourceLastDate: Date?`, `importedAt`, `skippedRecordCount`; Codable); `SessionSummary.importedFrom` (default nil); `SessionImportRequest` (`agentID: String?`, `workingDirectory: URL`, `title: String`, `provenance`, `startedBy: ULID?`).
    - `SessionDirectory.importSession(_ request: SessionImportRequest, transcript: Transcript) async throws -> SessionSummary`, with a default that throws `SessionDirectoryError.importUnsupported` (the Router compiles before this task).
    - Name rule of the in-memory directory: the title as given when its slug is free in the folder, else `<slug>-2`, `-3` (`SessionName.default`). Match it.
    - Orchestrator decision on the event: the Router sends `factsChanged` with the summary of the new imported session (no new event case), so the change feed shows it. Extras aligns its in-memory directory and doc.
    Update the pin after ^mdhq7rh ends, with `swift package --manifest-cache local update FoundationModelsExtras`.
  timestamp: 2026-11-19T22:25:07.690133+00:00
depends_on:
- 01M7TY6VQ8MK2NV6ADXMDHQ7RH
position_column: todo
position_ordinal: '8180'
title: 'The session directory imports a session: importSession, the importedFrom fact, and the name (D209 (h), part 2)'
---
## Goal

`RouterSessionDirectory` implements `importSession` of Extras with the writer of part 1. The imported session is a recorded root session that is not live, with the origin `import` and its provenance. Decision D209 (h) (`TestudoApp/features/decisions.md`, commit 56a8a59). Brief: `../.briefs/import/router-brief.md` items 2 and 3; overview `overview.md`.

## Depends on

- Part 1 (the writer).
- FoundationModelsExtras D209: `SessionImportRequest`, `SessionImportProvenance`, `SessionDirectoryOrigin.import`, `SessionSummary.importedFrom`, and `importSession(_:transcript:)` on `SessionDirectory` (`extras-brief.md`). Do not start before Extras sends the sha. Update the pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo). If the Extras protocol requirement has no default, the Router does not compile until this task: do it first when the sha comes.

## Change

1. `SessionFacts.importedFrom: SessionImportProvenance?`, written flat in the frontmatter as `importedFrom`. An old `index.md` with no key reads as `nil`. `SessionSummary(record:)` (^abrxfy5) gives `importedFrom` from the facts.
2. `RouterSessionDirectory.importSession(_:transcript:)`: write the recording with the writer (origin `import`, the provenance), then add the session to the directory as a recorded session that is not live. The name follows D199 (b) with the title of the request: the directory applies only the next free number among the sessions of the folder that are not archived (the ACPAgent gives the base name). Each import makes a new session (Q85 (c)).
3. Send the directory event that a new recorded session gives (as for the other paths that add a session), so the change feed shows it.

## Tests

- [ ] An import writes a recording that restores; the summary is a `root` with origin `import`, and `importedFrom` reads back (also after a restart).
- [ ] `list` of the directory shows the session with the name; a second import with the same title gets the next free number.
- [ ] An old `index.md` with no `importedFrom` reads as nil.
- [ ] A failed write leaves no folder and no directory entry.

## After

Push when green. Send the sha to foundationmodelsacpagent-9e and testudoapp-9a. #d209