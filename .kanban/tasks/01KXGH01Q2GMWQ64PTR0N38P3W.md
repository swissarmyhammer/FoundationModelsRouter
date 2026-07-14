---
depends_on:
- 01KXGGZKB5RH9SZ9JP8QTS4V0A
position_column: todo
position_ordinal: '8480'
title: 'Gated integration: tool-using turn over a recording handle round-trips to disk'
---
## What
The end-to-end proof on a real model, gated by FM_ROUTER_INTEGRATION_TESTS=1 (Apple silicon + network): resolve a small real profile, build LanguageModelSession(model: profile.standard.makeLanguageModel(), tools: [scripted test tool], instructions: text), run one turn whose prompt reliably invokes the tool, call `handle.sync(session.transcript)` at turn end (exactly as harness frontends will — the turn-final response only reaches disk via sync, per task 3), and assert the on-disk recording. This is the FIRST live traffic ever for the tool-aware recording schema (Kind.toolCalls / Kind.toolOutput / ToolDefinitionPayload).

## Acceptance Criteria
- [ ] transcript.jsonl for the handle session contains, in order: session, instructions, prompt, toolCalls, toolOutput, response events (the response event lands via the turn-end sync)
- [ ] Before sync, everything up through toolOutput is already on disk (mid-turn diff back-fill works live)
- [ ] The session appears in sessions.jsonl with correct slot/model fields
- [ ] Reconstruction (MergedTranscript / TranscriptTree) over the recorded directory returns entries matching the live session transcript
- [ ] The ungated test suite is unaffected (test is skipped without the env var)

## Tests
- [ ] Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift, gated on FM_ROUTER_INTEGRATION_TESTS=1
- [ ] Run locally with DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer and the env var set; paste the observed event kinds sequence into a task comment

## Workflow
- Use /tdd for the assertion structure; the live run is the final gate.

#coding-harness