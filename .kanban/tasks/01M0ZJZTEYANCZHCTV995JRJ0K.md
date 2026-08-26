---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'Router: cut the doc comments in the remaining seven files'
---
## What
The sibling of ^yzj5ht0, which did `Session/RoutedSession.swift` alone. These seven carry the same problem. Measured 2026-08-26, doc lines against total:

| Share | Doc / total | File |
|---|---|---|
| 66% | 125 / 188 | `Session/ToolOutputCapping.swift` |
| 61% | 152 / 249 | `Session/DiscoveryPriming.swift` |
| 57% | 98 / 171 | `Session/LanguageModelSessionBackend.swift` |
| 57% | 62 / 108 | `Recording/MergedTranscript.swift` |
| 56% | 60 / 106 | `Hosting/ToolInvocationRecord.swift` |
| 54% | 148 / 274 | `Recording/Sinks.swift` |
| 52% | 54 / 103 | `Hosting/OperationOutcome.swift` |

Unlike `RoutedSession.swift`, these hold real function bodies. So the largest category of waste — a comment that repeats the body below it — DOES exist here, and these should fall further than 67.7%.

## The rule
**Keep what the code cannot show. Cut what repeats the code.**

Keep an invariant, a constraint, a trap, a reason a reader would otherwise undo, or a measurement. Cut any sentence that restates a signature or a body, and cut repetition between paragraphs.

**The hard case, learned from ^yzj5ht0.** "Throws any error thrown by the model" restates `throws` and goes. "The summarizer's error reaches you, and this path does NOT degrade the way the automatic fold does" is a fact the signature cannot carry, and it stays. When a `- Throws:` or `- Returns:` line names WHICH failure or WHICH value among several possible ones, read it carefully before cutting.

**A fact belongs in the file once, at the declaration that owns it.** A convenience overload that says "See ``other(_:)``" must not repeat the contract.

## Acceptance Criteria
- [ ] Every doc comment that remains states something the code cannot show.
- [ ] No sentence restates a signature or a body, and no two paragraphs say the same thing.
- [ ] **Each file's pass publishes every invariant, constraint, trap and reason it KEPT, by line.** This list is the deliverable. It is the only way the cut can be reviewed: no validator can tell which fact a deleted sentence carried, so a reviewer reads the list against `git show` of the parent commit.
- [ ] No public symbol lost its doc comment. Shorter, never absent.
- [ ] Every surviving `- Parameter <name>:` key names the internal parameter, not the argument label.

**Do not set a percentage target.** ^yzj5ht0 proved the share measures the shape of a file, not the quality of its prose. Report the before and after numbers, but never delete a real fact to reach one.

## Tests
- [ ] Comment-only: a diff with the `///` lines filtered out must be empty for each file.
- [ ] `swift build --build-tests` 0 errors and 0 warnings from our code.
- [ ] `swift test` green: baseline 1058 tests in 104 suites plus 83 in 10 suites, with the same 2 known issues.

## Workflow
- **One file per commit.** A comment cut is not reviewable in bulk, and a lost invariant is expensive to notice later.
- Write every rewritten sentence in ASD-STE100 Simplified Technical English.

#cleanup #docs