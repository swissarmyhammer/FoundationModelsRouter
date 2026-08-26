---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zj8p1mkdsrd35p9n4a56ts
  text: |-
    Pass 1 of this card: `Session/RoutedSession.swift` only. The other files in the table stay as they are.

    Result: 324 doc lines of 444 (73.0%) became 252 of 372 (67.7%). 72 doc lines were removed. No code line changed. `git diff` with the doc lines filtered out is empty.

    ## What was cut
    - Each sentence that says the signature again. Examples: "- Returns: What the fold did." above a function that returns `CompactionResult`; "- Returns: The current `SessionOutbox/QueueDepth`."; "- Returns: Whatever `body` returns."
    - Each `- Parameter` line that only says the parameter name again: `prompt: The prompt to respond to.`, `response: The user's answer.`, `body: The wait on a person ...`.
    - Repeated text between paragraphs. `streamEvents(to:maxTokens:)` listed its event kinds two times: one time in prose, one time in the order paragraph. The order paragraph stays.
    - Two `- Returns:` blocks on `cancel(id:)` and `replace(id:prompt:)` that said again what the cases of `SessionOutbox.PromptQueueMutationResult` say in `SessionOutbox.swift`.
    - "The identity and directory accessors are `nonisolated` immutables" from the protocol header. The declarations below it show this.

    ## Why the file cannot go under 40%
    This file is a protocol declaration. It holds no function body, so no comment in it can repeat a body. Only two kinds of text were removable: text that says a signature again, and text that says the same thing two times. Both are now removed.

    The file has 120 lines that are not doc lines and 42 documented symbols. 40% permits 80 doc lines, which is 1.9 lines for each symbol. The cancellation contract, the event order, the gate discipline and the queue order each need more than 2 lines. To get 40%, you must delete one of them. 67.7% is the honest number.

    ## Gates
    - `swift build --build-tests`: Build complete, 0 errors, 0 warnings from our code. The one `missing creator for mutated node` warning comes from the mlx-swift dependency and was present before the change.
    - `swift test`: 1058 tests in 104 suites passed with the same 2 known issues, and 83 tests in 10 suites passed.

    ## Rules that apply to this file
    `dump validators` gave 55 rules. Three touch a doc edit:
    - `code-hygiene/missing-docs-swift`: swiftlint reads only that a doc comment IS there on an `open` or `public` declaration. It reads no word in the comment. A shorter block is still a block. Every symbol keeps its doc comment.
    - `swift/doc-parameter-naming`: a `- Parameter <name>:` key must name the internal parameter, not the argument label. Each of the 10 remaining keys was checked: `budget`, `maxTokens` (3 times), `workingDirectory`, `id` (3 times), `elicitationId`.
    - `code-hygiene/no-commented-code`: no example was moved out of a `///` block.

    This file holds no `// periphery:ignore` and no `// swiftlint:disable` directive, so the marker order rule does not apply.
  timestamp: 2026-08-26T17:35:41.620747+00:00
- actor: claude-code
  id: 01m0zj9tjm41c90ajt4y4z5gt0
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsRouter/Session/RoutedSession.swift. Doc lines 324/444 (73.0%) to 252/372 (67.7%). `swift build --build-tests`: 0 errors, 0 warnings from our code. `swift test`: 1058 tests in 104 suites with 2 known issues, plus 83 tests in 10 suites, all passed.
    - next: /review. The other 7 files in the card's table are not started.
  timestamp: 2026-08-26T17:36:19.028267+00:00
- actor: claude-code
  id: 01m0zjctxdfnmmhmjpgm3pa6xh
  text: |-
    ### the 40% acceptance criterion is wrong, and this pass proved it

    I wrote "every file under 40% doc lines" into this card. That number was a guess, and the first file shows it is not a sound test. The criterion is corrected below rather than left to fail every honest pass.

    **What happened.** `Session/RoutedSession.swift` went from 324 doc lines of 444 (73.0%) to 252 of 372 (67.7%). 72 doc lines were removed. `git diff` with `///` lines filtered out is EMPTY, so no code line changed — verified by me, not only reported.

    The pass stopped at 67.7% and said why, instead of reaching for my number. That is the correct behaviour and matches the card's own instruction not to hit the target by deleting something real.

    **Why 40% cannot work for this file.** It is a pure protocol declaration. It holds no function bodies, so no comment in it CAN repeat a body — the largest category of waste does not exist here. Only two categories were removable, signature restatement and cross-paragraph repetition, and both are now gone.

    What is left: 120 non-doc lines and 42 documented symbols. 40% permits 80 doc lines, which is 1.9 lines for each symbol. The cancellation contract, the event ordering, the gate discipline and the queue ordering each need more than two lines. Reaching 40% means deleting one of them.

    **So the ratio measures the wrong thing.** A file dense in declarations and thin in bodies will always score high, however tight its prose. A file with long function bodies scores low while its comments repeat every line. The share tells you about the shape of the file, not the quality of its doc.

    **The corrected criterion**, replacing "under 40%":
    - Every doc comment that remains states something the code cannot show: an invariant, a constraint, a trap, a reason, or a measurement.
    - No sentence restates a signature or a body.
    - No two paragraphs say the same thing.
    - The pass lists every invariant it KEPT, by line, so a reviewer can check nothing was lost.

    That is checkable by reading, which is the only way a comment cut can be checked.

    **The kept-invariant list is the real deliverable here**, and it is long: the cooperative-cancellation contract including that propagation past the process boundary is advisory and an MCP server may keep working; that model work which never checks cancellation runs to completion and the turn still returns; that a session retains `profile` so resident models stay loaded; the full turn event order for both proactive and reactive folds; that the turn lock is strict FIFO and a cancelled caller keeps its place; that a tool body reading its own session's transcript sees mid-turn history; that nothing bounds a decode; that abandoning a stream cancels the turn; that each subscription is buffered without bound; that `deinit` does not run the close sweep; and the reason `awaitingUser` exists at all, which is that a tool waiting on a person would otherwise hold `generationGate` and block every other session over that model.

    None of those is visible in a signature. All were at risk from a mechanical cut.

    **Seven files in the table remain untouched.** They are ordinary source with real bodies, so the removable category this file lacked does exist there, and they should fall further than this one did.
  timestamp: 2026-08-26T17:37:57.677129+00:00
- actor: claude-code
  id: 01m0zjpzy7q56q271pp612w3mc
  text: |
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`, 7 validators attempted, 0 findings, 0 failed. The directed kept-invariant check gave 1 finding — Sources/FoundationModelsRouter/Session/RoutedSession.swift:100.
    - next: Put the summarizer's error back into the three `compact` `- Throws:` blocks, then review again.

    #### What the directed check did
    The engine cannot read a comment cut, because no validator knows which fact a sentence carried. Thus each doc line that the diff removed was read against the new file and against the kept list on this card.

    #### The 8 items to spot-check are all present
    - Cancellation is cooperative, and propagation past the process boundary is advisory; an MCP server may keep working — `TurnCancellationResult.requested` and `cancelCurrentTurn()`.
    - Model work that never checks cancellation runs to completion, and the turn returns its response — `cancelCurrentTurn()`.
    - The session retains `profile`, thus the resident models stay loaded — the protocol header.
    - The turn lock is a strict FIFO `AsyncSemaphore`, and a cancelled caller keeps its place in line — `dispatchNextPrompt()`.
    - A tool body that reads its own session's transcript does not wait, and sees the history mid-turn — `transcript`.
    - Abandoning the stream cancels the turn — on `streamResponse(to:maxTokens:)` and on `streamEvents(to:maxTokens:)`.
    - `deinit` does not run the close sweep — `close()`.
    - `awaitingUser(_:)` exists because a tool that waits on a person would otherwise hold `RoutedModel/generationGate` and block every other session over that model — `awaitingUser(_:)`.

    Also present: the full turn event order for the proactive fold and the reactive fold, that nothing bounds a decode, that each `streamSessionEvents()` subscription is buffered without bound, the gate release and re-acquire discipline, and the queue order.

    #### The other checks
    - No public symbol lost its doc comment. Only `extension RoutedSession {` has no doc line above it, and an extension is not a documented symbol. It had none before the change.
    - All 10 `- Parameter` keys name the internal parameter: `budget` (2 times), `maxTokens` (3 times), `workingDirectory`, `id` (3 times), `elicitationId`. No key names an argument label.
    - The 40% share criterion was not used. The replacement criterion in the comment above was used.

    #### Removals that are correct, and why they are not findings
    - "Any error thrown by the model" from `respond(to:maxTokens:)` and from `dispatchNextPrompt()`: the method calls the model as its whole job, thus `throws` shows this.
    - "It throws if generation fails" from the two stream methods: `AsyncThrowingStream` shows this.
    - "Rethrows any error thrown by `body`, after re-acquiring" from `awaitingUser(_:)`: the new text is stronger. It says that the re-acquire happens on every exit from `body`, a throw and a cancellation included.
    - "A tool body cannot fork the session whose turn invoked it": kept as the `- Throws:` clause that names `SessionReentryError/forkDuringSameSessionTurn(sessionID:)`.
    - The `- Returns:` blocks on `cancelCurrentTurn()`, `cancel(id:)` and `replace(id:prompt:)`: the cases of the two result enums carry the same text.
    - "The identity and directory accessors are `nonisolated` immutables": the declarations show this.
  timestamp: 2026-08-26T17:43:30.503002+00:00
- actor: claude-code
  id: 01m0zjsabr53pagt4rnmdtxnqr
  text: |-
    ### the one finding is corrected — and it was a good catch

    `Sources/FoundationModelsRouter/Session/RoutedSession.swift:100` — the `- Throws:` on `compact(prompt:budget:)` had lost "The summarizer's error". Restored, and stated more fully than before, because the bare phrase did not carry the whole fact:

    > - Throws: The summarizer's error. A caller-driven fold does not degrade: unlike the automatic fold, which falls back to the deterministic-only pipeline and never throws, a summarizer failure here reaches the caller. Also `CancellationError` when cancelled, or ``SessionReentryError/sameSessionTurnInFlight(sessionID:)`` when called from a tool of this session's own turn.

    **Why this was a real loss and not a signature restatement.** `throws` on the declaration tells a reader that something can be thrown. It does not tell them WHICH failures reach them, and here that is genuinely surprising: `performAutoCompaction(prompt:budget:)` on the same type does the opposite, degrading through its tiers to the deterministic-only pipeline, which never throws. A reader who knows the automatic fold would reasonably assume the caller-driven fold degrades the same way. The code shows no `catch` on that path, but a doc comment that leaves the reader to go and check has failed at its job.

    This is exactly the line between the two categories this card is about. "Throws any error thrown by the model" says nothing a reader cannot see. "The summarizer's error reaches you, and it does NOT degrade the way the automatic fold does" says something the signature cannot.

    **The two overloads are deliberately not repeating it.** `compact()` and `compact(budget:)` both say "See ``compact(prompt:budget:)``". Restating the throws contract on each would put back exactly the repetition this card removes, so the reader is pointed at the one place that holds it.

    **Gates after the fix, run by me:** `swift build --build-tests` clean, 0 errors and 0 warnings from our code; `swift test` 1058 tests in 104 suites plus 83 tests in 10 suites passed, with the same 2 known issues.

    **A note on how this finding was produced, worth keeping.** The engine gave 0 findings from 7 validators, and it was right to: no validator can tell which fact a deleted sentence carried. The finding came from a directed check — reading the card's kept-invariant list against `git show HEAD~1`. That is the only way a comment cut can be reviewed, and it is why this card requires the pass to publish that list.
  timestamp: 2026-08-26T17:44:46.712512+00:00
position_column: review
position_ordinal: '8280'
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

## Review Findings (2026-08-26 12:38)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 1 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

The 7 engine validators gave 0 findings. The item below comes from the directed kept-invariant check: each invariant, constraint, trap and reason in `git show HEAD~1` was read against the new file and against the kept list on this card.

- [ ] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:100` `doc-cut/kept-invariant-lost` — The new `- Throws:` on `compact(prompt:budget:)` does not have "The summarizer's error". The old line had it, and the kept list on this card does not have it. This text does not say the signature again. `Session/RoutedSessionActorCompaction.swift` shows that the caller-driven fold calls `fold(...)` with a summarizer and catches nothing, thus a summarizer failure comes out of `compact`. `performAutoCompaction(prompt:budget:)` on the same type is different: it goes down through its tiers to "the deterministic-only pipeline, which never throws". A reader who knows the automatic fold will think that the caller-driven fold degrades in the same way. It does not. Put the summarizer's error back into the `- Throws:` of `compact(prompt:budget:)`, and into the `compact()` and `compact(budget:)` overloads in the extension, which lost the same line.