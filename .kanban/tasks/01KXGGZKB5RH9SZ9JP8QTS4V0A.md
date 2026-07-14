---
depends_on:
- 01KXGGZ3ETZEH6PMG3VEM16AZ8
position_column: todo
position_ordinal: '8380'
title: Resume and fork lineage for recording handles
---
## What
Add resume support to the recording handle: makeLanguageModel(resuming: sessionId) (exact spelling per taste — a parameter on the factory). Semantics:

- primes the handle last-seen Transcript with the restored session transcript so the FIRST generate call records only NEW entries — never re-records the whole history into a fresh directory
- writes a SessionIndexRecord carrying parentId and forkedAtEntryCount, reusing the existing lineage semantics from Recording/SessionIndex.swift
- pairs with LanguageModelSession(model: handle, tools: realTools, transcript: restored) — note this is how restored sessions finally get real tools, which the current fork/restore path (tools hardwired empty in LiveModelLoader) cannot do

## Acceptance Criteria
- [ ] Recording a session, resuming it, and continuing yields a child session whose transcript.jsonl contains only post-resume events
- [ ] The child SessionIndexRecord references the parent id and fork entry count; TranscriptTree / MergedTranscript reconstruction over parent plus child yields the full conversation
- [ ] Resuming with a different tool set works

## Tests
- [ ] Tests/FoundationModelsRouterTests/RecordingHandleResumeTests.swift — record N entries via a stub, resume, continue one turn, assert child directory has only the new events and the lineage fields are correct; reconstruction test asserts the merged transcript equals the full conversation
- [ ] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness