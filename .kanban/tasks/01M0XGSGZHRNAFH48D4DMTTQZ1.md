---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0y8bcck6g0hxc1dff8p6nh0
  text: |-
    ### research
    - Multitool takes the Router from git (`Package.swift` uses `.package(url:branch: main)`), and the checkout was at `f31f453`, not at the local Router HEAD `45a031a`. The old API compiled without one error. To build against the local HEAD without a commit, the Router dependency is now in edit mode: `swift package edit FoundationModelsRouter --path ../FoundationModelsRouter` (a `Packages/FoundationModelsRouter` symlink plus `.build/workspace-state.json`; no tracked file changes). A `sourcekit-lsp` index build kept the stale checkout directory alive, so it was moved aside inside `.build/`.
    - Router surface: `DetachmentParameterProviding` has `detachmentMount`, `detachmentTimeout(from:)`, `detachmentCollectInstruction`, `detachmentRunKind`, `detachmentCanceler`. `ToolDetachment.wrapping` mounts a String tool as `BackgroundTool` when the declared mount mode is `.background`, else `RunToCompletionTool`. `ToolRun` resolves the clock as `detachmentTimeout(from:) ?? mount.timeout`. `ToolContext.parkedRuns()` is now `backgroundRuns()` and `ParkedRun` is `BackgroundRun`. `DetachConfiguration.runToCompletionMount` and `nativeSessionMount` remain.
    - Multitool symbols that no longer compile: `MultiTool.detachmentClocks`, `Execute.detachmentClocks` and `Execute.detachmentMount` (`.detaching`), `ToolContext.parkedRuns` in `MultiTool+SandboxGlobals.swift` and `WaitTool.swift`, `ParkedRun` in the sandbox globals and the test fixtures, and every test mount written as `DetachConfiguration(mode: .detaching, waitSeconds:)`.
    - `SearchToolsTool` and `WaitTool` already declare `.runToCompletionMount` (synchronous, no clock). The card says searchTools "declares nothing". I keep that declaration: it declares no background mode, and its doc records that a 120-second work clock killed a real search. Removing it would put that clock back. If the intent is a full removal, say so in review.
    - The file verbs declare nothing today; they answer `@Generable` values, so `ToolDetachment` mounts them as `ContextBindingTool`, which is always inline.
  timestamp: 2026-08-26T05:23:09.843356+00:00
- actor: claude-code
  id: 01m0y97xbcsr74n7t1fgstp16k
  text: |-
    ### implement — discoveries
    - The Router HEAD `SessionEvent` has a new case, `runSettled(OperationEvent)`. The CLI turn drain in `Sources/MultitoolCLI/CLIRunner.swift` had an exhaustive switch and did not compile. The drain now prints one line for it: `<tool> run <token> settled: <outcome>`. A test in `CLITurnDrainTests` covers it. This is the "notify on settlement" half of the background contract, seen from the host.
    - `DetachConfiguration.defaultWaitSeconds` is gone from Router. `HardeningTests` compared the work bound against it; that one comparison is removed. The other comparison, against `defaultTimeoutSeconds`, stays and still pins the value.
    - A background `execute` call now answers before its command spawns. Two tests read state that the run body writes later, and they became races: the `ShellState` record in `ShellExecuteTests`, and the sandbox stamp in `RegisteredJournalOpTests` (a `true` command is off the plane before the snippet returns). Both now use `TestPoll.waitUntil`, which is the fixture that exists for a read that lags a call. No expectation was weakened.
    - `mcp__sah__files` `edit file` with `replace_all` replaced one occurrence only. Each later occurrence was edited on its own.
    - Prose that said "park" or named `DetachingTool`, `detachmentClocks` or `waitSeconds` in `Sources` and `Tests` is rewritten to the new vocabulary. One "park" remains in `JSCInterpreter.swift`: it is a verbatim quote from eventplan.md. The `waitSeconds` purge in `IntegrationTests` stays with the next task (`t73m7pw`).
  timestamp: 2026-08-26T05:38:44.716300+00:00
