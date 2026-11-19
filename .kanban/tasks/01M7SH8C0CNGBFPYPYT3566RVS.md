---
assignees:
- claude-code
depends_on:
- 01M7S16CT48HZ95JXCKH3XTEKZ
position_column: todo
position_ordinal: '80'
title: The record keeps lastSummary, recap and recapAt, and each summary gives them (D206)
---
## Goal

The session facts keep the last summary (ROUTER-9) and the recap (D206), so a recorded session gives them after a restart. Decision D206 (`TestudoApp/features/decisions.md`, commit da60a90). Brief: `../.briefs/recap/router-brief.md` items 1, 4 and 6; overview `overview.md`.

## Depends on

FoundationModelsExtras: `SessionSummary.recap` and `recapAt`. Do not start before Extras sends the D206 sha. Update the pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo). The dependency on ^h3xtekz is only the order of work.

## Current behavior

- `SessionStateTracking` keeps the last final reply cut to 500 characters, in memory only (`Sources/FoundationModelsRouter/Directory/SessionStateTracking.swift:41`, `:90`).
- `recordState(after:of:)` (`Directory/RouterSessionDirectory.swift:3644-3660`); the live summary gives `lastSummary` (`:700-722`, `:718`).
- `SessionFacts` has no summary (`Recording/SessionFacts.swift:16-46`); keys `Recording/SessionRecord.swift:266`, decode `:318`, encode `:365`.
- A recorded session gives no last summary (`Directory/RecordedSessions.swift:123-141`).

## Change

- Add `lastSummary`, `recap` and `recapAt` to `SessionFacts`, with coding keys in the record. A missing key decodes as `nil`.
- Write `lastSummary` with the record at the end of each turn that changed it.
- `RecordedSessions.summary(of:)` and the live summary give all three (`SessionSummary.lastSummary`, `.recap`, `.recapAt`).
- A fork starts with no `recap` and no `lastSummary` (the fork facts copy neither).
- Update the type doc of `SessionStateTracking` and of the directory (ROUTER-9) to name D206.

## Tests

- [ ] A turn writes `lastSummary` to the record; a restart gives it in the recorded summary.
- [ ] `recap` and `recapAt` written to the facts are in the live and the recorded summary, and after a restart.
- [ ] An old record with no such keys decodes, with `nil`.
- [ ] A fork has no `recap` and no `lastSummary`.

## After

Push when green. Send the sha to foundationmodelsmultitool-89, foundationmodelsacpagent-9e and testudoapp-9a. #d206