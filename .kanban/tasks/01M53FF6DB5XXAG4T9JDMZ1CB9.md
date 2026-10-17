---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53jqk5je7faeghapts0d7g1
  text: |-
    Research and run log (implement step):

    - The repo sourcekit-lsp was stopped. `swift package --manifest-cache local update FoundationModelsExtras` ran in the Router and in IntegrationTests. Both Package.resolved files pin 7a40759a5f8ee81443f9f72d4799ca7e70eaead1 (main). Package.resolved is gitignored, so this gives no tracked diff.
    - WARNING for the next agent: `sah serve` starts the sourcekit-lsp of this repo again after a kill. It then builds index-build directories inside .build/checkouts. Stop it again before each swift command.
    - The first full run did not end. After 28 minutes the test helper used 0% CPU. One test waited forever: StoppedAnswerOtherWorkEventTests/questionOfOtherWorkWhileTheStoppedAnswerWindsDown. All other tests of the main target passed, and no test failed. I stopped the test helper to get the output.
    - Cause: an old expectation, not a Router defect. Extras f451cc7 (R1): the sweep of cancelAll() puts each open run token in `cancelledRunTokens`. A question of such a token now ends at once with `RunPlane.runCancelledReason`, and no event is posted. The test asked from the two runs that the sweep cancelled, and waited for one post. That post never came.
    - Fix (test only): the question test now starts a third run of other work after the stop. The sweep had its run list before this run started, so the run is not cancelled. Its question opens and posts. The run of the stopped answer asks too, and its question posts nothing.
    - Another finding: the question of the later run becomes run mail (SessionOutbox.stage), so its output has the origin `.mail([run mail id])`, not the origin of its poster. The runs that the sweep stopped make no mail (`ignoredRuns`), so their posts keep the poster origin. Thus the question test checks one post, and an origin that is not the mail of the stopped answer. The helper was split: `postsOfOtherWork(of:from:in:alsoOpening:)` closes the session and gives the posts. `expectOnlyThePostOfOtherWork` keeps the poster-origin check for the other six tests.
    - The `pattern` and length change of Extras made no test fail.
  timestamp: 2026-10-17T00:03:35.218054+00:00
- actor: claude-code
  id: 01m53jqvfmmjmpedkx00frgxze
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/StoppedAnswerOtherWorkEventTests.swift. `swift test --filter 'FoundationModelsRouterTests.StoppedAnswerOtherWorkEventTests'`: 7 tests passed. Full `swift test` (after the fix): 1794 tests in 217 suites passed with 1 known issue (the RealModelHarness `withKnownIssue`), plus 26 and 19 tests passed, exit 0. `swift build --package-path IntegrationTests --build-tests`: Build complete, exit 0. The only warning is the SwiftPM "missing creator for mutated node" of mlx-swift_Cmlx.bundle, which other cards already record.
    - next: review
  timestamp: 2026-10-17T00:03:43.732243+00:00
position_column: doing
position_ordinal: '80'
title: Move to Extras 7a40759 (R1 cancel ends questions, JSON Schema pattern and length)
---
Source: elicitation check of 2026-10-16 (elicitation-plan.md section 10), item 0. Request from the coordinating session.

Extras 7a40759 (main) changes two behaviors:
- R1: a cancelled token asks no new question, and a cancel ends the questions of each token.
- `pattern` and length checks follow JSON Schema.

- [x] Stop the sourcekit-lsp of the repo. Run `swift package --manifest-cache local update FoundationModelsExtras` in the Router and in IntegrationTests. Confirm that Package.resolved pins 7a40759 or a later main commit.
- [x] Run the full suite one time. Correct each test that expects the old behavior. Do not change a test that shows a real defect; record it on this card.
- [x] Build IntegrationTests one time.
#elicitation-fixes