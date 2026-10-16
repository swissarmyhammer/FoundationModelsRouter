---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m51g00mycm47z1f572nb69n5
  text: |-
    Research done.

    - Callers of `deliverLive(_:)`: `deliverLive(_:origin:)` (run events: runProgress, runMessage, runSettled, elicitationRequested), `deliver(invocation:)`, `deliver(report:)`, `deliver(display:)` (posts of a tool, with the task-local origin of the poster), and the own events of the answer: `report(generationCall:)`, `submissionDidStart` (submissionStarted), `drainGenerationPassPhases()` (submissionQueued and pass phases). Direct users of `currentAnswerEventSink`: the automatic compaction inside the answer and the stall report. These are the work of the answer itself.
    - Decision: the posts of a poster (run events, question posts, toolInvocation, toolCallReport, toolDisplay) get one route: the sink of the running answer, but the session feed with no audience while `openAnswerMail.isSilenced`. The poster decides the drop: run events and question posts through the existing poster guard, and tool posts through the hub (their output origin is the task-local origin of the poster, and the hub drops an origin that holds a silenced mail). The own events of the answer keep `deliverLive(_:)` with no change, so they stay on the sink of the stopped answer and the hub drops them by audience. `deliverQuestionPost(_:origin:)` then is the same as `deliverLive(_:origin:)`, so it goes away.
    - A swept run terminal of `cancelAll()` has the signal as poster (the sweep task inherits the origin of the signal). It is also dropped today while the stopped answer winds down. A run that the stopped answer started inherits the mail origin of that answer, so its posts stay dropped.
    - Test shape: the BackgroundingBackend holds the first answer at a gate that ignores the cancel, so the stopped answer continues. A `.process` fake run of other work holds its canceler (CancelerHold), so the sweep does not settle it. Each post is awaited through the outbox (the journal write or the observer call ends before the post returns), then the test closes the session and reads the feed to its end. No sleeps or polls.
  timestamp: 2026-10-16T04:37:16.574421+00:00
- actor: claude-code
  id: 01m51gfwtj6axbqwzgjry04wnw
  text: |-
    ### implement — changed
    - evidence: 4 files changed, 1 file added.
      - Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift: new `deliverPost(_:)`, the one route of a post (run events, question posts, toolInvocation, toolCallReport, toolDisplay). While `openAnswerMail.isSilenced`, it sends session-scoped with no audience; else it uses `deliverLive(_:)`. `deliverLive(_:origin:)` keeps the poster drop guard and now calls `deliverPost(_:)`. `deliverQuestionPost(_:origin:)` and the private `deliver(_:origin:through:)` are removed, because they became the same as `deliverLive(_:origin:)`. The own events of the answer (submissionStarted, pass phases, generationCall, compaction, stall) keep `deliverLive(_:)` / `currentAnswerEventSink`, so the hub still drops them for the stopped answer. The rule is in the doc of `deliverPost(_:)`.
      - Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift: doc of `currentAnswerEventSink`.
      - Sources/FoundationModelsRouter/Session/RoutedSession.swift: `cancelAll()` doc, step 2: events of other work still go out while the stopped answer winds down. No API change.
      - Tests/FoundationModelsRouterTests/Helpers/SessionOutputPositions.swift: SessionEventCase gets runProgress, runMessage, toolInvocation, toolCallReport, toolDisplay.
      - Tests/FoundationModelsRouterTests/StoppedAnswerOtherWorkEventTests.swift (new): 7 fixed-order tests, one for each dropped kind. Each also posts the same kind from a run of the stopped answer and expects it dropped.
    - red (on the old code, `swift test --filter StoppedAnswerOtherWorkEventTests`, 7 tests in 1 suite, 7 issues): progressOfOtherWork..., messageOfOtherWork..., questionOfOtherWork..., terminalOfOtherWork..., invocationOfOtherWork..., reportOfOtherWork..., displayOfOtherWork...WhileTheStoppedAnswerWindsDown each failed at StoppedAnswerOtherWorkEventTests.swift:206 `otherPosts.map(\.origin) → []` against `[.mail(<other>)]`.
    - green: same filter, "Test run with 7 tests in 1 suite passed".
    - full run (one time): "Test run with 1766 tests in 214 suites passed after 8.064 seconds with 1 known issue" (the known issue is the existing withKnownIssue test of RealModelHarness), plus 26 and 19 tests of the other test targets passed. No compiler warning (only the existing "missing creator" note of the mlx bundle).
    - IntegrationTests: `swift build --build-tests --manifest-cache local` → Build complete.
    - Discovery: the sweep of `cancelAll()` journals the swept terminals with the origin of the signal, so a swept runSettled was dropped too while the stopped answer ran. The same route fixes it.
    - next: review.
  timestamp: 2026-10-16T04:45:56.946250+00:00
position_column: doing
position_ordinal: '80'
title: Live events of other work are dropped while the answer that cancelAll() stopped winds down
---
Found during ^vkkecjt. Not fixed there: that card fixed only the question posts (elicitationEnded, elicitationCompleted) with `deliverQuestionPost(_:origin:)` in Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift.

The window: `performCancelAll()` (RoutedSessionActorDrain.swift:72-81) calls `stopRunningAnswer()` first. `endRunningAnswerAtOnce()` (RoutedSessionActorDrain.swift:108-117) sends answerFailed(.cancelled), then calls `outputHub.silence(ids)` and `openAnswerMail.silence()`. The answer itself stops later. Until `runAnswerWork` ends, its `defer` does not clear `currentAnswerEventSink` (RoutedSessionActorAnswerExecution.swift:166-167). `close()` runs `performCancelAll()` too (RoutedSessionActorForking.swift:432), so it has the same window.

In that window `deliverLive(_:)` (RoutedSessionActorRunJournal.swift:229-235) gives each live event to the sink of the stopped answer. The sink (`answerEventSink()`, RoutedSessionActorAnswerExecution.swift:20-28) emits with `audience: Set(openAnswerMail.all)`. `SessionOutputHub.emit` drops each output whose audience is not disjoint with the silenced ids (SessionOutputHub.swift:409). Thus these events are dropped although their poster is not the stopped answer:

- `record(event:origin:)` (RoutedSessionActorRunJournal.swift:51-66) through `deliverLive(_:origin:)` (RoutedSessionActorRunJournal.swift:201-206): runSettled, runProgress, runMessage and elicitationRequested of another background run, whose poster is not silenced.
- `deliver(invocation:)`, `deliver(report:)` and `deliver(display:)` (RoutedSessionActorRunJournal.swift:384-406) through `deliverLive(_:)`: toolInvocation, toolCallReport and toolDisplay of another background run.

A host then misses, for example, the question of a background run that asks while the stopped answer winds down. The journal keeps each run event; only the live event is lost.

- [x] Fixed-order red test: a background run posts a live event (for example elicitationRequested, or runSettled) after cancelAll() stopped an answer that is held open, before that answer ends. Expect the event on the feed.
- [x] Fix: decide the route of a live event of other work while the open answer is silenced (for example the same rule as `deliverQuestionPost(_:origin:)`), and keep the drop of the output of the stopped answer itself.
- [x] One full run. #defect