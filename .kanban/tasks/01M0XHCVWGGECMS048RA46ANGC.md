---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zrd4vkdycg83mnbng2rdnz
  text: |-
    Research done. Verified against the code, not against doc comments.

    **Ground truth: `runCode` always goes to the background.**
    `Sources/FoundationModelsMultitool/MultiTool+Background.swift:62-64` — `mount` returns `ToolMount(mode: .background, timeout: nil)` with no condition. Router reads that declaration in `Sources/FoundationModelsRouter/Hosting/ToolMounting.swift` (`switch mount.mode` / `case .background` -> `BackgroundToolRunner`). Thus no "slow" branch exists.

    **The README item is NOT done.** `README.md:23` still reads "so a slow `runCode` starts a background run and answers at once with a pending envelope." Commits `1c57491` and `2347c0c` (task ^xpbhgac) changed the bare-`LanguageModelSession` sentence and the mount direction, but they left the word "slow". The `rg -i 'waitSeconds' README.md docs` gate does pass (no match). I will correct line 23.

    **The card's claim that "the session also reports settlement on its own" is TRUE ON ONE SURFACE ONLY.**
    - `respond(to:)` does drain: `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:63-76` loops up to `backgroundRunDrainRoundLimit = 4` (`:8`), awaits each run through `mailbox.wait` (`:89-90`), and re-prompts with `drainedRunContinuationPrompt` (`:12-15`).
    - `streamEvents(to:)` and `streamResponse(to:)` do NOT drain: `Sources/FoundationModelsRouter/Session/RoutedSession.swift:135-136` and `:156-159` — "This surface does not drain the run plane." `SessionEvent.runSettled` goes to the HOST, not into the model's context.
    - `dispatchNextPrompt()` runs a delivery turn with `settledRunDeliveryPrompt` (`Generation.swift:17-22`), but only when a host driver calls it.

    This package's host contract names `streamEvents(to:)`, and the CLI demo drives that surface. Thus on the surface this package documents, `wait` is the only way the model gets a result inside the turn. I will NOT put "you may not have to call wait" into the model-facing `description`: the model cannot know its surface, and on the streaming surface that sentence would strand it. The per-surface fact goes in the doc comment, where there is room to name the surface.

    **Two false claims found in the existing text, both of the kind this card was written to stop.**
    1. `WaitTool.swift` "**The two surfaces.**" paragraph has the two surfaces inverted: it says the streaming surface delivers a result on its own and that `respond(to:)` needs no tool. The code says the opposite about draining.
    2. `CLIRunner.swift` says a `RoutedSession` mounts each vended tool under `ToolMount.synchronous`. `MultiTool` declares `.background`.

    **Also found:** `WaitTool.swift` says waiting "used to be" a `wait(completionToken, seconds)` global in the sandbox. The global still exists — `Sources/FoundationModelsMultitool/MultiTool+SandboxGlobals.swift:255` and `:266` declare it, and `:345` binds it.
  timestamp: 2026-08-26T19:22:59.315808+00:00
- actor: claude-code
  id: 01m0zrryns9g0aqj0shsghsgpd
  text: |-
    ### implement — changed
    - evidence: 5 files — `Sources/FoundationModelsMultitool/WaitTool.swift`, `Sources/MultitoolCLI/CLIRunner.swift`, `README.md`, `eventplan.md`, `Tests/FoundationModelsMultitoolTests/WaitToolTests.swift`. Gates: `swift build --build-tests` clean; `swift test` 1023 tests in 73 suites passed; `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` clean; `swift build --product multitool-cli` clean; `rg -i 'waitSeconds' README.md docs` no match.
    - next: `/review`

    TDD ran on the one behavioural contract in the change. `WaitToolTests.swift` asserted `description.contains("only when you cannot continue")` — the old last-resort framing, which the card reverses. I changed the test first and watched it fail on the real cause (`swift test --filter WaitToolTests/theDescriptionNamesNoDuration`: 2 issues, on the new `not the result` expectation and on the negated last-resort expectation), then wrote the description.

    Every claim in the new text was checked against code, never against a neighbouring doc comment:
    - "every mounted `runCode` call goes to the background" — `MultiTool+Background.swift:62-64`, `ToolMount(mode: .background, timeout: nil)`, unconditional.
    - Router honours the declaration — `Hosting/ToolMounting.swift:43-45`, `switch mount.mode` / `case .background` -> `BackgroundToolRunner`.
    - "no race, a fast snippet gets a token too" — `Hosting/BackgroundToolRunner.swift:55-98`, `call` returns `envelope.rendered` with no fast path. This is what licenses the README's "not the slow calls only".
    - The per-surface drain facts — `Session/RoutedSessionActorGeneration.swift:8,12-15,63-76,89-90` and `Session/RoutedSession.swift:135-136,156-159`.

    Not done and deliberately so: the "parked" vocabulary in `eventplan.md`. It states current behaviour correctly, the same word stands in five other sections, and a partial rename would leave the file inconsistent. Recorded in the description rather than guessed at.

    One deviation from the dispatch to flag: the README item was reported as already done by ^xpbhgac. It was not. `README.md:23` still read "so a slow `runCode` starts a background run" — commits `1c57491` and `2347c0c` changed the mount direction and the bare-session sentence and left the word "slow". The `waitSeconds` gate passed independently of it. I did the item.
  timestamp: 2026-08-26T19:29:26.201667+00:00
- actor: claude-code
  id: 01m0zsgphq76jweqtrgefnhmgq
  text: |-
    ## Review Findings (2026-08-26 19:40) — clean, and the omission is confirmed load-bearing

    **Engine — `review sha e066988~1..HEAD`:** findings 0, attempted 7, failed 0. Eight Swift files reviewed of ten touched; `README.md` and `eventplan.md` were never opened, because the engine reviews code only.

    ### `WaitTool.description` — the omission is right, verified in the Router

    This was the claim I most wanted checked, because that text is in the prompt on every turn, so a false sentence there is a behavioural defect rather than a documentation one.

    - **`respond(to:)` DOES drain.** `RoutedSessionActorGeneration.swift` holds the loop: `runPlaneDrainCount += 1`, then up to `backgroundRunDrainRoundLimit` rounds of `settleBackgroundRuns(cancellationsBefore:)` followed by a re-generate on `drainedRunContinuationPrompt`.
    - **The streaming surfaces do NOT.** `settleBackgroundRuns` is referenced in exactly one file — its definition and that one call site. No `streamEvents` or `streamResponse` path reaches it.

    So on a streaming surface no result arrives unasked. A promise that one would is **false on two of the three surfaces**, and a model cannot know which surface drives it. The only sentence true on all three is the one that was written: `wait` is the normal way to read a `runCode` result, with no promise of delivery.

    **The omission is load-bearing, not an oversight.** That is worth stating plainly, because a later reader might see the missing sentence as an incomplete description and "helpfully" add it back.

    ### `eventplan.md` — leave the four dated mentions, and there is a stronger reason than mine

    I argued internal consistency: half-renaming a file that uses the word five more times elsewhere makes it worse.

    The reviewer added the reason that actually settles it. **That file is the user's own design record, and the user personally rewrote its elevation section earlier today**, in commit `d9e1fe6` "docs(eventplan): replace waitSeconds elevation with background tools by declaration". It is authored, not generated.

    Vocabulary maintenance inside someone's authored design document is a different act from fixing a stale code comment, and the bar for it is the author's say-so. The one-word grammar fix ("An backgrounded" → "A backgrounded") is inside that line. Renaming dated historical mentions is outside it.

    **Two markdown files in this range remain unreviewed by any tool** — `README.md` and `eventplan.md`. They need a human read, and no amount of re-running the engine will change that.
  timestamp: 2026-08-26T19:42:24.311104+00:00
depends_on:
- 01M0XHCGVSKNCN6CEJXT73M7PW
- 01M0XGRYMR1GPMY1X52FTDMR58
position_column: done
position_ordinal: ffff8580
title: 'Multitool: docs, WaitTool text, and the CLI demo'
---
## What
Cross-repo task in `../FoundationModelsMultitool`. Third of three.

- [x] `Sources/FoundationModelsMultitool/WaitTool.swift` docs and description: `wait` collects a settled run's result now; the session also reports settlement on its own — the model does not have to call it.
- [x] `README.md`: the "slow `runCode` goes to the background" paragraph becomes "`runCode` always goes to the background".
- [x] `eventplan.md` is already corrected in the working tree (the dual mode is removed from the normative sections; do NOT delete the file). Review the ~16 remaining historical mentions in "Consolidation of the siblings" and keep only the ones that state history, not current behavior.
- [x] `Sources/MultitoolCLI/CLIRunner.swift`: the demo flow works with always-handle `runCode`; update its narration.

## Acceptance Criteria
- [x] `rg -i 'waitSeconds' README.md docs` returns no match.
- [x] The remaining `eventplan.md` mentions of the old design are inside clearly historical text only.
- [x] The CLI demo target compiles; its tests pass.
- [x] Full Multitool suite green.

## Tests
- [x] Run `swift test` and the CLI test target in `../FoundationModelsMultitool` — green. 1023 tests in 73 suites.

## Workflow
- Use `/tdd` — run the suites before and after; the change is documentation and demo narration. #docs

## Correction to the card's own premise

The card says the session reports settlement on its own, so the model does not have to call `wait`. That is true on ONE surface only, and this package documents the other one. Verified in Router source:

- `respond(to:)` drains: `Session/RoutedSessionActorGeneration.swift:63-76` loops to `backgroundRunDrainRoundLimit = 4` (`:8`), awaits each run through `mailbox.wait` (`:89-90`), and re-prompts with `drainedRunContinuationPrompt` (`:12-15`).
- `streamEvents(to:)` and `streamResponse(to:)` do NOT drain: `Session/RoutedSession.swift:135-136` and `:156-159` — "This surface does not drain the run plane." `SessionEvent.runSettled` goes to the host, not into the model's context.

The host contract and the CLI demo both drive `streamEvents(to:)`. Thus the per-surface fact went into the doc comment, and the model-facing `description` promises nothing about a result arriving unasked — the model cannot know its surface, and that sentence would strand it on the streaming surface.

## eventplan.md — the review, decision by decision

Scope: "Consolidation of the siblings". NOT deleted, and no heading changed (many test files quote the headings verbatim).

KEEP, states history:
- The `CallWait` inventory ("a soft deadline that detaches the call") and the Shelltool inventory ("a deadline race that detaches and does not kill", "a capture-at-start sink that posts detached events"). Both describe sibling code the next paragraph deletes.
- "The `waitSeconds` block-clock is removed together with the sync-or-background race." A removal statement, and the anchor for the whole section.
- "We remove the MCP follow-up pseudo-tools ... The uniform `status()` / `wait()` / `cancel()` builtins replace them." Current and correct.

CHANGED, one item: "An backgrounded `runCode`" -> "A backgrounded `runCode`". A broken article left by an earlier rename pass. Checked with `rg` first: `ShellExecuteTests.swift:314` quotes this passage only through "one string, two planes", so the quotation does not dangle.

LEFT AND REPORTED, ambiguous — not guessed at on the user's own document:
- "parked" at four sites in this section ("behind a parked run", "a parked native call", "park state", "parked runs"). These state current behaviour accurately; only the word is dated. The same word also stands at lines 128, 132, 141, 234 and 756, outside this section, so a rename inside one section alone would contradict the rest of the file. This is a vocabulary pass, not an old-design mention.
- "Detach supervision moves to the shared engine" and "a live detached run". Both are shell child-process vocabulary rather than the `runCode` sync-or-background race, so whether they are stale is a question about the Shell capability and not about this card.

## Also found, and corrected

Two false claims already in the text, of exactly the kind this card exists to stop:
1. `WaitTool.swift` had the two surfaces INVERTED — it said the streaming surface delivers a result on its own and `respond(to:)` "needs no tool". The code says the opposite about draining.
2. `CLIRunner.swift` said a `RoutedSession` mounts each vended tool under `ToolMount.synchronous`. `MultiTool` declares `.background`.

And one more, corrected in passing: `WaitTool.swift` said waiting "used to be" a `wait(completionToken, seconds)` sandbox global. The global still exists — `MultiTool+SandboxGlobals.swift:255` and `:266` declare it, `:345` binds it. What changed is that a MODEL now has a tool; a snippet still has the global.