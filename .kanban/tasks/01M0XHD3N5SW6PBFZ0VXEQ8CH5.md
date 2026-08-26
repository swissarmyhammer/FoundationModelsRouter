---
assignees:
- claude-code
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
- 01M0XGS4FFR5ATBWCME1PCH3EE
position_column: todo
position_ordinal: 8a80
title: Cut the doc-comment bloat across Router sources
---
## What
The `///` comments narrate essays — edge-case war stories, cross-references, and rationale that repeat the code. Cut them down across `Sources/FoundationModelsRouter/**`, with `Hosting/` and `Session/` first. The rule: a doc comment states the contract — what the symbol does, its parameters, what it returns, and only the constraints the code cannot show. No narration of history, no "(task ^xxxxx)" citations, no restated implementations. Target shape: most member doc comments fit in 1-5 lines; a type-level overview fits in one screen.

Run this AFTER the engine rework — do not polish text that ^bzekmfd deletes.

- [ ] Record the baseline first: `rg -c '^\s*///' Sources | awk -F: '{s+=$2} END {print s}'`.
- [ ] Pass over `Hosting/`, then `Session/`, then the rest.
- [ ] Keep DocC references that still resolve; delete the ones that pointed at removed symbols.

## Acceptance Criteria
- [ ] The total `///` line count in `Sources` is at most half the recorded baseline.
- [ ] No doc comment cites a kanban task id or a plan file.
- [ ] `swift build --build-tests` and the full suite are green.

## Tests
- [ ] No behavior change. Run `swift test` — green.

## Workflow
- Use `/tdd` — run the suite before and after each folder pass. #cleanup #docs