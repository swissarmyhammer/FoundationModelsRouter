---
position_column: todo
position_ordinal: '8180'
title: Extract transcript-diff engine shared by RoutedSession and the recording handle
---
## What
Factor the last-seen-vs-current Transcript diff that RoutedSessionActor performs inside its recorder-bracketed generate chokepoint (Session/RoutedSession.swift) into a standalone type, suggested Recording/TranscriptDiffer.swift: given (lastSeen: Transcript, current: Transcript) plus session identity (routerId, sessionId, parentId, slot, model), produce the ordered TranscriptEvent.Partial values via the existing TranscriptEntryMapper. Rewire RoutedSessionActor to call it — behavior must be identical. Pure refactor plus new unit coverage; no public API change required (internal type is fine).

This gives the upcoming RecordingLanguageModel (see dependent task) and RoutedSessionActor ONE diff implementation instead of two.

## Acceptance Criteria
- [ ] Exactly one diff implementation; RoutedSessionActor delegates to it
- [ ] Diff emits correct events for instructions, prompt, response, reasoning, and — first-ever direct coverage — toolCalls and toolOutput entries
- [ ] All existing recording tests pass unchanged

## Tests
- [ ] Tests/FoundationModelsRouterTests/TranscriptDifferTests.swift over synthetic transcripts: empty to instructions+prompt; prompt to response; a tool-using turn (toolCalls, then toolOutput, then response); identical transcripts produce an empty diff; ordering is stable
- [ ] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd — write the differ tests against the extracted seam first.

#coding-harness