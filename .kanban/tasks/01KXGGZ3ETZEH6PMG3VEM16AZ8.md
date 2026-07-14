---
depends_on:
- 01KXGGX3TTZ318CPMMY9F3EV1K
- 01KXGGXJDEWZ9N64M9FW3DS21J
position_column: todo
position_ordinal: '8280'
title: 'RecordingLanguageModel: per-session recording LanguageModel handle vended by RoutedLLM'
---
## What
Add a factory on RoutedLLM — makeLanguageModel() returning a LanguageModel conformer (working name RecordingLanguageModel, in Recording/ or Session/). A FACTORY, not a property: each call mints a fresh handle carrying per-session state — its own session ULID, recording directory under the recordings root, lazily opened recorder sink, and last-seen Transcript. Behavior:

- wraps the loaded container model (LoadedLLMContainer) and forwards generation
- acquires the RoutedModel shared serialGate around generate, so GPU serialization spans handle sessions and RoutedSessions alike
- on every generate call, diffs the incoming transcript against last-seen via the extracted TranscriptDiffer and appends the resulting TranscriptEvent partials; records the emitted response at turn end; updates last-seen
- honors RecordingLevel (off / metadataOnly / full) and the redact hook via the existing GatingRecorder
- registers a SessionIndexRecord in sessions.jsonl on first use, same fields as RoutedSession sessions

Net effect (the whole point): any LanguageModelSession(model: handle, tools: myTools, instructions: text) — constructed by ANY caller — is recorded, serial-gated, and tool-capable with zero session plumbing. RoutedSession remains unchanged for existing callers.

## Acceptance Criteria
- [ ] makeLanguageModel() returns a distinct identity per call; two live handles never interleave events or share a directory
- [ ] A LanguageModelSession over a handle with a test tool produces instructions/prompt/toolCalls/toolOutput/response events equivalent to what the RoutedSession chokepoint would record for the same conversation
- [ ] RecordingLevel.off and .metadataOnly and redact behave exactly as they do for RoutedSession
- [ ] Existing RoutedSession tests pass unchanged

## Tests
- [ ] Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift over a stub container + InMemoryRecorder: per-handle identity, diff-on-generate correctness, serial gate acquisition, level gating, redaction
- [ ] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness