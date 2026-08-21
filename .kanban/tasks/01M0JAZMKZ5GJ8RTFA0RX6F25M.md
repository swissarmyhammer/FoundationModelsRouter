---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0jd4te71bzcv02d9y5jm39h
  text: |-
    ### implement — research

    - Router has no model-visible `wait` tool. `ToolContext.wait(completionToken:seconds:)` (Sources/FoundationModelsRouter/Hosting/ToolContext.swift) is a Swift capability a host tool calls. `WaitOutcome` (Hosting/RunPlane.swift) is a Swift enum: `settled(OperationEvent)`, `deadlineElapsed`, `unknownToken`. It has no wire spelling. The strings `"settled"` and `"deadline_elapsed"` exist only in `PendingRunEnvelope.renderedSuffix` and in one test. So the default sentence must not name states.
    - `PendingRunEnvelope` (Hosting/DetachingTool.swift) renders `prefix + token + midfix + token + suffix`. `isRendered(text:)` checks the exact length, reads the first token slot, and re-renders. `TokenCappingTool.call` (Session/ToolOutputCapping.swift) is the one caller.
    - `DetachmentParameterProviding` has two members with defaults: `detachmentMount` and `detachmentClocks(from:)`. `DetachingTool` reads it in `init` (mount) and in `perCallClocks(from:)`. The new member follows the `detachment` prefix: `detachmentCollectInstruction(forCompletionToken:)`.
    - Test conformers of the protocol: DetachingToolTests (5), NestedGenerationReentryTests (3), SessionOutboxToolWiringTests (1), RespondRunPlaneDrainTests (1). None overrides the new member, so the default covers them. IntegrationTests does not name `PendingRunEnvelope`, `isRendered`, or the protocol.
    - Tests that the change must move: `renderedEnvelopeTeachesTheCollectStep` (asserts the old snippet), `mismatchedTwinTokensAreRejected` and `editedProseIsRejected` (both assume one fixed suffix, which design B removes). `alteredLengthIsRejected`, `nonULIDTokenSlotsAreRejected`, `nonEnvelopeOutputIsRejected`, and `pendingEnvelopeSurvivesCappingLayer` stay true.
    - Design: `PendingRunEnvelope` gets a stored `next`, `init(completionToken:next:)`, `init(completionToken:)` keeps the default sentence, and `defaultCollectInstruction(forCompletionToken:)` is the one definition the protocol default and the envelope share. `isRendered` checks prefix, a valid ULID token, the `","next":"` midfix, and the `"}` suffix, then decodes and re-renders, so recognition is still re-rendering and ordinary output is never JSON-parsed.
    - No `.periphery.yml` in the repo; the review engine runs periphery itself.
  timestamp: 2026-08-21T14:56:04.551664+00:00
- actor: claude-code
  id: 01m0jdgz74gc8m5mg8fb6czywm
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Hosting/DetachingTool.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift (doc comment only), Tests/FoundationModelsRouterTests/DetachingToolTests.swift. Design B. `DetachmentParameterProviding` gets `detachmentCollectInstruction(forCompletionToken:)` with a default. `PendingRunEnvelope` gets a stored `next`, `init(completionToken:next:)`, and `defaultCollectInstruction(forCompletionToken:)`. `isRendered(text:)` checks the prefix, a valid ULID token, the `","next":"` midfix and the `"}` suffix, then decodes and re-renders. `DetachingTool.detach` renders the wrapped tool's sentence. The default sentence, verbatim: `This run is still going. Do not answer yet, and never invent or guess its result. Call the wait tool with completionToken "<T>" to collect the result. If the run is not finished yet, call wait again with the same completionToken.` It names no state, because Router's `WaitOutcome` has no wire spelling; the doc comment records this.
    - tests: RED first (`swift build --build-tests`: 5 errors, `defaultCollectInstruction` and `next:` missing). Then `swift test --filter "DetachingToolTests|ToolOutputCappingTests"`: 62 tests in 2 suites passed. Root `swift test`: 1032 tests in 98 suites passed with 2 known issues (both pre-existing `withKnownIssue` sites), plus 77 XCTest tests in 9 suites passed. `swift build --build-tests --package-path IntegrationTests`: Build complete. `periphery scan --skip-build --index-store-path .build/out --retain-public ...`: no finding in the changed files (only pre-existing unused-parameter rows in Resolution/*). No `swift format` run.
    - removed tests: `mismatchedTwinTokensAreRejected` and `editedProseIsRejected` assumed one fixed suffix; design B makes an edited sentence a valid envelope. `renderedEnvelopeTeachesTheCollectStep` became `defaultCollectInstructionTeachesTheCollectStep`. Added: `toolSuppliedCollectInstructionIsRendered`, `renderedEnvelopeIsRecognizedWithAnyCollectInstruction`, `tokenCappingPassesRenderedEnvelopesThrough`, and two malformed-`next` rows in `nonEnvelopeOutputIsRejected`.
    - next: /review. Box 4 (tell Multitool on `^4qcf1v9`) stays open for the orchestrator.
  timestamp: 2026-08-21T15:02:42.660550+00:00
position_column: doing
position_ordinal: '8180'
title: The pending envelope's `next` text prescribes a `runCode` snippet that cannot collect the run
---
Filed from FoundationModelsMultitool card `^4qcf1v9`. This card is native to Router: the text lives in Router, and only Router can change it.

## What happens

`PendingRunEnvelope.renderedMidfix` and `renderedSuffix` in `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift` render this `next` text on every park:

> Call this tool again with a snippet that does: return await wait("<completionToken>", 60). When the returned state is "settled", the result is in its detail field. When it is "deadline_elapsed", the run is still going: call wait again with the same completionToken.

For Multitool's `runCode`, this instruction cannot collect the run:

1. `runCode` always backgrounds. `MultiTool.detachmentClocks(from:)` (Multitool, `Sources/FoundationModelsMultitool/MultiTool+Detachment.swift`) answers a zero wait clock (Multitool task `^cv98vff`). Each `runCode` call returns a fresh pending envelope before its snippet runs.
2. So the prescribed snippet `return await wait("T0", 60)` returns a new envelope for a new token T1. It does not return the result of T0. The `next` text of T1 prescribes the same snippet for T1. The model obeys it. Each round costs one model generation.
3. Measured with no model (Multitool mounted under `.nativeSessionMount`, one scripted background run): on a settled T0 the call returned a fresh envelope in 42 µs; on a running T0 in 112 µs; the second hop minted a third token. Measured with a model (Multitool CI run `32392350928`): 21 rounds and 1777 s for an 8-second fixture. The model escaped only when it called the `wait` tool with the original token.
4. The state names in the text ("settled", "deadline_elapsed") are Router's `WaitOutcome` names. Multitool's sandbox `wait()` and its `wait` tool report `state: complete | error` and `result: timeout | unknown`. The text names values the model does not see.
5. Multitool's `runCode` description already says "do not wait()". The in-band `next` text wins over the tool description. The transcript shows this.

The collect step for a Router-mounted Multitool session is the `wait` **tool** (`Sources/FoundationModelsMultitool/WaitTool.swift`, mounted by `MultiTool.Registry.makeSessionTools`), called with the same completionToken. Multitool tasks `^2w9vbkm` and `^h773bed` record why: a snippet-level wait asks the model for a duration it cannot know. Router card `01M03NR0CQ8MX1SV2NQ466D38P` already recorded that this instruction is Router behaviour on every host.

## What Multitool needs

The `next` text of a pending envelope must lead the model to a collect step that works:

- The text must not prescribe a `runCode` snippet. For a detaching tool other than `runCode`, "call this tool again with a snippet" is also wrong: a shell tool has no snippets.
- The text must name the same completionToken, and a collect step that returns the result in band: the `wait` tool with that completionToken.
- The state names in the text must match what the collect step reports, or the text must not name states.

Two designs. The choice is Router's:

- A. Change the fixed text. Example: "Call the wait tool with completionToken "<T>". When its state is "complete", answer from its detail. When its result is "timeout", call wait again with the same completionToken." Keep `isRendered(text:)` exact.
- B. Let the wrapped tool supply the collect sentence through `DetachmentParameterProviding` (an optional requirement with a default). The tool that owns the collect verb then owns the sentence. `PendingRunEnvelope.isRendered(text:)` then recognizes the prefix, the token, and a `next` field, not one fixed suffix. `TokenCappingTool` is the one `isRendered` caller.

Call sites: `DetachingTool.detach(...)` builds the envelope. `Tests/FoundationModelsRouterTests/DetachingToolTests.swift` asserts the current snippet text `return await wait("<token>", 60)` near its line 460. `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift` uses `isRendered`.

Multitool has touched nothing in the Router tree.

## Acceptance Criteria

- [x] The `next` text does not prescribe a `runCode` snippet, and names the same completionToken for a collect step that returns in band.
- [x] `isRendered(text:)` recognizes every rendered envelope, and `TokenCappingTool` passes it through.
- [x] Router tests green.
- [ ] Multitool is told on its card `^4qcf1v9`, so it can bump its Router pin and re-measure the elevation scenario.