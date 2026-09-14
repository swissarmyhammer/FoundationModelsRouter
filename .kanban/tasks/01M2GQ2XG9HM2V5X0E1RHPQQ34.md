---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2gr2159ehhy75jh5zhbyjf5
  text: |-
    Research done. I ran a temporary experiment test (now deleted) with a fake executor on the real macOS 27 FoundationModels runtime. Facts:

    1. `Transcript.Response` has no usage (swiftinterface: id, assetIDs, _metadata, segments only). Confirmed.
    2. `LanguageModelSession.usage` sums the usage of all generation calls. Calls with outputs 10, 20, 100 give `session.usage.output` = 130.
    3. `LanguageModelSession.Response.usage` (the value that `respond` returns) is the usage of the LAST generation call only. The same 3 calls give `Response.usage.output` = 100. A last call that sends no `.updateUsage` gives the sum of its own fragment token counts (2), not the sum of the attempt.
    4. `ResponseStream.Snapshot.usage` is also the usage of the call that made the snapshot. The final snapshot of a call carries the value of its `.updateUsage`.
    5. The stream yields NO snapshot for a final call that sends no text (for example, only metadata or only usage). The last snapshot is then from an earlier tool-call round, and its `transcriptEntries` end at that `.toolCalls` entry. Thus the last snapshot usage is correct only when the last entry of the snapshot is the last entry of the session transcript.
    6. Inside a tool call, `session.usage` already holds the usage of the round that asked for the tool.
    7. With tools mounted, the MLX executor runs the allowed tool path on every round. That path sends the answer text and then `.updateUsage` on the response entry id, with no `incompleteOutput` when the budget ends in the answer text.

    Plan: no upstream change is necessary. The backend keeps the output token count of the last generation call (from `Response.usage` on the respond path, from the last snapshot on the stream path), with the id of the last transcript entry of that call. The backend clears the value when a generating call starts, and gives it only while the transcript still ends at that entry. `FinishReason` uses this count for an attempt that called a tool.
  timestamp: 2026-09-14T19:59:42.249862+00:00
- actor: claude-code
  id: 01m2grkc5r04g8yjjnq5m0trta
  text: |-
    Implementation landed. No upstream change was necessary, and Libraries/MLXFoundationModels is not changed.

    What changed:
    - `LanguageModelSessionBackend` has a new requirement `lastGenerationCallOutputTokenCount() -> Int?`, with a public default that gives `nil`.
    - `MLXFoundationModelsSessionBackend` records the output count of the last generation call: from `LanguageModelSession.Response.usage` on the respond path, and from the usage of each `ResponseStream` snapshot on the stream path. It records the id of the last transcript entry of that call too. Each generating method clears the value when it starts. The accessor gives the count only while `liveSession.transcript.last?.id` is still that id.
    - `FinishReason.init` has the new parameter `lastCallOutputTokens`. The count of the last call decides for every attempt. A reported count above the output count of the attempt is not a count of this attempt and does not decide (the case of an attempt that failed before it reached the backend). When no count is reported, a one-call attempt uses its own count as before, and a tool-calling attempt uses the metadata only.
    - `finishTurn` passes `backend.lastGenerationCallOutputTokenCount()`. The doc of `TokenUsage.finishReason` states the new rule.

    What did not work, and why the guards exist:
    - A final call that sends only reasoning, with no response entry, makes the SDK throw "Session ended without producing a response". The probe ending `endsWithoutText` thus sends the model id metadata that the MLX executor sends at the start of each call.
    - Without the transcript-end id check, the streamed test `streamedToolLoopWithSilentLastCallReportsCompleted` failed: the last snapshot was of the tool-call round (count equal to the ceiling), and the turn reported `.maxTokens`. I watched that failure, then added the check.

    Tests (TurnFinishReasonTests, 23 tests): 3 new unit tests on `FinishReason`, and 4 new live tests over a tool loop (respond with nil and 256 ceilings, respond where only the tool round spends the ceiling, stream with a truncated last call, stream with a silent last call). `CeilingProbeLanguageModel` got the endings `callsTool` and `endsWithoutText`, and its container now mounts tools.
  timestamp: 2026-09-14T20:09:10.584307+00:00
- actor: claude-code
  id: 01m2grkk0nbpnzb21zwqy2rqw9
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/Session/FinishReason.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift, Sources/FoundationModelsRouter/Session/SessionEvent.swift, Tests/FoundationModelsRouterTests/Helpers/CeilingProbeLanguageModel.swift, Tests/FoundationModelsRouterTests/TurnFinishReasonTests.swift. `swift test`: 1323 tests in 141 suites passed (2 known issues that already existed), plus 1 and 83 tests in the other runs. `swift test --filter TurnFinishReasonTests`: 23 passed. `swift build --package-path IntegrationTests --build-tests`: build complete.
    - next: /review
  timestamp: 2026-09-14T20:09:17.589676+00:00
- actor: claude-code
  id: 01m2gssds64jp0x4bahp0qw4vy
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 0 confirmed, 1 refuted, 7 files reviewed, 0 failed. The 4 .kanban/ files are excluded by .reviewignore.
    - next: The task is in done.
  timestamp: 2026-09-14T20:29:57.414315+00:00
- actor: claude-code
  id: 01m2gssz4tjj49s13e79fhz5xv
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files
    - test: green — swift test, 1323+1+83 passed, 0 failed, 0 skipped
    - commit: e3c07ec
    - review: clean — 0 findings; task in done
  timestamp: 2026-09-14T20:30:15.194650+00:00
position_column: done
position_ordinal: ffffd680
title: A tool-calling turn that reaches the ceiling in its answer text reports completed
---
## The problem

Card ^52rb0ef added a count rule to `FinishReason`: an attempt with one generation call ends at `.maxTokens` when its output token count is equal to or more than the ceiling it gave the backend.

An attempt that called a tool makes more than one executor call inside one `LanguageModelSession.respond`. `liveSession.usage` gives only the sum of all calls. The sum does not tell which call stopped. Thus the count rule does not apply to such an attempt (see `FinishReason.generationCalledTool`), and a tool turn that runs out of tokens in its final answer text still reports `.completed`.

## Facts to check

- `Transcript.Response` has no usage of its own in the SDK swiftinterface.
- `LanguageModelSession.ResponseStream.Snapshot` has `usage` and `transcriptEntries`. The stream path can maybe see the usage when each `.toolCalls` entry appears.
- The unconstrained MLX path (`MLXLanguageModel.swift`) sends `.updateUsage` on the response entry id of each call.

## The work

1. Find a way to know the output token count of the last generation call of an attempt, or ask upstream to mark a stop at the ceiling in the answer text with `incompleteOutput`.
2. Do NOT change `Libraries/MLXFoundationModels` (upstream code) from this repository.
3. Add a test with a tool loop whose last call stops at the ceiling in the answer text.