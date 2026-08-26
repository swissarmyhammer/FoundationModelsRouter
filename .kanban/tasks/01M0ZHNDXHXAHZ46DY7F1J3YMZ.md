---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: 'Multitool: cut the doc comments back to what the code cannot say'
---
## What
The user asked for this directly: "you just have way too much code in here, and way too long of /// comments." The Router side was cut. The Multitool was not. Doc comments are now the majority of several source files.

Measured on 2026-08-26, doc lines against total lines:

| Share | Doc / total | File |
|---|---|---|
| 74% | 100 / 135 | `MultiToolConfiguration.swift` |
| 71% | 146 / 203 | `Surface/APISurface.swift` |
| 64% | 195 / 302 | `Rendering/ResultRenderer.swift` |
| 62% | 125 / 200 | `Diagnostics/CallTrace.swift` |
| 60% | 282 / 468 | `Discovery/SearchToolsTool.swift` |
| 59% | 96 / 162 | `MultiTool+Background.swift` |
| 58% | 348 / 598 | `Surface/MultiToolBuilder.swift` |
| 54% | 829 / 1510 | `MultiTool.swift` |

## The rule to apply
**Keep what the code cannot show. Cut what repeats the code.**

Keep:
- A constraint or a safety property. Example, in `MultiTool+Background.swift`: the engine's timeout resets on every progress event while the sandbox watchdog's deadline never does, so a snippet that keeps reporting progress still meets the absolute ceiling. Code cannot show that.
- A measurement that explains a choice. Example: `^4qcf1v9` recorded 21 rounds and about 1700 seconds for an eight-second run, which is why the collect sentence is worded as it is.
- A reason a reader would otherwise undo. Example: why a value is a code and not a count.

Cut:
- Any sentence that restates the signature or the body.
- Repetition. `MultiTool+Background.swift` says a declared mount wins over the site twice, in two paragraphs.
- Doc that is longer than the code and adds nothing: `mount` is 3 lines of code under 14 lines of doc, and `timeout(from:)` is 3 lines under 29.

## Known defect to fix while here
- [ ] `MultiTool+Background.swift:49` opens with a sentence that does not parse: "The mount every `runCode` call carries: the background, whatever mount the composition site applies." Replace with one clear sentence, for example: "The mount every `runCode` call carries. It is always background, and it wins over the mount the composition site applies."

## Acceptance Criteria
- [ ] Every file in the table above is under 40% doc lines, OR the card records why a file must stay above it.
- [ ] No constraint, safety property, or measurement was lost. List each one kept, by file.
- [ ] The garbled sentence at `MultiTool+Background.swift:49` reads clearly.
- [ ] No public symbol lost its doc comment entirely — shorter, not absent.

## Tests
- [ ] Comment-only change, so the suites are the regression guard: `swift test` green (baseline 1023 tests in 73 suites) and `swift build --build-tests` with zero warnings.

## Workflow
- One file at a time. A comment cut is not reviewable in bulk, and a lost constraint is expensive to notice later.
- Write every rewritten sentence in ASD-STE100 Simplified Technical English.

#cleanup #docs