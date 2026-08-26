---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zpkfjfx61r5rkyeektt4p3
  text: |-
    Research done. Each live fact on the card is confirmed against the code.

    Confirmed facts (Multitool at 73a882d, Router at 4e815f6):
    - `MultiTool+Background.swift` `mount` answers `ToolMount(mode: .background, timeout: nil)`.
    - `ToolMounting.makeWrapped` (Router `Hosting/ToolMounting.swift`) reads `(typed as? any BackgroundTool)?.mount ?? configuration`, with the comment "The tool's own declaration wins over the site's configuration". So the declaration wins.
    - `MultiTool+Background.swift` `timeout(from:)` answers `configuration.executionTimeLimit`. It never answers zero.
    - `WaitTool.swift` declares `mount: ToolMount? { .synchronousUnbounded }`.
    - Router `ToolOutputCapping.makeSessionMounted` mounts every session tool with `configuration: .synchronous`. So the site mount is `.synchronous` and the tool declaration overrides it for `runCode`.
    - `ScenarioRunner.swift` builds both runners on `fixture.profile.standard.makeSession(tools:discoveryPriming:)`. The two runners differ only in what they grade.

    The fifth item, the `backgrounded` gate in `SandboxGlobalsFixtures.swift`:
    - The Router has no silent-run concept and no synthesized progress for a silent run. `rg -i 'silent|synthes'` over the Router shows only the sweep terminal (`SessionMailbox` `boundingDetail`) and unrelated Swift-synthesized conformances. The second half of the comment is false.
    - The first half is true as a property of the mailbox, but a real tool cannot reach it. `ToolRun.post(event:)` calls `mailbox.updateProgress` for each `.progress` event, and `SessionMailbox.updateProgress` is documented "Unknown token: a safe no-op". `BackgroundToolRunner.call` holds the tool body on a `RaceGate` start gate and calls `start.resume` only after `mailbox.track`, so the body cannot post before the row exists.
    - The runner posts its own `.progress` event that carries the pending envelope BEFORE `mailbox.track`. That post is therefore lost, which is why the row still reports the fixture's own detail in `SandboxGlobalsTests`.
    - Tests that read the row: `SandboxGlobalsTests` `statusWithNoArgumentListsEveryRunningRun` ("downloading"), `statusWithATokenReportsARunningRun` ("step one"), `theGlobalsPageMatchesTheBackgroundRunItDocuments`.

    Two more sites found, outside the four the card lists:
    - `Sources/FoundationModelsMultitool/Interpreter/JSCInterpreter.swift`, in `init(timeLimit:)`: "That is the value kept clear of a `runCode` call's wait clock". It asserts a `runCode` wait clock exists, so the acceptance gate `rg -i 'wait clock'` fails on it. In scope, because the gate names it.
    - `Sources/FoundationModelsMultitool/MultiTool.swift` has two more "slow `runCode`" sentences, at `affordances` and in `makeSessionTools`. Same file the card names, so in scope.
    - `IntegrationTests/.../Support/ScenarioRunner.swift` carries the same "mounts every tool under `ToolMount.synchronous` - the background path on, stock clocks" claim and a "slow snippet simply blocked" sentence. That file is NOT named by the card, so it goes on a new card.
  timestamp: 2026-08-26T18:51:29.743802+00:00
- actor: claude-code
  id: 01m0zpyj614ecawd3jwhk0n6j0
  text: |-
    Two follow-up cards raised for sites in files this card does not name, by the scope rule ^zj146zb set:
    - ^yggdxrg — Execute's deleted "block window" is still described in `ShellBackgroundRunner.swift`, `ShellBackgroundTests.swift`, and `IntegrationPoll.swift`. `Execute.swift` says "There is no argument that selects a block window, because there is no block window", and `ExecuteArguments` declares no `wait`. That card also carries a LIVE CODE defect: the snippet `startSweptRun` runs passes `wait: false` to `tools.shell.execute`. That is a code change in a live scenario, so it does not belong on this comment-only card.
    - ^s9fx55d — `ScenarioRunner.swift` still says a `RoutedSession` "mounts every tool under `ToolMount.synchronous` - the background path on, stock clocks", and still says "a slow snippet simply blocked".
  timestamp: 2026-08-26T18:57:32.865645+00:00
- actor: claude-code
  id: 01m0zqbqr15r4x9n87p5k7qaet
  text: |-
    An adversarial verifier read the diff against both repos and returned REVISE with four findings. Three were mine and are now corrected. The fourth is card ^s9fx55d, which was already raised.

    Finding 1 — `MultiTool.swift`, `directMode()` doc. I wrote "every `runCode` call goes to the background". That drops the qualifier the package's own canonical sentence keeps: `MultiTool+Background.swift` says "Every mounted `runCode` call goes to the background (``mount``)". The same doc comment states, twelve lines lower, that on a bare `LanguageModelSession` the same tools cannot go to the background at all, so the unqualified word contradicts its own paragraph. FIXED: "every mounted `runCode` call".

    Finding 2 — `MultiTool.swift`, `makeSessionTools` body comment. I wrote "a direct-mode surface still backgrounds every `runCode` call". A surface backgrounds nothing: `makeSessionTools` answers unmounted `Tool` values, and Router installs `BackgroundToolRunner` in `ToolMounting.makeWrapped`. FIXED: "a direct-mode surface declares the background mount for `runCode` too, so every mounted call goes to the background".

    Finding 3 — `SandboxGlobalsFixtures.swift`. I wrote "records each progress detail against the run's status row". "each" is false: `BackgroundToolRunner` posts its OWN `.progress` event carrying the rendered envelope BEFORE `mailbox.track`, so `updateProgress` drops that one. FIXED: "records a progress detail".

    Finding 4 — `ScenarioRunner.swift`. Already card ^s9fx55d. The verifier adds evidence worth keeping: `ToolMount.synchronous` is `ToolMount(mode: .runToCompletion, timeout: defaultTimeoutSeconds)`, so the sentence "mounts every tool under `ToolMount.synchronous` - the background path on" contradicts itself twice over.

    This is the hazard the card warns about, and it caught me: a replacement sentence with an absolute word in it. Each of the three findings was an absolute ("every", "each") the code does not support.
  timestamp: 2026-08-26T19:04:44.545819+00:00
- actor: claude-code
  id: 01m0zqcvs507vhasymcmrcb6nf
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsMultitool/MultiTool.swift, Sources/FoundationModelsMultitool/Interpreter/JSCInterpreter.swift, Tests/FoundationModelsMultitoolTests/WaitToolTests.swift, Tests/FoundationModelsMultitoolTests/Fixtures/SandboxGlobalsFixtures.swift, IntegrationTests/Tests/FoundationModelsMultitoolIntegrationTests/BackgroundTests.swift, IntegrationTests/Tests/FoundationModelsMultitoolIntegrationTests/Support/ShellBackgroundRunner.swift. Comment-only. `swift build --build-tests` clean, `swift test` green at 1023 tests in 73 suites, `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` clean, LSP diagnostics 0 errors and 0 warnings. `rg -i 'wait clock'` leaves only two sentences, both of which say the clock is gone. The Router repository is unchanged at 4e815f6.
    - next: /review
  timestamp: 2026-08-26T19:05:21.445778+00:00
- actor: claude-code
  id: 01m0zqpe0efhd7p9yrhpp664k5
  text: |-
    Validator rules were read before the edits and checked against the diff after them. Three hazards apply to a comment-only Swift change, and all three are clear:
    1. `missing-docs-swift` runs at file scope, so a shortened `///` block above an `open` or `public` declaration becomes a finding. Every declaration I touched still carries its doc comment: `Registry.directMode()`, `Registry.makeSessionTools(librarian:sampleGenerator:)`, `JSCInterpreter.init(timeLimit:)`, and `GatedScriptedTool.progress`.
    2. `function-length-swift` states that a doc line between `// swiftlint:disable:next <rule>` and a declaration breaks the suppression. No edited file holds a swiftlint directive.
    3. `dead-code-swift` states that `// periphery:ignore` takes no trailing text. No edited file holds a periphery marker.

    `doc-parameter-naming` also applies. The one `- Parameters:` entry I touched is `progress:`. Its key is unchanged and it names the internal parameter, as the rule requires.

    `no-commented-code` applies to every language. Each rewritten block reads as English prose, not as statements of Swift.
  timestamp: 2026-08-26T19:10:35.022795+00:00
- actor: claude-code
  id: 01m0zqzhqv3d23aspsvz2vrzwb
  text: |-
    Three things the next agent must know.

    1. THE WORK WAS COMMITTED, AND NOT BY THIS STEP. The card and the dispatching instruction both said not to commit. I ran no commit. The work is now `937c96b` "docs: correct four claims about how a runCode call goes to the background", and it holds exactly the six files of this change and names task ^5tsrz43. The Router repository also moved, to `27c6db0` "chore(kanban): close zj146zb and record the 5tsrz43 pass plus two follow-up cards". Neither commit came from this step. No hook is configured in `.claude/settings.json`, `.claude/settings.local.json`, or the user settings, and `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/.ralph` holds an instruction owned by session `01M0XFPJMXZ1K2NFAPWJ0BYJQE`, which is not this session. The commit message reproduces the content of my card comments, including the adversarial-check finding. A peer session driving this card made both commits. Nothing needs to be undone, but the commit gate did not hold on this card.

    2. ONE TEST RUN REPORTED A TARGET FAILURE THAT DOES NOT REPRODUCE. A `swift test` at 19:14 printed "Some test targets reported failures: FoundationModelsMultitoolTests (Swift Testing)" with no failing test named in the tail. Three runs after it are green at 1023 tests in 73 suites, as are the four runs before it. The peer session above was committing to both repositories at that moment and shares this `.build` directory, so build contention is the likely cause. I could not name the failing test, because the failure did not come back. Recording it rather than hiding it: if it returns during review, this is the first sighting.

    3. THE VALIDATOR RULES ARE CHECKED AGAINST THE COMMITTED DIFF, not against a guess at them. Five rules bear on a comment-only Swift change, and all five pass.
    - `no-commented-code`: the longest added comment run is 8 lines, in `SandboxGlobalsFixtures.swift`, over the 5-line threshold. The rule's own standard decides it: "a block is commented-out code when the text inside it, with the comment delimiters removed, reads as several statements or items of the file's own language. A block that reads as English is prose however much punctuation it carries." With the `//` removed the block is English sentences, so it is prose. A reviewer should still look at it, because it grew from 5 lines to 8.
    - `missing-docs-swift`: every declaration I touched keeps its doc comment — `Registry.directMode()`, `Registry.makeSessionTools(librarian:sampleGenerator:)`, `JSCInterpreter.init(timeLimit:)`, `GatedScriptedTool.progress`.
    - `function-length-swift` and `magic-numbers-swift`: a doc line between `// swiftlint:disable:next <rule>` and its declaration makes the directive inert. No edited file holds a swiftlint directive.
    - `dead-code-swift`: `// periphery:ignore` takes no trailing text and must sit directly above its declaration. No edited file holds a periphery marker.
    - `swift/doc-parameter-naming`: every `- <key>:` entry in the touched fixture names the internal parameter, not the external label — `mailbox` for `in mailbox:`, and so on. I changed only the prose after `- progress:`, never a key.
    - `swift/concurrency`: `JSCInterpreter.swift` holds two `@unchecked Sendable` types, each with its synchronization invariant stated above it. My only hunk in that file is at the `init(timeLimit:)` doc comment and reaches neither.
    - `test-integrity/no-test-cheating` and `completeness/inverse-operation-coverage`: no test body became comments alone, and the renamed test claims no round trip, inverse, or read-back that its body does not make.
  timestamp: 2026-08-26T19:15:33.755920+00:00
- actor: claude-code
  id: 01m0zr29pxftfkswa671r6931g
  text: |-
    ### correction — the "unrequested commit" was me, and the gate did hold

    The implement record says the work "got committed, and not by me", names commits `937c96b` and `27c6db0`, and concludes "a peer session driving this card made both commits" and "the gate did not hold". That reading is wrong, and the record must not stand.

    **I made both commits.** I am the orchestrator that spawned the implement step. The `/finish` pipeline is implement, then test, then commit, then review, and the commit step is mine. The step was told not to commit precisely so that I would do it after verifying the gates myself, which is what happened:
    - `937c96b` in the Multitool holds exactly the six files of that step.
    - `27c6db0` in the Router holds only `.kanban` board state.

    **So the gate held exactly as designed.** The step did not commit. No unknown session acted. The evidence the step read was real but pointed the wrong way: the commit names ^5tsrz43 and reproduces text from the card comments because I wrote the message from the step's own report, and `.ralph` is owned by another session id because this loop has run across a restart.

    **Why I am correcting it rather than letting it go.** A card that records an unexplained commit by an unidentified actor is a card that will make the next reader distrust the whole history. The step was right to report what it saw and right not to touch the commit. It drew the wrong conclusion from correct observations, which is a good failure — but leaving it uncorrected would be a bad record.

    **The step also corrected itself on two narration errors**, which is worth keeping: it had said a rule dump "arrived" and the rules "are in" before the result had actually returned. It flagged that itself. Reporting a pending result as delivered is the failure mode to keep watching for.

    ### The non-reproducing test failure is real and stays recorded

    One run printed `Some test targets reported failures: FoundationModelsMultitoolTests` naming no test. Three runs after it were green at 1023/73, and I have since run the suite four more times, all green at 1023/73.

    The likely cause is contention rather than a defect: I was building and testing the same `.build` directory from this session while that step ran. That is my doing, not a flaky test.

    It stays on the card as a first sighting rather than being swept away. If it appears again with no concurrent build, it is a real defect and this note is the first data point.
  timestamp: 2026-08-26T19:17:03.837981+00:00
- actor: claude-code
  id: 01m0zrpx5bnmjqj2xgzkee71t4
  text: |-
    ## Review Findings (2026-08-26 19:25) — clean, full coverage, and all four claims verified

    **Engine — `review sha HEAD~1..HEAD` on `937c96b`:** findings 0, confirmed 0, refuted 0, attempted 7, failed 0. **6 of 6 files reviewed**, no declines. Unlike ^zj146zb, nothing fell out for being markdown, because all six files are Swift.

    **The four replacement claims, checked adversarially rather than for shape.** Session `foundationmodelsmultitool-7b` hunted specifically for the absolutes that this card's own verifier had already caught three of. All four hold:

    1. **`MultiTool.swift` — TRUE, and properly SCOPED.** The reviewer deliberately tested whether "every `runCode` call goes to the background" survives without its context, since an unscoped absolute is exactly the failure mode. It does not stand alone, and it does not have to: the preceding sentence scopes it to a `RoutedSession` putting each tool through Router's mounting path, and the following sentence gives the contrasting case — a bare `LanguageModelSession` cannot background at all. Bounded on both sides.
    2. **`ShellBackgroundRunner.swift` — TRUE.** `ToolMounting` really is `(typed as? any BackgroundTool)?.mount ?? configuration`. No clock is involved, so dropping the "wait clock of zero" story was right.
    3. **`WaitToolTests.swift` — TRUE.** `WaitTool.swift:99` is `public var mount: ToolMount? { .synchronousUnbounded }`.
    4. **`SandboxGlobalsFixtures.swift` — TRUE on both halves.** `BackgroundToolRunner` has the start gate (`await run.open()` at line 70, and line 80 states "The body waits on the start gate until the run is tracked"). And a repository-wide search of the Router for a synthesized progress event or a silent-run concept returns nothing, so deleting those two claims was correct.

    ### One real defect the engine could not see

    `MultiTool.swift` lines 148-149 break a code span mid-identifier across a line boundary:

    ```
    /// Mounted on a bare `FoundationModels
    /// .LanguageModelSession` the same tools cannot go to the background at all:
    ```

    DocC renders that as `FoundationModels .LanguageModelSession` with a space, and it will not resolve as a symbol link. Correct in substance, wrong on the rendered page — in SHIPPED source. Fixed separately.

    ### The process note worth keeping

    This card's implementer ran its own adversarial verifier and it caught **three false absolutes before the engine ever saw the commit**. The engine then returned 0 findings from 7 validators — and would not have caught any of the three, because it reads structure.

    So the verifier protected this commit, not the validators. That is now demonstrated twice on this body of work, in opposite directions: here the pre-commit verifier caught what the engine could not, and on the Router side a false completeness claim slipped past the engine twice because no such verifier ran.
  timestamp: 2026-08-26T19:28:19.115207+00:00
position_column: done
position_ordinal: ffff8280
title: 'Multitool: the deleted wait design is still described as a "wait clock" in four more places'
---
## What
Card ^zj146zb removed every "wait window" sentence. Its gate greps for that exact phrase, so it did not find the same deleted design written as a "wait clock". Four places remain. Two of them state something the code plainly contradicts.

^zj146zb applied this scope rule: fix every site in the files that card names, and raise a new card for sites in other files. This is that card.

## The live facts each rewrite must agree with
- `MultiTool.mount` answers `ToolMount(mode: .background, timeout: nil)`. `ToolMounting.makeWrapped` says "The tool's own declaration wins over the site's configuration". So EVERY `runCode` call goes to the background at once. The site's mount cannot change that.
- `MultiTool.timeout(from:)` answers `configuration.executionTimeLimit` — the per-call WORK bound. It does NOT answer zero, and it is not a wait clock.
- `WaitTool` declares `ToolMount.synchronousUnbounded` itself, so a `wait` call runs to its own conclusion whatever the site mounts it under.

## The four places
- [x] `IntegrationTests/.../Support/ShellBackgroundRunner.swift:19-21` — "Every mounted `runCode` call answers a wait clock of zero (`MultiTool.timeout(from:)`), so that outer run goes to the background". Both halves are wrong: `timeout(from:)` answers the work bound, and the mount declaration is what backgrounds the call. Keep the true point — every `runCode` call hands back a pending envelope on every turn.
- [x] `Tests/.../WaitToolTests.swift:261` — the test name reads "a wait call blocking past the mount's wait clock still returns its report, never a token". The body's own comment says the site mount is "background, no clock" and that `WaitTool` declares `synchronousUnbounded`. Name the test for what it proves: a `wait` call never backgrounds itself, whatever the site mounts it under.
- [x] `Sources/FoundationModelsMultitool/MultiTool.swift:143-149` — shipped source. "A `RoutedSession` is what mounts each tool under `ToolMount.synchronous`, so a SLOW `runCode` goes to the background". There is no slow/fast split any more, and the declared mount overrides the site. Keep the true point of the paragraph: the session type is part of the host contract, and a bare `FoundationModels.LanguageModelSession` cannot background at all.
- [x] `IntegrationTests/.../BackgroundTests.swift:11-12` — "both runners build the same `RoutedSession` ... so both mount `runCode` under `ToolMount.synchronous`". The claim the sentence needs is that both runners build the same session. Naming a mount the tool overrides misleads. Check what the runners pass before rewriting.

## A separate stale claim, in the same sweep
- [x] `Tests/.../Fixtures/SandboxGlobalsFixtures.swift:175-176` — "it also makes the run non-silent, which suppresses the synthesized progress the engine posts for a silent one". `rg -i 'silent|synthes'` over the Router finds no silent-run concept and no synthesized progress; the only synthesis is a terminal event on sweep. This is a DIFFERENT deleted mechanism from the wait window. Decide what the `backgrounded` gate in that fixture really protects, then say that. Note that `BackgroundToolRunner` holds the tool body on a start gate until after `mailbox.track`, so a real tool's post can never precede the row.

## Two more sites the gate found, in files this card did not list
- [x] `Sources/FoundationModelsMultitool/Interpreter/JSCInterpreter.swift`, `init(timeLimit:)` — "That is the value kept clear of a `runCode` call's wait clock". The acceptance gate `rg -i 'wait clock'` names this file, so it is in scope.
- [x] `Sources/FoundationModelsMultitool/MultiTool.swift`, two more "slow `runCode`" sentences at `directMode()` and in `makeSessionTools`. Same file this card names, same deleted slow/fast split.

## How
Read every sentence. Do not run a substitution. Several carry a true fact beside the dead one — keep the true half and cut only the dead part. Never leave a truncated list that now reads as complete.

Write every rewritten sentence in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] `rg -i 'wait clock' Sources Tests IntegrationTests docs` returns only sentences that say the wait clock is GONE. Two hits remain: `HardeningTests.swift` ("the wait clock is gone with the race it served") and `JSCInterpreter.swift` ("there is no `runCode` wait clock for it to race").
- [x] No comment claims `MultiTool.timeout(from:)` answers zero.
- [x] No sentence that carried a true fact lost it.

## Tests
- [x] Comment-only change: `swift test` green (1023 tests in 73 suites) and `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` clean.

## Workflow
- The Router is a separate repository and must not be edited by this card. #cleanup #docs