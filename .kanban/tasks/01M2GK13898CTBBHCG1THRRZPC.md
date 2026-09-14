---
comments:
- actor: claude-code
  id: 01m2gkvekb5bw70kk5yx2f5z3x
  text: |-
    Research done. Discoveries:

    1. The MLX executor sends `["incompleteOutput": true]` as `.response(entryID:, action: .updateMetadata(...))`. FoundationModels puts this value in `Transcript.Response.metadata` (macOS 27). So the signal is readable from the transcript entries of the backend. No MLX change is necessary.
    2. The unconstrained MLX path sends `incompleteOutput` ONLY when generation ends inside a reasoning block. A turn that runs out of tokens in the answer text (after `</think>`) gets no metadata. This is upstream behaviour. The measured SWE-bench cases are the reasoning case, so this card covers them.
    3. `ModelLoader.loadLLM(context:)` is advisory. The doc says: "one container serves every working context". Thus the container must not keep a ceiling from the load context. The resolved context lives on the session (`RoutedSessionActor.contextTokens`, from `SlotResolution.contextTokens`). Decision: the session gives `maxTokens ?? contextTokens` to the backend. The live backend keeps a named floor constant for a caller that gives no ceiling.
    4. `ProfileDefinition.defaultContext` is also 8192. A profile that does not set `context` resolves to 8192, so the ceiling stays 8192 for such a host profile. A host that wants a longer turn must set `context` (or `nil` to derive the native context).
    5. `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift` shows how to drive the real `MLXFoundationModelsSessionBackend` over a scripted `LanguageModel`. A test can send the same metadata action as MLX, with no GPU.
  timestamp: 2026-09-14T18:46:12.331040+00:00
- actor: claude-code
  id: 01m2gmng0xz7rfca9tdpy1mqk7
  text: |-
    Implementation landed. What changed:

    1. Ceiling. `RoutedSessionActor.responseTokenCeiling(requested:contextTokens:)` (RoutedSessionActorTurnExecution.swift) gives the backend `maxTokens ?? contextTokens`. A context of 0 gives `nil`. `respondBody` and `streamGeneratingBody` use it, so respond, stream, events, guided and dispatch turns all get the ceiling. In LiveModelLoader.swift the private `defaultMaxTokens` is now `MLXFoundationModelsSessionBackend.responseTokenFloor` (8192), with a comment that it is a floor and not a policy.
    2. Signal. New `Session/FinishReason.swift`: public `FinishReason { completed, maxTokens }`, and `init(turnEntries:)` that reads `incompleteOutput` from the metadata of the LAST `.response` entry of the attempt.
    3. Carry. `TokenUsage.finishReason` (default `.completed`, so old call sites compile). `finishTurn` in RoutedSessionActorRecording.swift reads the entries that `persistedBaseline` does not hold, before the diff moves the baseline.

    DECISION (review this): the derivation is in the session, not in LiveModelLoader. Reason: `ModelLoader.loadLLM(context:)` is advisory and one pooled container serves every working context, so the container cannot know the context of a session. This changed the contract of 3 old tests. They expected `nil` at the backend ("the default lives in LiveModelLoader only"). They now expect the resolved context: `SessionChokepointTests.respondThreadsMaxTokensOverride`, `SessionChokepointTests.streamResponseThreadsMaxTokensOverride` (explicit value changed 8192 -> 2048, so it differs from the default context), `GuidedGenerationTests.respondFollowingForwardsMaxTokensOverride`. I asked the user; the question UI cut the text and the user could not read it, so no answer. Alternative if review rejects this: add `contextTokens:` to the `LoadedLLMContainer.makeSession(...samplingMode:)` family and derive inside the live backend.

    What did not work:
    - The probe executor first used one fixed response entry id for all calls. A second call that sent only metadata on the reused id made FoundationModels throw "Session ended without producing a response." Each call now uses its own entry id, as MLX does.
    - Counting `.prompt` entries in `request.transcript` to find the first turn gave the wrong turn. The probe now counts calls in its log.

    Verified on the real FoundationModels runtime (no GPU): `.response(entryID:, action: .updateMetadata(["incompleteOutput": true]))` lands in `Transcript.Response.metadata`, and a response entry exists even with no text.

    Follow-up card ^52rb0ef: a turn that reaches the ceiling after `</think>` gets no metadata from MLX, so it still reports `.completed`.
  timestamp: 2026-09-14T19:00:25.757799+00:00
- actor: claude-code
  id: 01m2gmnmx904c179fph1rjtzb2
  text: |-
    ### implement — changed
    - evidence: `swift test` -> 1309 tests in 141 suites passed (2 known issues, not new), 1 test passed, 83 tests in 10 suites passed; `swift build --package-path IntegrationTests --build-tests` builds with no error. New: Sources/FoundationModelsRouter/Session/FinishReason.swift, Tests/FoundationModelsRouterTests/TurnFinishReasonTests.swift (8 tests), Tests/FoundationModelsRouterTests/TurnTokenCeilingTests.swift (5 tests), Tests/FoundationModelsRouterTests/Helpers/CeilingProbeLanguageModel.swift. Changed: Resolution/LiveModelLoader.swift, Session/SessionEvent.swift, Session/RoutedSessionActorRecording.swift, Session/RoutedSessionActorTurnExecution.swift, Session/RoutedSessionActorGeneration.swift, Session/RoutedSession.swift, Session/TurnOutcome.swift, Tests SessionChokepointTests.swift, GuidedGenerationTests.swift.
    - next: /review. Check the DECISION in the comment above (ceiling derived in the session, 3 old tests changed).
  timestamp: 2026-09-14T19:00:30.761466+00:00
- actor: claude-code
  id: 01m2gmzqhrasza7nc20negz5xd
  text: |-
    ### test — green
    - evidence: `swift test` (root package) — 1309 + 1 + 83 = 1393 tests passed, 0 failed, 0 skipped, 2 pre-existing known issues (legitimate `withKnownIssue` checks in `BoundedWaitTests.swift` and `RealModelHarnessTests.swift`, not part of this task's diff).
    - evidence: `swift build` (root package) clean. No compiler warning in our code. Only one benign SwiftPM build-planner message unrelated to our source: `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)` — this is from the external `mlx-swift` dependency's bundle target, not from `FoundationModelsRouter` or `Libraries/MLXFoundationModels` source.
    - evidence: `swift build --package-path IntegrationTests` and `swift build --build-tests --package-path IntegrationTests` both complete clean, same benign external message only.
    - The two new test suites for this task — "Turn finish reason: a truncated turn is distinguishable from a finished turn" and "Turn token ceiling: derived from the resolved context" — both ran and passed.
    - No skipped or disabled tests found anywhere in the run.
    - next: hand off to review.
  timestamp: 2026-09-14T19:06:01.144514+00:00
position_column: doing
position_ordinal: '80'
title: The token ceiling is a constant, and a truncated turn is silent
---
## The problem

A turn that runs out of output tokens looks exactly like a turn that
finished. The backend knows the difference. Router throws that knowledge
away, so the host cannot report it.

Measured in the SWE-bench run of 2026-09-14. Three instances gave no patch
and reported the ordinary `end_turn`:

| instance | tokensOut | model ms | tool calls |
|---|---|---|---|
| django__django-13925 | 8192 | 230869 | 0 |
| django__django-13964 | 8192 | 228298 | 0 |
| django__django-14016 | 8192 | 227886 | 0 |

`tokensOut` is 8192 in each one, and not near 8192. It is the ceiling
exactly. Each transcript holds ONE reasoning block that stops in the middle
of a sentence, and no tool call at all. The agent spent 228 seconds and
changed nothing, and the record of the run says the turn completed.

## Two faults, and they are separate

### 1. The ceiling is a constant, and it is not the ceiling of the model

`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:38`

```swift
/// The token ceiling for a generation call that gives no `maxTokens`.
private let defaultMaxTokens = 8192
```

It is applied at `LiveModelLoader.swift:198` and `:236`:

```swift
GenerationOptions(samplingMode: samplingMode,
                  maximumResponseTokens: maxTokens ?? defaultMaxTokens)
```

The host gives no `maxTokens`, so this fallback decides every turn. 8192
tokens is 228 seconds at the 36 tokens each second of
`mlx-community/Qwen3.8-27B-mxfp4` on that machine.

The number has no relation to the context of the resolved model. It also
makes the bounds that were DESIGNED to govern a long turn unreachable: the
stall bound of the host is 1800 seconds, and the watchdog of the bench is
3000 seconds. A fallback constant decides the length of a turn, and the two
bounds above it never get a turn to govern.

Derive the ceiling from the context of the resolved model. Keep a constant
for a model that reports none.

### 2. The truncation signal exists, and nothing reads it

The MLX layer already tells you. When the thought does not close before the
budget ends, it emits metadata:

```swift
await Self.emitMetadata(["incompleteOutput": true], entryID: entryID, into: channel)
```

That is upstream code of ml-explore, and it is correct. **`incompleteOutput`
has no consumer in this package, and none in the host.** Only the tests of
the vendored MLX read it.

Router then cannot carry the fact, because no type holds it:

- `Session/LanguageModelSessionBackend.swift:10` — `ResponseFragment` holds
  `text` and `restartsResponse`, and nothing more.
- `Session/SessionEvent.swift:161` — `TokenUsage` holds `tokensIn`,
  `tokensOut` and `contextFill`, and nothing more.

So the stream of fragments simply ends. The host sees a turn that stopped
giving text, which is what a finished turn also looks like.

## The work

1. `LiveModelLoader.swift:38,198,236` — derive `maximumResponseTokens` from
   the context of the resolved model. Keep a named constant for the model
   that reports no context, and say in the comment that it is a floor and
   not a policy.
2. Consume the `incompleteOutput` metadata of the backend.
3. Carry the fact. Add a finish reason to `TokenUsage`, or to the event that
   closes a turn. The host must be able to ask "did this turn end because it
   ran out of tokens?" and get a true answer.

Do NOT change MLX. `Libraries/MLXFoundationModels` is upstream ml-explore
code, current upstream main holds the same shape, and a change there is a
fork of a file of Apple that this organization then carries for ever. The
signal this card needs is on the wire already.

## When it is complete

- The ceiling of a turn comes from the model, and not from a constant.
- A turn that ends at the ceiling is distinguishable from a turn that ends
  because the model finished.
- A test proves both, with a backend that reports `incompleteOutput`.

The host card is [[a-truncated-turn-reports-end-turn]] in
`FoundationModelsACPAgent`. It maps this fact to an honest stop reason. This
card must land first, because that card has nothing to map until it does.