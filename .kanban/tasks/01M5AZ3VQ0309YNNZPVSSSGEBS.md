---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5b41tv1wbq8nj6z4fmtyq5y
  text: |-
    Implementation landed (not committed).

    Design: `PromptHookLedger` has a new set `replaced` of screening mail that a replace changed. `noteReplace(of:)` adds an id only while the mail is screening; `isReplaced(_:)` reads it; `endScreen(of:)` and `forget(_:)` remove it. `performReplace(_:with:)` calls the new `notePromptReplace(of:)` after a successful queue replace. `admitScreenedPrompt` skips the text of the chain when `isReplaced` is true. `performReplace` and `admitScreenedPrompt` both run on the session actor, so no replace can come between the check and the body change. `blockScreenedPrompt` does not read the flag, so a block still blocks.

    Why a flag and not a body compare: a replace with a body equal to the first body must still win; a compare cannot see that replace.

    A replace before the chain starts (mail marked, `beginPrompt` not yet called) also gets the flag; the chain then reads the first text, and the replaced body still wins. This agrees with "a replace is not screened".

    FoundationModelsHooks `PrePrompt` is not re-documented in this package, so no doc change there. Docs changed: `RoutedSession.replace(_:with:)`, `performReplace(_:with:)`, the extension doc and `admitScreenedPrompt` in `RoutedSessionActorPromptHooks.swift`, and `PromptHookLedger`.

    Tests: 4 new tests in `PromptHookTests` (section "Replace signals"). The chain waits on a `RunLatch` that the test opens after the replace signal ended (`signalDone`), so the order is deterministic. Only "a replace while the chain runs wins over the text of the chain" was RED before the fix (the model got "replaced question"); the other three state behavior that already held. `aCancelWhileTheChainRunsEndsTheMail` now uses the new `gatedVisitor` and `waitForTheChain` helpers in place of its inline copy.
  timestamp: 2026-10-19T22:20:57.569248+00:00
- actor: claude-code
  id: 01m5b41xpfkkp5q22303avexc4
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Session/PromptHookLedger.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorPromptHooks.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCancellation.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Tests/FoundationModelsRouterTests/PromptHookTests.swift. `swift test --filter FoundationModelsRouterTests.PromptHookTests`: RED 1 failing test of 14, then GREEN 14 of 14. Full `swift test`: exit 0, 1911 tests in 236 suites passed (9 known issues), plus 26 and 19 in the other targets.
    - next: review
  timestamp: 2026-10-19T22:21:00.495846+00:00
- actor: claude-code
  id: 01m5b44m1ttdb7ztdpeyq32at0
  text: |-
    ### test — green
    - evidence: I touched the 5 changed Swift files. Then I ran `swift test` one time at the root: 1911 tests in 236 suites passed, 0 failures, 0 skipped. The run has 9 known issues. They come from 9 withKnownIssue calls in PromptWaitTests, TaskEndEventWaitTests, ManualRunClockWaitTests and RealModelHarnessTests. None of these files is in this change. Two smaller test runs also passed (26 tests, and 19 tests).
    - evidence: `cd IntegrationTests && swift build --build-tests` finished with Build complete.
    - warnings: only the known mlx "missing creator for mutated node". There are no other compiler warnings.
    - next: review.
  timestamp: 2026-10-19T22:22:28.922462+00:00
depends_on:
- 01M5AS7RT8YA6KWDKXHQHWVD8S
position_column: doing
position_ordinal: '80'
title: A replace of a queued mail is not screened, and a replace during the chain is not lost
---
## Context
Found while doing ^qhwvd8s (Router emits PrePrompt and PostPrompt for each mail).

The session screens each `userMessage` and `agentMessage` mail with one `PrePrompt` when `mail(_:)` puts it in the queue (`RoutedSessionActorPromptHooks.swift`). The signal `replace(_:with:)` (`performReplace(_:with:)` in `RoutedSessionActorCancellation.swift`) changes the body of a queued mail in place, and the model then gets the new text.

## Decision (the user, 2026-10-19)
**A replace is not screened.** The replaced text goes to the model as the caller gave it, with no new `PrePrompt`. A guard visitor does not see replaced text. Write this in the docs.

## What
- **Replace after the screen ended:** no change in behavior. The model gets the replaced text. Write the rule in the doc comments of `replace(_:with:)` and of the `PrePrompt` emission (`RoutedSessionActorPromptHooks.swift`), and in the doc comment of `PrePrompt` in FoundationModelsHooks if this package re-documents it.
- **Replace while the chain runs:** the replace must win, and it must not be lost. Now, when the chain also changes the text, `admitScreenedPrompt` builds the new body from the body that the chain read, so the replace is lost. Correct it: when a replace came while the chain ran, `admitScreenedPrompt` keeps the replaced body and ignores the text of the chain's `.proceed(e)` or `.approved(e)`. A `.blocked(reason)` result still blocks the mail, because the mail itself was screened and blocked.
- The mail still gets exactly one `PostPrompt`.

## Acceptance Criteria
- [x] A replace after the screen ended: the model gets the replaced text, and no second `PrePrompt` comes.
- [x] A replace while the chain runs, and the chain replaces the text: the model gets the text of the `replace` signal, not the text of the chain.
- [x] A replace while the chain runs, and the chain gives `.proceed`: the model gets the replaced text.
- [x] A replace while the chain runs, and the chain blocks: the mail is blocked.
- [x] Each mail gets exactly one `PostPrompt`.
- [x] The doc comments state the rule "a replace is not screened".

## Tests
- [x] `Tests/FoundationModelsRouterTests/PromptHookTests.swift` (Swift Testing): each criterion above, with a slow test visitor so that the replace comes while the chain runs.
- [x] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks