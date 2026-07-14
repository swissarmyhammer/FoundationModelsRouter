---
comments:
- actor: claude-code
  id: 01kxgz42and29m12bdz0hk5xmc
  text: |-
    Implemented and green.

    Key design decision beyond the task's literal pseudocode: `Wrapped.Executor(configuration: wrapped.executorConfiguration)` needs a concrete `Wrapped: LanguageModel` type at the call site, but `RoutedLLM = RoutedModel<any LoadedLLMContainer>` only ever holds the container as an existential. Empirically verified (via scratch swiftc compiles against the real macOS 27 FoundationModels SDK) that:
    - `any LanguageModel` IS constructible as an existential type, despite `LanguageModel`'s `associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model` constraint.
    - Swift's implicit existential-opening (SE-0352) lets a generic function be called directly with an `any LanguageModel` value, recovering the concrete type inside the generic body.

    So the mechanism is: `LoadedLLMContainer` gains a new member `var languageModel: any FoundationModels.LanguageModel { get }` (defaulted via extension to a `preconditionFailure`, mirroring the existing `ModelLoader.evict(container:)` "optional protocol member" idiom — so none of the ~20 existing stub `LoadedLLMContainer` conformers in the test suite need any changes). `MLXFoundationModelsContainer` overrides it to return `model` (its `MLXLanguageModel`). `RoutedLLM.makeLanguageModel()` reads `container.languageModel` and hands it to `RecordingLanguageModelState.makePassthrough(wrapped:)`, a static func that opens the existential once (inside a private generic helper) and builds `Wrapped.Executor(configuration:)` exactly once, closing over the concretely-typed executor+model in a `@Sendable` closure. `RecordingLanguageModel.Executor.init(configuration:)` calls this once per handle; the SDK's own executor cache (keyed by our `Configuration`'s identity-based equality on the backing `RecordingLanguageModelState` actor) ensures it's never rebuilt per call.

    `RecordingLanguageModelState` is an actor (not a lock-guarded class) holding: routerId/sessionId/recordingDirectory/slot/model/recorder/serialGate/sessionIndexWriter/indexPath/wrapped/profile (all `nonisolated let`, since `capabilities`/`executorConfiguration` and `Executor.init` are non-async and need synchronous access), plus mutable `lastSeen`/`didRecordSessionMeta`/`didRegisterSessionIndex`. Both `generate(request:channel:innerRespond:)` (called from the executor's `respond`) and `sync(_:)` acquire the SAME shared `RoutedModel.serialGate` around their diff-and-record work, so they can never interleave on `lastSeen`, and generation on a handle fully serializes with `RoutedSession` generation on the same model. `SessionIndexRecord` registration is lazy (on first `generate`/`sync`, not at `makeLanguageModel()` mint time), matching "no I/O until actually driven."

    Extracted `TranscriptDiffer.leadingInstructionsText(of:)` out of `MLXFoundationModelsContainer`'s private duplicate (now calls the shared one) since both it and the new session-index registration need the same "derive instructions from a transcript's leading `.instructions` entry" logic. Also factored `RoutedModel.recordingDirectory(forSessionId:)` out of `makeSession`'s inline computation, shared with `makeLanguageModel()`.

    Adversarial double-check (via the `double-check` agent) caught one real gap: the shrink-defense in `diffAndRecord` claimed doc-comment parity with `RoutedSessionActor.recordTranscriptDelta`'s shrink guard but didn't actually log a warning the way that sibling does. Fixed by adding a matching `recordingLanguageModelLogger.warning(...)` call; re-checked and passed.

    Verification: `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 323 unit tests pass (315 pre-existing + 8 new in RecordingLanguageModelTests.swift), 14 gated integration tests correctly skipped (no GPU/network in this sandbox), zero warnings on a clean rebuild.

    Files touched: Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift (new), Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift, Sources/FoundationModelsRouter/Resolution/ModelLoader.swift, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift (new).

    Leaving in doing per /implement workflow for /review to pick up.
  timestamp: 2026-07-14T18:44:39.893413+00:00
depends_on:
- 01KXGGX3TTZ318CPMMY9F3EV1K
- 01KXGGXJDEWZ9N64M9FW3DS21J
position_column: doing
position_ordinal: '80'
title: 'RecordingLanguageModel: per-session recording LanguageModel handle vended by RoutedLLM'
---
## What
Add a factory on RoutedLLM — makeLanguageModel() returning a LanguageModel conformer (working name RecordingLanguageModel, in Recording/ or Session/). A FACTORY, not a property: each call mints a fresh handle carrying per-session state — its own session ULID, recording directory under the recordings root, lazily opened recorder sink, and last-seen Transcript. Behavior (mechanisms confirmed by spike 9f3ev1k + its review addendum):

- wraps the loaded container model (LoadedLLMContainer) and forwards generation by constructing the wrapped model's own executor (`LanguageModelExecutor.init(configuration:)` is a public protocol requirement) and passing the OUTER channel straight through: `try Wrapped.Executor(configuration: wrapped.executorConfiguration).respond(to: request, model: wrapped, streamingInto: channel)`. Streaming, reasoning, and toolCalls events flow untouched. Cache the inner executor on the handle — the SDK caches executors keyed by Configuration equality; do not defeat that by re-creating per call.
- Do NOT delegate through a nested LanguageModelSession (the spike probe's mechanism — it would execute tool calls itself and break tool-using turns), and do NOT attempt to read relayed channel events (`Event` is write-only: static constructors only, zero public accessors).
- acquires the RoutedModel shared serialGate around generate, so GPU serialization spans handle sessions and RoutedSessions alike
- on every generate call, diffs `request.transcript` against last-seen via the extracted TranscriptDiffer and appends the resulting TranscriptEvent partials; updates last-seen. This captures instructions, prompts, toolCalls, toolOutput, and all PRIOR responses (every call carries the full transcript). Tool definitions are also on `request.enabledToolDefinitions` directly.
- the TURN-FINAL response is not observable at the executor boundary. Close the gap with an explicit, idempotent `sync(_ transcript: Transcript)` on the handle: diff-and-record against last-seen; cheap no-op when nothing is new. Turn owners call it at turn end with `session.transcript` (public getter). Any later generate call in the same session back-fills automatically via the diff, so mid-turn records are complete even without sync; sync matters for the last turn before idle/exit.
- honors RecordingLevel (off / metadataOnly / full) and the redact hook via the existing GatingRecorder
- registers a SessionIndexRecord in sessions.jsonl on first use, same fields as RoutedSession sessions

Net effect (the whole point): any LanguageModelSession(model: handle, tools: myTools, instructions: text) — constructed by ANY caller — is recorded, serial-gated, and tool-capable with zero session plumbing, plus one optional `sync(session.transcript)` at turn end for the final response. RoutedSession remains unchanged for existing callers.

Testability: `LanguageModelExecutorGenerationRequest` has a public memberwise init and `LanguageModelExecutorGenerationChannel` has `public init()` — the handle's executor is exercisable in unit tests without any session.

## Acceptance Criteria
- [x] makeLanguageModel() returns a distinct identity per call; two live handles never interleave events or share a directory
- [x] A LanguageModelSession over a handle with a test tool produces instructions/prompt/toolCalls/toolOutput events equivalent to what the RoutedSession chokepoint would record for the same conversation; after `sync(session.transcript)` at turn end the final response event is present too
- [x] Tool-using turns work end-to-end over the handle (toolCalls events pass through the shared channel unmodified)
- [x] `sync` is idempotent: calling it twice, or after the diff already caught up, appends nothing
- [x] RecordingLevel.off and .metadataOnly and redact behave exactly as they do for RoutedSession
- [x] Existing RoutedSession tests pass unchanged

## Tests
- [x] Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift over a stub container + InMemoryRecorder: per-handle identity, diff-on-generate correctness, passthrough fidelity (including a toolCalls-emitting stub executor), sync-at-turn-end recording the final response, sync idempotence, serial gate acquisition, level gating, redaction
- [x] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness