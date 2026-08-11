---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzqa1989pb4x3k7wghfjjgs2
  text: |-
    Research, measured (not reasoned) with a throwaway scripted `LanguageModel` over a real tool-mounted `LanguageModelSession`, no GPU:

    **D2 reproduces exactly as the card says.** A scripted model that emits response text and then a tool call gives this snapshot sequence from `LanguageModelSession.streamResponse`:
    `["PRETOOL ", "PRETOOL ", "PRETOOL ", "PRETOOL ", "FINAL-ANSWER", "FINAL-ANSWER", "FINAL-ANSWER"]`
    and `respond(to:).content` on the same script is `"FINAL-ANSWER"`. So the post-tool snapshot does NOT extend the pre-tool one, `suffix(of:after:)` returns the whole snapshot, and `response += chunk` gives `"PRETOOL FINAL-ANSWER"` where the answer is `"FINAL-ANSWER"`. Confirmed.

    **D1 does NOT reproduce on this SDK.** With TWO calls in one `.toolCalls` entry the transcript is:
    - `.toolCalls` entryId=`r0`, call ids `["c0", "c1"]`
    - `.toolOutput` entryId=`c0`
    - `.toolOutput` entryId=`c1`

    `Transcript.ToolOutput.id` IS the id of the call it answers. The SDK invariant the current doc comment claims holds, so `.toolStatus(.completed, id: entry.entryId)` already carries the right id. The card's premise ("a different identifier space") is false under macOS 27 FoundationModels. The correlation is nonetheless only incidental — it depends on an undocumented SDK invariant, and if it ever broke, every call would also be reported `.failed` by the sweep. Fix is therefore to resolve the completed id inside the call-id identity space rather than trust the entry id blindly.

    Also found: `MLXLanguageModel`'s executor buffers its whole output and emits EITHER a tool call OR text, so a real tool-calling pass emits no pre-tool response text — that is why D2 is invisible on many real runs, and it is a fidelity difference the scripted suite must state.
  timestamp: 2026-08-11T02:22:13.257255+00:00
position_column: doing
position_ordinal: '8180'
title: '[Router] Streaming a tool-using turn does not work — fix D1 and D2, prove it end to end'
---
FOR THE ROUTER AGENT. **Reopened work.** `^cvtfem3` and `^vhjhaey` are both `done`, and the thing they existed to achieve does not work: FoundationModelsMultitool scores **0/4** through `RoutedSession` on both `streamEvents` and `respond(to:)`, against **1/4–3/4** through a plain `LanguageModelSession(model:tools:)` over the same MLX model, same tools, same prompts, same commit.

Those cards were closable as written because their criteria asked for a *test and a recorded outcome*, not for the defect to be gone. That was a defect in how I wrote them. This card's criteria cannot be met without it working.

Two concrete defects were appended to `^cvtfem3` **after** it closed, so they were never worked. They are restated here in full.

## D1 — `.toolStatus(.completed)` is keyed by the wrong id

`RoutedSessionActorRecording.swift:365-379`:

```swift
case .toolCalls:
    for call in entry.toolCalls ?? [] {
        onEvent(.toolCall(id: call.id, name: call.toolName, argumentsJSON: call.argumentsJSON))
        onEvent(.toolStatus(id: call.id, status: .running, summary: nil))
    }
case .toolOutput:
    onEvent(.toolStatus(id: entry.entryId, status: .completed, summary: partial.text))
```

`.toolCall` and `.running` carry `call.id`; `.completed` carries `entry.entryId` — a different identifier space. Correlating a completion to its call by id is the only thing that id is for, and it cannot be done. A client sees N calls start and N unattributable completions.

Not theoretical: a consumer built exactly that mapping (`callIndexByID` from `.toolCall`, attach `summary` on `.toolStatus`) and it silently attached nothing, leaving a diagnostic inert for five gated runs.

`dispatchedToolCallIds` and `completedToolCallIds` are already threaded through that function, so the correlation is in hand.

## D2 — the snapshot delta corrupts text across a tool boundary

`LiveModelLoader.swift:395`:

```swift
private static func suffix(of current: String, after previous: String) -> String {
    guard current.hasPrefix(previous) else { return current }
    return String(current.dropFirst(previous.count))
}
```

The doc calls the non-prefix branch "a defensive fallback for a non-monotonic snapshot, not expected in practice". With tools it is expected every turn: first pass, tool runs, generation resumes on a new answer that does not extend the old text. The guard fails, the whole snapshot is returned as a delta, and `streamGeneratingBody`'s `response += chunk` concatenates it. `previous` is never reset — `var previous = ""` for the life of one `pumpStream`.

## Why the existing tests pass anyway

`^cvtfem3`'s scripted-model test emits no pre-tool text, so snapshots stay monotonic and D2 never triggers. And `MLXFoundationModelsSessionBackend.init` takes a concrete `MLXLanguageModel`, so no scripted model reaches `pumpStream` or the live `respond` path at all — the region where both defects live has no fast coverage.

**"No test can reach it" is not available as an answer** (human-ruled): if it cannot be tested it cannot be known to work. Three tests reach it today — Router's gated suite, the consumer's gated suite (failing on it right now), and a fast scripted test once the initializer is widened to the backend protocol. Write the slow one first, then widen the seam so the fast one is possible.

## Acceptance Criteria — none of these can be satisfied by a passing test alone

- [ ] A **gated** Router test drives a real tool-using turn through `streamEvents` and asserts the final answer contains data only the tool could supply — and it passes
- [ ] The same turn through `respond(to:)` produces the same final answer, asserted by equality
- [ ] Every `.toolStatus(.completed)` id matches a previously emitted `.toolCall` id; the completed id set equals the called id set; covered with **two** calls in one turn, where mis-keying is invisible with one
- [ ] A non-monotonic snapshot sequence across a tool boundary yields accumulated text equal to the final answer — char equality, not `contains`, and no duplicated prefix
- [ ] `MLXFoundationModelsSessionBackend.init` accepts the backend protocol (or an injected snapshot source) so the two assertions above also run without a GPU
- [ ] **The consumer is re-measured and reported**: FoundationModelsMultitool, `MULTITOOL_INTEGRATION=1 swift test --filter SearchThenCallTests`, ~8–11 min. Record the per-scenario table whatever it says. This card does not close on a green Router suite alone — 0/4 there with green tests here is exactly the state that produced this card.

## Reproduction

FoundationModelsMultitool depends on Router **by local path**, so a fix is picked up with no push. Its build is currently broken by the Detach rename and will be adapted on that side; that is expected and not a Router problem.
## D4 — Router's own test suite orphans hung processes. Reproducible without any consumer.

Found by sampling the process table, not by inference.

```
PID 88350   12:43:46 elapsed   0.0% CPU   ppid=1   FoundationModelsRouterTests
PID 60459   11:37:08 elapsed   0.0% CPU   ppid=1   FoundationModelsRouterTests
PID 44786   11:47:50 elapsed   0.0% CPU   ppid=1   FoundationModelsRouterTests
PID 47523   11:45:06 elapsed   0.0% CPU   ppid=1   FoundationModelsRouterTests
```

Four `FoundationModelsRouterTests` processes, aged **11h37m to 12h44m**, every one at **0% CPU** with **ppid 1** — their `swift-test` parents exited and left them reparented to launchd. RSS ~55 MB, so they are not holding model weights: the work finished and the process could not exit.

Sampling one shows the main thread parked in `swift_task_asyncMainDrainQueue` with nothing to run, and only an idle workqueue thread besides. That is a Swift concurrency deadlock at teardown — the classic shape being an `AsyncThrowingStream` continuation that is never finished, so the main actor never drains and the process never terminates.

**This needs no consumer to reproduce.** It is Router's own suite, on this machine, four times over.

### Why this matters more than D1 and D2

An app driving Router's streaming cannot shut down. For the Agent Client Protocol use case — which is the reason the streaming surface exists — a session that will not terminate is worse than one that returns a wrong answer.

It also corrupted measurement on the consumer side, which is how it surfaced: two gated `SearchThenCallTests` runs ended in **signal 11** and one hit an **1800-second idle timeout with no result**. All three were read as "slow model" or "flaky suite". They were this.

Corroborating, from Router's own recent history: `9acf971 test(router): bound hang-prone waits in outbox and wait-gate tests` and `7534466 fix(tests): bound BoundedWait.spin by wall clock, not yield count`. Those bound the *symptom* — a test that would otherwise wait forever. The process still cannot exit, so the cause is untouched.

### Test

Run the suite and assert the process exits. Concretely: after `swift test` returns, no `swiftpm-testing-helper` for this bundle remains — a wrapper that runs the suite, waits for exit with a bounded timeout, and fails if the process is still alive. That is a test the current code fails today, and it is the definition of "streaming works" for a client that has to shut down.

Then find the unfinished continuation. Every `AsyncThrowingStream` built in `RoutedSessionActorGeneration` and `LiveModelLoader` needs an audit for a path where `continuation.finish()` is not reached — including the error path, the cancellation path, and the path where the consumer stops iterating early (`onTermination` cancels the task, but a task already parked awaiting the backend will not necessarily unwind).

### Housekeeping

Those four orphans were killed by PID after confirming `ppid == 1` and 0% CPU — orphans with nothing waiting on them. Live runs with real parents were left alone.
