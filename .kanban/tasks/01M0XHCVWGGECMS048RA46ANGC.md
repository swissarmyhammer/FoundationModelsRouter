---
assignees:
- claude-code
depends_on:
- 01M0XHCGVSKNCN6CEJXT73M7PW
- 01M0XGRYMR1GPMY1X52FTDMR58
position_column: todo
position_ordinal: '8980'
title: 'Multitool: docs, WaitTool text, and the CLI demo'
---
## What
Cross-repo task in `../FoundationModelsMultitool`. Third of three.

- [ ] `Sources/FoundationModelsMultitool/WaitTool.swift` docs and description: `wait` collects a settled run's result now; the session also reports settlement on its own — the model does not have to call it.
- [ ] `README.md`: the "slow `runCode` goes to the background" paragraph becomes "`runCode` always goes to the background".
- [ ] `eventplan.md` is already corrected in the working tree (the dual mode is removed from the normative sections; do NOT delete the file). Review the ~16 remaining historical mentions in "Consolidation of the siblings" and keep only the ones that state history, not current behavior.
- [ ] `Sources/MultitoolCLI/CLIRunner.swift`: the demo flow works with always-handle `runCode`; update its narration.

## Acceptance Criteria
- [ ] `rg -i 'waitSeconds' README.md docs` returns no match.
- [ ] The remaining `eventplan.md` mentions of the old design are inside clearly historical text only.
- [ ] The CLI demo target compiles; its tests pass.
- [ ] Full Multitool suite green.

## Tests
- [ ] Run `swift test` and the CLI test target in `../FoundationModelsMultitool` — green.

## Workflow
- Use `/tdd` — run the suites before and after; the change is documentation and demo narration. #docs