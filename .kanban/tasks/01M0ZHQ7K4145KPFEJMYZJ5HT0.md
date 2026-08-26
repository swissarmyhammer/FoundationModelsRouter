---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'Router: cut the doc comments back to what the code cannot say'
---
## What
The sibling of ^f1j3ymz, for this repository. The user's complaint covered both sides: "you just have way too much code in here, and way too long of /// comments."

Cutting the public surface from 812 declarations to 437 (^90tn9fj) did NOT cut the doc comments. Those are different things, and a smaller surface can even raise the share, because the doc stays on the symbols that remain.

Measured 2026-08-26, doc lines against total, files over 100 lines:

| Share | Doc / total | File |
|---|---|---|
| 72% | 324 / 444 | `Session/RoutedSession.swift` |
| 66% | 125 / 188 | `Session/ToolOutputCapping.swift` |
| 61% | 152 / 249 | `Session/DiscoveryPriming.swift` |
| 57% | 98 / 171 | `Session/LanguageModelSessionBackend.swift` |
| 57% | 62 / 108 | `Recording/MergedTranscript.swift` |
| 56% | 60 / 106 | `Hosting/ToolInvocationRecord.swift` |
| 54% | 148 / 274 | `Recording/Sinks.swift` |
| 52% | 54 / 103 | `Hosting/OperationOutcome.swift` |

Twelve files over 100 lines are at or above 40%.

`Session/RoutedSession.swift` at 72% is the worst file in either repository, and it is the type a host reaches for first. Start there.

## The rule to apply
**Keep what the code cannot show. Cut what repeats the code.**

Keep:
- A constraint or an invariant. Example, in `Hosting/OperationEvent.swift`: only `.completed` is terminal, and a run that posts any event must post exactly one. Code cannot show that.
- A reason a reader would otherwise undo, such as why a value is `package` and not `public`.
- A measurement that explains a choice.

Cut:
- Any sentence that restates the signature or the body.
- Repetition across paragraphs.
- A parameter list that only spells the parameter names again.

## Acceptance Criteria
- [ ] Every file in the table is under 40% doc lines, OR the card records why it must stay above.
- [ ] No invariant, constraint, or measurement was lost. List each one kept, by file.
- [ ] No public symbol lost its doc comment entirely — shorter, not absent.
- [ ] `swift build --build-tests` has zero warnings, and `swift test` is green (baseline 1058 tests in 104 suites plus 83 in 10 suites, with the same 2 known issues).

## Tests
- [ ] Comment-only change, so the suites are the regression guard. Run them before and after each file.

## Workflow
- One file at a time. A comment cut is not reviewable in bulk, and a lost invariant is expensive to notice later.
- Write every rewritten sentence in ASD-STE100 Simplified Technical English.

#cleanup #docs