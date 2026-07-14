---
depends_on:
- 01KXGGX3TTZ318CPMMY9F3EV1K
- 01KXGGXJDEWZ9N64M9FW3DS21J
position_column: todo
position_ordinal: '8280'
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
- [ ] makeLanguageModel() returns a distinct identity per call; two live handles never interleave events or share a directory
- [ ] A LanguageModelSession over a handle with a test tool produces instructions/prompt/toolCalls/toolOutput events equivalent to what the RoutedSession chokepoint would record for the same conversation; after `sync(session.transcript)` at turn end the final response event is present too
- [ ] Tool-using turns work end-to-end over the handle (toolCalls events pass through the shared channel unmodified)
- [ ] `sync` is idempotent: calling it twice, or after the diff already caught up, appends nothing
- [ ] RecordingLevel.off and .metadataOnly and redact behave exactly as they do for RoutedSession
- [ ] Existing RoutedSession tests pass unchanged

## Tests
- [ ] Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift over a stub container + InMemoryRecorder: per-handle identity, diff-on-generate correctness, passthrough fidelity (including a toolCalls-emitting stub executor), sync-at-turn-end recording the final response, sync idempotence, serial gate acquisition, level gating, redaction
- [ ] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness