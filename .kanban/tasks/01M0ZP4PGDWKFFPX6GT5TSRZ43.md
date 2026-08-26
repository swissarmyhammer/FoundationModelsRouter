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
position_column: doing
position_ordinal: '8180'
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