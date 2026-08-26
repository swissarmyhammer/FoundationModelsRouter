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
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
- 01M0XGRYMR1GPMY1X52FTDMR58
position_column: review
position_ordinal: '80'
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