---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ebyw32qggcq79f9405a1tn
  text: 'Research: I searched the repository for references before the deletion. `rg -l --hidden "docs/Usage|Usage\.md" --glob ''!.build'' --glob ''!.kanban'' --glob ''!.git'' .` found no match. A wider search for `docs/` (hidden files included, thus `.github/` CI workflows) also found no match. The README, the CI configuration, and the DocC sources do not point to `docs/Usage.md`. The only necessary change is the deletion of `docs/Usage.md` and the empty `docs/` directory.'
  timestamp: 2026-08-20T01:18:23.330220+00:00
- actor: claude-code
  id: 01m0ec4qqt6rbbygnz3vbvyt1m
  text: |-
    ### implement — changed
    - evidence: 1 file removed — docs/Usage.md (and the empty docs/ directory with it, via `git rm -r docs/`). No other file changed: the pre-deletion reference sweep (`rg -l --hidden "docs/Usage|Usage\.md" --glob '!.build' --glob '!.kanban' --glob '!.git' .` and the wider `docs/` sweep) found zero references in the README, the CI workflows, and the DocC sources. Post-deletion checks: both rg sweeps exit 1 (no match), `test -d docs` exits 1. `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0. `Scripts/swift-test.sh --skip IntegrationTests` passed: 1023 tests in 96 suites (1 known issue) + 77 tests in 9 suites — the same counts as the baseline. Note: the first suite run showed one timing flake in GenerationStallDiagnosticTests ("a streaming turn reports the stall against the fragments it counted", BoundedWait timeout under full-suite load); it passed in isolation (0.067 s) and in the second full run. The deletion of a Markdown file cannot cause it.
    - next: /review
  timestamp: 2026-08-20T01:21:35.482974+00:00
position_column: doing
position_ordinal: '8580'
title: Delete the docs directory
---
The user asked to delete the docs. The `docs/` directory holds one file, `docs/Usage.md` (8 KB), which describes `respond`, the run plane, and drain behavior.

## What

- Delete `docs/Usage.md` and the `docs/` directory in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter.
- Before the deletion, search the repository for references to `docs/` and `Usage.md` (exclude `.build/` and `.kanban/`). Remove or repoint each reference.
- Do not move the content into README.md. The deletion is the request.

## Acceptance Criteria

- [x] The `docs/` directory does not exist
- [x] `rg -l "docs/Usage" --glob '!.build' --glob '!.kanban' .` finds no match
- [x] The hermetic suite stays green

## Tests

- [x] `rg -l "Usage.md" --glob '!.build' --glob '!.kanban' .` exits with no matches after the deletion
- [x] `Scripts/swift-test.sh --skip IntegrationTests` (or the current hermetic command) passes with the same counts as before
- [x] `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0

## Workflow
- Use `/tdd` where a failing check is possible; this card is a deletion, so the reference search is the check. #docs #cleanup