- actor: claude-code
  id: 01m0y986gqexjh0dqz4kkb6qtt
  text: |-
    ### implement — changed
    - Tools that declare the background: `MultiTool` (`runCode`) and `Execute` (`tools.shell.execute`). Each has `detachmentMount = DetachConfiguration(mode: .background, timeout: nil)`. `runCode` gives `configuration.executionTimeLimit` as its work bound through `detachmentTimeout(from:)`. `execute` gives no engine clock; its own `timeout` argument stays the one limit.
    - `ExecuteArguments` has no `wait` argument. The schema and the description say a mounted call always answers the completion token.
    - `SearchToolsTool` and `WaitTool` keep `.runToCompletionMount`. The file verbs declare nothing and stay `ContextBindingTool` (inline). `RunBinding.innerCallMount` stays `.runToCompletion`, and a test now pins its mode and its default timeout.
    - Every `ParkedRun`/`parkedRuns()` use is `BackgroundRun`/`backgroundRuns()`. `detachmentClocks` and `detachImmediatelySeconds` are gone.
    - CLI: `drainTurn` handles `SessionEvent.runSettled`.
    - New tests: `runCode` declares the background mount and its work bound (`MultiToolExecutionTests`, `SuspendedContextTests`); a mounted `execute` always answers the pending envelope, and its schema has no `wait` (`ShellExecuteTests`); a file verb mounted by the session answers inline (`FilesCapabilityTests`); the inner-call mount runs to completion (`RunBindingTests`); a settled run is printed by the CLI drain (`CLITurnDrainTests`).
    - Build: `swift build --build-tests` clean. Tests: `swift test` passed, 1023 tests in 73 suites, three runs in a row.
    - Not committed, in either repo. The Router dependency is in SwiftPM edit mode (`Packages/FoundationModelsRouter` symlink, untracked) so the Multitool build reads the local Router HEAD.

    step: implement
    outcome: changed
    evidence: Multitool `Sources/FoundationModelsMultitool/MultiTool+Detachment.swift`, `Capabilities/Shell/Execute.swift`, `MultiTool+SandboxGlobals.swift`, `WaitTool.swift`, `Sources/MultitoolCLI/CLIRunner.swift`, 17 test files; runCode and execute declare background; searchTools, wait and file verbs do not; build clean, 1023 tests green
    task: ^dmttqz1
  timestamp: 2026-08-26T05:38:54.103364+00:00
- actor: claude-code
  id: 01m0y9dvnpzbqnhtdtdnxpmy0g
  text: |-
    ### review — stuck
    - evidence: The review engine is bound to the Router repository root. `review sha HEAD~1..HEAD` reviewed the Router commit (4 `.kanban/` files, all excluded), not Multitool commit e4be355. `review file` with an absolute or relative Multitool path failed: "path escapes the repository root". The `cwd`, `root`, `workspace`, and `path` parameters did not change the root.
    - next: A person must start the review from a session that has `/Users/wballard/github/swissarmyhammer/FoundationModelsMultitool` as its workspace, with scope `HEAD~1..HEAD` (commit e4be355), and then record the findings on this task. The task stays in `review`.
  timestamp: 2026-08-26T05:41:59.606580+00:00
- actor: claude-code
  id: 01m0y9eqyx73d4841mnb8dmjyq
  text: |-
    ### finish iteration 1 — stuck
    - implement: changed — Multitool: runCode and execute declare background, `wait` argument removed from execute, searchTools/wait/file verbs synchronous, CLIRunner handles runSettled; 22 files
    - test: green — swift test in FoundationModelsMultitool, 1023 tests in 73 suites, 0 failed (three runs)
    - commit: e4be355 (Multitool), 4bcaaee (Router kanban state)
    - review: stuck — the local review engine is bound to the Router repository root and cannot read the Multitool checkout ("path escapes the repository root"). The review gate must run from a session opened in /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool with scope HEAD~1..HEAD (commit e4be355); record the result on this card. Task left in review; not forced to done.
  timestamp: 2026-08-26T05:42:28.573781+00:00
- actor: claude-code
  id: 01m0z7dt256fw90wdc5bbbx0jx
  text: |-
    ### review — findings (run by the peer session inside the Multitool checkout)
    - evidence: `review sha e4be355~1..e4be355`, backend local, 32 files reviewed — findings 3, confirmed 3, refuted 0, attempted 21, failed 0
    - next: work the three findings, then re-review against the CURRENT path (the file is now MultiTool+Background.swift) so the three declined hygiene rules can judge it

    Three code-hygiene rules declined an item because a later commit renamed the file: `function-length-swift`, `magic-numbers-swift`, and `missing-docs-swift` all report "found no file at Sources/FoundationModelsMultitool/MultiTool+Detachment.swift". Part of the commit is therefore unjudged; a re-review at the new path or a later sha closes that.
  timestamp: 2026-08-26T14:26:15.237510+00:00
- actor: claude-code
  id: 01m0zdfnk484pb28q78k2df4hd
  text: |-
    ### implement — the three findings, and the repository sweep

    **The three findings were already correct at HEAD.** Commit `74b7f84`
    ("conform to BackgroundTool and the ToolMount names", card ^d1c69ab) landed
    after the reviewed commit `e4be355`. It renamed `detachedRunSleepSeconds` to
    `backgroundRunSleepSeconds` at the declaration, at the doc reference, and at
    all three uses (lines 473, 499, 526), and it corrected the comment near line
    56. `rg -i 'detach' Tests/FoundationModelsMultitoolTests/ShellExecuteTests.swift`
    finds nothing, thus the cause is gone from the whole file. This is measured,
    not assumed.

    **The sweep.** A finding shows one example of a cause, thus I looked for the
    same cause in the full repository:
    `rg -i 'detach|parked|park\b|parking'`. Router at `cc94cce` has no such word
    in `Sources`, thus every survivor is the Multitool's own.

    Changed — four sites in the main package, all prose:

    - `Tests/FoundationModelsMultitoolTests/Fixtures/PollFixtures.swift` — "the
      call that parked it" became "the call that started it". This one was the
      design word: it named what a background call does.
    - `Sources/FoundationModelsMultitool/Diagnostics/CallTrace.swift` — "Every
      thread parked on a condition variable" became "Every thread that waits on a
      condition variable".
    - `Tests/FoundationModelsMultitoolTests/HardeningTests.swift` — a test display
      name and a comment. "while it's parked awaiting a pending tools.* promise"
      became "while it waits on a pending tools.* promise"; "its time parked in
      the interpreter's promise pump" became "its time in the interpreter's
      promise pump". No test matches on these strings, and the test count did not
      move.
    - `Tests/FoundationModelsMultitoolTests/JSCInterpreterTests.swift` — a test
      display name. "a snippet parked on a pending call" became "a snippet that
      waits on a pending call".

    Not changed, with the reason:

    - `Sources/FoundationModelsMultitool/Interpreter/JSCInterpreter.swift` — the
      word sits inside a sentence quoted word for word from `eventplan.md` ("We do
      not build a semaphore-based park mechanism and its thread guards only to
      delete them later."). To edit a quotation makes it a false quotation. The
      source document must change first.
    - `IntegrationTests/**` — 48 sites in 7 files, and they include real
      identifiers: `ParkedShellRun`, `parkedRun`, `parked` in
      `Support/ShellElevationRunner.swift`. Card ^t73m7pw names that same file and
      orders it renamed to the background vocabulary, thus a written card holds
      this work already.
    - `HardeningTests.swift` line 17 says "the elevation engine". Card ^t73m7pw
      also holds this: it asks for `rg -il 'elevat'` to find nothing.
    - `README.md` — three sites, and they are worse than vocabulary. The README
      says a `RoutedSession` "mounts each vended tool under
      `DetachConfiguration.nativeSessionMount`", but Router at `cc94cce` has no
      `DetachConfiguration` and no `nativeSessionMount`; the type is now
      `ToolMount`, and a tool declares its own `var mount: ToolMount?`. It also
      says the tools "cannot detach at all" and "never detachment". To correct
      this needs a statement about how a bare `LanguageModelSession` behaves now.
      That is a design statement I must not invent, thus I report it instead of
      guessing. No card holds it yet.
    - `plan.md` and `eventplan.md` — the design documents that record the earlier
      design. They are history.

    **Gates.** `swift build --build-tests` clean. `swift test` passed, 1023 tests
    in 73 suites, which is the baseline exactly.
    `swift build --package-path IntegrationTests --build-tests` clean (with
    `--disable-automatic-resolution`, because a plain run timed out while it
    fetched `mlx-swift-lm` from the network — an environment fault, not a code
    fault). Router untouched: HEAD stays `cc94cce` and its working tree holds only
    this card's own `.kanban` files. Nothing is committed in either repository.
  timestamp: 2026-08-26T16:12:07.652552+00:00
- actor: claude-code
  id: 01m0zdpm5933x8n01z0hx3gj8m
  text: |-
    ### implement — changed
    - evidence: 4 files in `../FoundationModelsMultitool` — `Sources/FoundationModelsMultitool/Diagnostics/CallTrace.swift`, `Tests/FoundationModelsMultitoolTests/Fixtures/PollFixtures.swift`, `Tests/FoundationModelsMultitoolTests/HardeningTests.swift`, `Tests/FoundationModelsMultitoolTests/JSCInterpreterTests.swift`. 8 lines changed, all prose. `swift build --build-tests` clean, zero warnings. `swift test` passed, 1023 tests in 73 suites, the baseline exactly. `swift build --package-path IntegrationTests --build-tests` clean. Router HEAD stays `cc94cce`, code untouched. Nothing committed.
    - next: `/review`. Run it from a session whose workspace is the Multitool checkout, because the review engine binds to the repository root and refuses a path outside it. Scope the run at the working tree, not at `e4be355`, so the three hygiene rules that declined `MultiTool+Detachment.swift` can judge the file at its present name, `MultiTool+Background.swift`.

    The wording change is the task itself, thus `public-output-contract` check 1 (gratuitous reformatting of an existing message) does not hold: its written exception is "the task explicitly asked to change the message". Two test display names changed. No CI job selects a test by name (`rg -- '--filter|--skip'` finds nothing), and the test count did not move.

    New card raised for work found in the sweep: ^xpbhgac, "Multitool: correct the README's stale mount vocabulary". The README names `DetachConfiguration.nativeSessionMount`, which Router at `cc94cce` does not have.
  timestamp: 2026-08-26T16:15:55.561392+00:00
- actor: claude-code
  id: 01m0ze4wtzzjgj46w6dsz5kw9m
  text: |-
    ### observation while the review runs — a garbled sentence, and the doc length

    I read `Sources/FoundationModelsMultitool/MultiTool+Background.swift` at `1b5cf2d` while the review engine worked. Two things, recorded here so they are not lost if the engine does not report them.

    **1. A garbled sentence, line 49 and 50.** The doc of `mount` opens:

    > "The mount every `runCode` call carries: the background, whatever mount the composition site applies."

    That sentence does not parse. The meaning is that the mount is always background, and that a mount declared by the tool wins over the mount the composition site applies (which the next paragraph then says again, correctly: "A declared mount wins over the site"). Correct it to one clear sentence, for example:

    > "The mount every `runCode` call carries. It is always background, and it wins over the mount the composition site applies."

    **2. The doc comments are much longer than the code.** In this file:
    - `collectInstruction(forCompletionToken:)` — 20 lines of doc, 8 lines of code.
    - `mount` — 14 lines of doc, 3 lines of code.
    - `timeout(from:)` — 29 lines of doc, 3 lines of code.

    The user asked for shorter doc comments in this body of work ("way too long of /// comments"). Not every line here is waste: the paragraph on the two clocks (the engine timeout resets on progress, the watchdog does not) states a real safety property that the code cannot show, and the `^4qcf1v9` measurement (21 rounds, about 1700 seconds for an eight-second run) is the evidence for the collect sentence. Those earn their place.

    The rest repeats what the code says. A person should decide the cut; I did not edit the file, because it is under review and a stable tree was promised.
  timestamp: 2026-08-26T16:23:43.199436+00:00
- actor: claude-code
  id: 01m0ze7zc0bzsztem7mwyf9zme
  text: |-
    ### loop state at 2026-08-26 16:26 — read this first after a restart

    **Where this card is.** Implement is done and committed. The card waits ONLY for a review result. It is not stuck: the engine is running and is making progress.

    - Multitool HEAD: `1b5cf2d` "docs: remove parked wording from trace and test text". Working tree clean.
    - Router HEAD: `cc94cce`. Verified by hand at 16:26: build clean, 0 errors and 0 warnings from our code; `swift test` 1058 tests in 104 suites plus 83 tests in 10 suites passed, with the same 2 known issues.
    - The 3 findings of this card are closed and were verified in the tree, not only checked off.

    **Why a second session is doing the review.** The `review` engine binds to the repository root of the calling session. This session's workspace is the Router, so it refuses a Multitool path. Session `foundationmodelsmultitool-7b` was asked at about 16:05 to run two passes:
    1. `review sha HEAD~1..HEAD` — commit `1b5cf2d`.
    2. `review file Sources/FoundationModelsMultitool/MultiTool+Background.swift` — needed because an earlier review declined three hygiene rules on this file when it carried its old name, `MultiTool+Detachment.swift`.

    That limit is now its own card, ^kq4cxva.

    **What to do when the findings arrive.** Record them word for word as a dated `## Review Findings` section on this card. No severity tiers. If clean, the card goes to `done` and the Router `.kanban` change is committed there (the board lives in the Router, and the Multitool has no board of its own).

    **Two observations already recorded above, which the engine may or may not repeat.** A garbled sentence at `MultiTool+Background.swift:49`, and doc comments much longer than the code they describe.

    **Do not edit anything in the Multitool checkout while the review runs.** A promise of a stable tree was given, and a stash or revert race is exactly how work has been lost here before. The next cards, ^t73m7pw and ^xpbhgac, are both in that checkout and are both fully scoped and ready to start the moment this card closes.
  timestamp: 2026-08-26T16:25:24.096772+00:00
- actor: claude-code
  id: 01m0zeeck0xjmedrbncacy6j6k
  text: |-
    ## Review Findings (2026-08-26 16:35)

    Two passes, run by session `foundationmodelsmultitool-7b` because the engine cannot reach this repository from a Router session (see ^kq4cxva).

    **Pass 1** — `review sha HEAD~1..HEAD` on `1b5cf2d`: CLEAN. findings 0, confirmed 0, refuted 0, attempted 7, failed 0, skipped 0. 4 files reviewed, 0 not reviewed. No declined rules.

    **Pass 2** — `review file Sources/FoundationModelsMultitool/MultiTool+Background.swift`: 1 finding, confirmed. attempted 7, failed 0. The three hygiene rules that declined the file under its old name `MultiTool+Detachment.swift` (`function-length-swift`, `magic-numbers-swift`, `missing-docs-swift`) judged it this time and reported nothing. **That gap is closed.**

    The finding, word for word:

    - [ ] `Sources/FoundationModelsMultitool/MultiTool+Background.swift:42` `completeness/public-output-contract` — The collectInstruction method omits the seconds parameter when instructing to call wait(). The actual wait() function in MultiTool+SandboxGlobals.swift:266 requires both completionToken and seconds. This incomplete instruction will cause model calls to fail when attempting to collect background runs. Update the collectInstruction to specify both parameters, e.g.: 'Call the wait tool with completionToken "\(completionToken)" and a timeout in seconds to collect the result.' Also update line 46 to include a seconds value when retrying after timeout.

    ### This finding is refuted. Do not apply it.

    It reads two different surfaces as one. Both are named "wait", and that is the trap:

    1. **The mounted `wait` TOOL** — what a MODEL calls, and what `collectInstruction` speaks to. Its arguments are `WaitArguments` at `Sources/FoundationModelsMultitool/WaitTool.swift:8`.
    2. **The `wait()` SANDBOX GLOBAL** — what a JS SNIPPET calls inside `runCode`. That is the declaration the finding cites at `MultiTool+SandboxGlobals.swift:266`: `declare function wait(completionToken: string, seconds: number)`.

    `collectInstruction` names the first one. It says "Call the wait tool" at line 42 and "call the wait tool again" at line 46. It never names the global.

    The finding is wrong on all three of its claims about the tool:
    - **There is no `seconds` parameter on the tool.** The field is `timeout`, at `WaitTool.swift:23`.
    - **It is not required. It is optional** — `public var timeout: Double?` at `WaitTool.swift:23`, and its `@Guide` says "Omit it to use the host's own bound."
    - **`completionToken` is optional too** — `public var completionToken: String?` at `WaitTool.swift:14`.

    So a `wait` tool call carrying only a completion token is valid and is the documented way to take the host's bound. The present instruction is correct.

    **Applying the fix would cause the failure the finding predicts.** It would tell the model to send `seconds`, which `WaitArguments` does not declare. That is an invalid argument on the one call a model makes when a background run settles — the exact path this card exists to make work.

    Acting on this would break the product, so it is not applied. The finding is recorded here in full, with the evidence against it, rather than dropped in silence. A person should confirm this reading before the card closes.
  timestamp: 2026-08-26T16:28:54.240733+00:00
- actor: claude-code
  id: 01m0zeff96rjzn2zgvhvypt36z
  text: |-
    ### finish iteration 3 — stuck, and it needs a person

    - implement: changed — the 3 findings of this card were already correct at HEAD and were verified in the tree, not only checked off; a repository sweep then fixed 4 more "parked" sites (8 lines, all prose)
    - test: green — Multitool `swift build --build-tests` clean with zero warnings; `swift test` 1023 tests in 73 suites passed, the baseline exactly; `IntegrationTests` builds clean
    - commit: 1b5cf2d docs: remove parked wording from trace and test text
    - review: pass 1 CLEAN (0 findings over 4 files); pass 2 gave 1 confirmed finding at `MultiTool+Background.swift:42`

    **Why the card is stuck and not done.** The one finding is refuted by the code, with the evidence in the comment above. It reads the mounted `wait` TOOL and the JS `wait()` SANDBOX GLOBAL as one surface because both are named "wait". Applying its suggested fix would tell the model to send a `seconds` argument that `WaitArguments` does not declare, and would break the collect path this card exists to make work.

    That is a rule fighting a documented contract, which is a true conflict. The standing instruction for a true conflict is to record it, mark the task stuck, and stop. A person resolves it, and a person does not have to be me.

    **What a person must decide.** One of:
    1. Agree the finding is a false positive. The card then closes with no code change, and the two-surfaces-one-name trap is worth recording for the rule.
    2. Show that the reading is wrong. Then the correct fix is applied — but note that `WaitArguments` would have to change first, because the tool has no `seconds` field today.

    **Everything else on this card is finished.** The hygiene gap that the old file name caused is closed: `function-length-swift`, `magic-numbers-swift` and `missing-docs-swift` all judged `MultiTool+Background.swift` this time and reported nothing.

    Two observations recorded earlier are still open and are NOT findings: the garbled sentence at line 49, and doc comments much longer than the code they describe.
  timestamp: 2026-08-26T16:29:29.766638+00:00
- actor: claude-code
  id: 01m0zegntv8pwmbq9xfrn7x7nx
  text: |-
    ### the refutation is independently confirmed, and it WILL recur

    Session `foundationmodelsmultitool-7b` checked the rebuttal against the source rather than take it on trust, and confirms every point. It adds one fact that settles the matter beyond doubt:

    **`MultiTool+SandboxGlobals.swift:266` is not a Swift declaration at all.** It is a line of TypeScript inside a `SandboxGlobalDoc` string literal: `declare function wait(completionToken: string, seconds: number)`. It is documentation text handed to a JS sandbox. It declares nothing in Swift, so it cannot state the contract of a Swift tool.

    **The engine is stateless, so this finding will come back.** `review` takes a scope, returns counts and findings, and remembers nothing between runs. There is no place to suppress or annotate a finding. A future pass over this file will very likely raise the same one. This card is the durable record. If it becomes noise, the lever is the validator rule `completeness/public-output-contract`, not the run.

    **Name the trap, because it is a property of the design and not a mistake in it.** This package has two `wait` surfaces with one name:
    1. a mounted TOOL with Optional arguments, which a MODEL calls;
    2. a JS GLOBAL with required positional arguments, which a SNIPPET calls inside `runCode`.

    A rule that matches a declaration by name will find whichever comes first and then read the other one's contract. Any name-matching rule can make this same error. Whoever meets it next should check WHICH `wait` a finding is talking about before believing it.
  timestamp: 2026-08-26T16:30:09.243202+00:00
- actor: claude-code
  id: 01m101hhz72rx9wp6xq0tmwzx8
  text: |
    ## Review Findings — resolved by the user (2026-08-26)

    - [x] `MultiTool+Background.swift:42` `completeness/public-output-contract` — "The collectInstruction method omits the seconds parameter when instructing to call wait()."

    **The user read the refutation and closed the card.** The finding is a false positive. No code change was made, and none was correct: the mounted `wait` tool declares `completionToken: String?` and `timeout: Double?`, both Optional and neither named `seconds`. The `seconds` the finding cites belongs to the JS sandbox global, which is a line of TypeScript inside a string literal at `MultiTool+SandboxGlobals.swift:266` and states no Swift contract. Applying the fix would have told the model to send an argument `WaitArguments` does not declare, breaking the collect path this card exists to build.

    **The two observations are both closed, and neither is a finding.**

    1. The garbled sentence at line 49 is repaired. It now reads: "The mount every `runCode` call carries. It is always background." Verified in the tree, not assumed.
    2. The doc-length observation was taken up as its own card, `^f1j3ymz`, which is done. This file now stands at 79 doc lines to 57 code lines. Still doc-heavy, and deliberately so: what survives here is the two-clocks safety property and the `^4qcf1v9` measurement, which the code cannot state.

    **One thing to carry forward.** The review engine is stateless, so this finding will very likely be raised again by any future pass over this file. There is nowhere to suppress it. The cause is a real property of the design: two surfaces named `wait`, one a tool with Optional arguments that a model calls, one a JS global with required positional arguments that a snippet calls. Any rule that matches a declaration by name can read the wrong one's contract. This card is the durable record of that trap.

    - next: none. Card closes.
  timestamp: 2026-08-26T22:02:40.999507+00:00
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
- 01M0XGRYMR1GPMY1X52FTDMR58
position_column: done
position_ordinal: ffff8780
title: 'Multitool: declare the background tools'
---
## What
Cross-repo task in `../FoundationModelsMultitool` (sibling checkout). First of three Multitool tasks. Apply the declaration API fixed by Router task ^19c9vv4 — a long-running tool declares `var detachmentMount: DetachConfiguration? { DetachConfiguration(mode: .background, timeout: ...) }`; an undeclared tool is synchronous:

- [x] `runCode` (`Sources/FoundationModelsMultitool/MultiTool.swift`, `MultiTool+Detachment.swift`) declares background — a snippet can run for hours. Its per-call work bound moves to the timeout-only member that replaced `detachmentClocks(from:)` (`MultiTool+Detachment.swift:98` bounds each call at `configuration.executionTimeLimit`).
- [x] Shell execute (`Capabilities/Shell/Execute.swift`, `ShellRunner.swift`) declares background. Remove the model-facing `wait` argument from `ExecuteArguments` (`Execute.swift:136-158`) and from the schema and description — it controlled the block window, which no longer exists.
- [x] `searchTools` (`Discovery/SearchToolsTool.swift`) and the file verbs (`Capabilities/Files/**`) declare nothing — synchronous.
- [x] Inner `tools.*` calls through `ToolInvoker` stay run-to-completion (`RunBinding.innerCallMount`) — verify, unchanged.

## Acceptance Criteria
- [x] A test proves `runCode` and `execute` always answer with the pending envelope.
- [x] A test proves `searchTools` and a file verb answer inline.
- [x] The rendered `execute` schema has no `wait` argument. A test asserts on the schema.
- [x] FoundationModelsMultitool builds against the updated Router.

## Tests
- [x] Update `Tests/FoundationModelsMultitoolTests/ShellExecuteTests.swift`, `MultiToolExecutionTests.swift`, and the capability-registration tests.
- [x] Run `swift test` in `../FoundationModelsMultitool` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings

From `review sha e4be355~1..e4be355`, backend local, 32 files. All three name
the same cause: "detached" vocabulary that stayed in
`Tests/FoundationModelsMultitoolTests/ShellExecuteTests.swift`. The correct
word is "background".

- [x] The identifier `detachedRunSleepSeconds`, near line 473. Rename it to
  `backgroundRunSleepSeconds`.
- [x] The identifier `detachedRunSleepSeconds`, near line 499. Rename it to
  `backgroundRunSleepSeconds`.
- [x] The identifier `detachedRunSleepSeconds`, near line 526, and the comment
  near line 56 that speaks of "the detached tests". Rename the identifier and
  correct the comment.

Each of the three was already correct at HEAD `55f6ea5`. Commit `74b7f84`
renamed the declaration, the doc reference and all three uses, and corrected
the comment. This is verified, not assumed: `rg -i detach` on that file finds
nothing, thus the cause is gone from the whole file and not only from the
three lines the findings name.

A sweep of the full Multitool repository followed, because the same cause can
live in other files. It removed four more sites of this vocabulary from the
main package. The comment thread gives the sweep and what stays for other
cards.