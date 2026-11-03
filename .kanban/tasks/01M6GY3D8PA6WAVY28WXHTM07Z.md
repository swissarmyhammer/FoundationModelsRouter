---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6h71j8513t84chx8wxnyyq2
  text: |-
    ### DESIGN (decided by the implementer)
    Fact found: an answer at a session gives NO event on its feed. The feed shows an end (elicitationEnded) only when a cancel ends the question. So the child feed alone cannot tell the relay about an answer. The relay needs a new signal.

    Design:
    1. A Router session gets an internal answer feed: one id for each question that a client answered with respond(...) and that resumed the run (delivery .delivered). A URL-mode accept gives no id (the completion comes later on the feed). A completion gives no id.
    2. SubagentQuestionRelay subscribes to the answer feed of the child at the same time as the feed of the child, before the first mail. A child that is not a Router session has no answer feed (known limit, as for the end).
    3. When the relay reads an id from the answer feed, and the relayed question is still open at the parent, the table marks it as answered below. The relay ends the copy in the parent at once, one time, with cancel and the reason "answered at the child" (public constant SubagentQuestionRelay.answeredAtChildReason). The task of the question then resumes and does nothing in the child.
    4. An id can come before the relay sent the question up. The table keeps such an id for its relay (dropped when the relay closes). The relay then ends the copy as soon as the parent recorded it.
    5. A later answer at the parent for the same id finds no open question: .noPendingElicitation, and the child run keeps the first answer.
    6. No change when the parent answers first: the table has no open entry, so the id from the answer feed (that the relay itself caused) ends nothing.
    7. Outcome: Extras has no end reason for this. The closest existing outcome is a cancel response with a reason string. No change in Extras.
    8. The feed of the child itself does not change (no new SessionEvent case). A new case would change every feed order test.
  timestamp: 2026-11-03T17:24:22.917870+00:00
- actor: claude-code
  id: 01m6h7hzcb868qdc8e7pztpmxr
  text: |-
    ### implement — changed
    - evidence: full swift test: 2323 tests in 281 suites passed, 0 failures, 0 new warnings. New or changed tests: 3 in SubagentSessionAccessTests (answer at child ends parent copy at once; later parent answer gives .noPendingElicitation; parent answers first ends nothing), 3 table tests in SubagentQuestionRelayTests.
    - RED: the first test waits for the parent end with the relaying gate closed. It hung before the change (the old end came only at the close of the child).
    - files: SubagentQuestionRelay.swift, RoutedSessionActorRelayedQuestions.swift, RoutedSessionActor.swift, RoutedSessionActorQueueing.swift, SessionEvent.swift (doc), RoutedSession.md (doc), two test files.
    - note: the end outcome is a cancel with reason "answered at the child" (SubagentQuestionRelay.answeredAtChildReason). Extras has no special reason; no change in Extras.
    - note: an answered-early id of a question that the parent answered itself stays in a per-relay set until the relay closes (small, bounded by the relay life).
    - next: review
  timestamp: 2026-11-03T17:33:20.651796+00:00
position_column: review
position_ordinal: '80'
title: An answer at the child ends the relayed copy of the question in the parent
---
## What
When a host answers a question through the child session (`child.respond(elicitationId:response:)`), the relayed copy of the question stays open in the parent until the relay ends (the child closes). It then ends once, as a cancel with reason "run cancelled". Found by the tests of card 01M6GJJKPTESHZGW7N2AAY83G3 (`SubagentSessionAccessTests`).

If both levels answer, the parent still takes its answer and sends it down, but the child keeps the first answer.

Do (design first, in a task comment): the `SubagentQuestionRelay` ends the relayed copy in the parent as soon as the child question ends, with an outcome that says it was answered at the child. Check `RoutedSessionActorRelayedQuestions.swift` and `SubagentQuestionRelay.swift`.

Low priority. It blocks nothing: the host suppresses the relayed copy.

## Acceptance Criteria
- [ ] An answer through the child ends the parent copy at once, once.
- [ ] A later answer at the parent for the same id changes nothing.
- [ ] No change when the parent answers first.

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/SubagentSessionAccessTests.swift` or add a relay test file.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents