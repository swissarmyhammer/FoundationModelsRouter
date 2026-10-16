---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Live events of other work are dropped while the answer that cancelAll() stopped winds down
---
Found during ^vkkecjt. Not fixed there: that card fixed only the question posts (elicitationEnded, elicitationCompleted) with `deliverQuestionPost(_:origin:)` in Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift.

The window: `performCancelAll()` (RoutedSessionActorDrain.swift:72-81) calls `stopRunningAnswer()` first. `endRunningAnswerAtOnce()` (RoutedSessionActorDrain.swift:108-117) sends answerFailed(.cancelled), then calls `outputHub.silence(ids)` and `openAnswerMail.silence()`. The answer itself stops later. Until `runAnswerWork` ends, its `defer` does not clear `currentAnswerEventSink` (RoutedSessionActorAnswerExecution.swift:166-167). `close()` runs `performCancelAll()` too (RoutedSessionActorForking.swift:432), so it has the same window.

In that window `deliverLive(_:)` (RoutedSessionActorRunJournal.swift:229-235) gives each live event to the sink of the stopped answer. The sink (`answerEventSink()`, RoutedSessionActorAnswerExecution.swift:20-28) emits with `audience: Set(openAnswerMail.all)`. `SessionOutputHub.emit` drops each output whose audience is not disjoint with the silenced ids (SessionOutputHub.swift:409). Thus these events are dropped although their poster is not the stopped answer:

- `record(event:origin:)` (RoutedSessionActorRunJournal.swift:51-66) through `deliverLive(_:origin:)` (RoutedSessionActorRunJournal.swift:201-206): runSettled, runProgress, runMessage and elicitationRequested of another background run, whose poster is not silenced.
- `deliver(invocation:)`, `deliver(report:)` and `deliver(display:)` (RoutedSessionActorRunJournal.swift:384-406) through `deliverLive(_:)`: toolInvocation, toolCallReport and toolDisplay of another background run.

A host then misses, for example, the question of a background run that asks while the stopped answer winds down. The journal keeps each run event; only the live event is lost.

- [ ] Fixed-order red test: a background run posts a live event (for example elicitationRequested, or runSettled) after cancelAll() stopped an answer that is held open, before that answer ends. Expect the event on the feed.
- [ ] Fix: decide the route of a live event of other work while the open answer is silenced (for example the same rule as `deliverQuestionPost(_:origin:)`), and keep the drop of the output of the stopped answer itself.
- [ ] One full run. #defect