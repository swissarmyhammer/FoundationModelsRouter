---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tyf11zcmw0s5hvga5sxg9z
  text: |-
    Research (implement):
    - Extras at f99b111 has no `SessionDirectoryOrigin.import` (cases: client, tool, message, trigger, fork). The origin stays a parameter: `SessionConfiguration.origin` gives it.
    - A live session records through `RoutedModel.recorder` (the router `JSONLRecorder`, wrapped in `GatingRecorder` for the level and the redact hook) with `TranscriptDiffer.partials` -> `TranscriptEntryMapper.event(from:)`. Its first event is a `.session` meta event. The recorder is best effort: a failed append is logged and dropped, so a writer that must be atomic must read the file back and count the events.
    - The restore takes the compaction budget from the configuration envelope of the record (`SessionRecord.configuration`, `SessionTreeRestoration` rebuild). So the writer records `SessionConfiguration.persistable` as a live session does, and the restore gives the same `autoCompactionBudget` with no new rule.
    - `TranscriptTree.load` finds a session by its `index.md` and throws `sessionDirectoryNotIdentified` for a folder whose name is not a ULID. A temporary folder in the same root that a process crash leaves (not a thrown failure) therefore makes a later load throw. A thrown failure removes the temporary folder.
    - `SessionRecord.firstActivityAt` nil hides a session from a client listing; the writer sets it at the write when the transcript holds a prompt.
  timestamp: 2026-11-19T22:22:33.023788+00:00
- actor: claude-code
  id: 01m7tz62er6jrz8j71zwb620ma
  text: |-
    Implementation landed (not committed):
    - Public API: `RoutedModel<any LoadedLLMContainer>.recordSession(from transcript: Transcript, configuration: SessionConfiguration) async throws -> ULID`, and `public enum SessionRecordingWriteError { case noDurableRecording; case eventsNotWritten(expected: Int, written: Int) }` in `Sources/FoundationModelsRouter/Recording/TranscriptSessionWriter.swift`. The origin, the title and the agent come from the `SessionConfiguration` fact fields (`origin` today is `.client`/`.tool`/...; part 2 gives `.import`).
    - The events go through the handle recorder (`recorder.append(_:to:)`, the live writer with the level and redact gate) and `TranscriptDiffer.partials` -> `TranscriptEntryMapper`. The writer reads `transcript.jsonl` back and throws `eventsNotWritten` when the recorder dropped an event.
    - The restore gives the recorded budget from the configuration envelope. The proactive trigger needs a measured size, and a written history has no `.generationCall` event, so the writer stamps the last `.response` event with `tokensIn` = the size of the transcript by the model's own `tokenCounter`, `tokensOut` = 0 (the same stamp a live submission writes). No compaction rule changed. A mutation run without the stamp makes the compaction test fail.
    - Atomic folder: a hidden temporary folder `.<id>.writing` beside the session folder in the same root, then `moveItem`. A thrown failure removes it (a mutation run without the removal makes the no-folder test fail).
    - Found: `TranscriptTree.load` threw `sessionDirectoryNotIdentified` for a temporary folder in the root (proved RED by a test). `TranscriptFileDiscovery.fileURLs` now skips hidden files and folders (`.skipsHiddenFiles`); a session folder is a ULID name, so a hidden folder is never a session.
    - Test support: the plain-import resolve stubs (`FixedMachineProbe`, `CannedMetadataSource`, `ZeroEmbeddingContainer`, `ResolveOnlyContainer`, `ReportingLoader`, `PlainImportResolveStubs.rawMetadata`) moved from private types of `ResolutionProgressPublicSurfaceTests` to `Tests/FoundationModelsRouterTestSupport/PlainImportResolveStubs.swift`, so the new public-surface test shares them.
  timestamp: 2026-11-19T22:35:08.120211+00:00
- actor: claude-code
  id: 01m7tz7tyfrjg37x4nk49p68z5
  text: |-
    ### implement — changed
    - evidence: `public func recordSession(from transcript: Transcript, configuration: SessionConfiguration) async throws -> ULID` on `RoutedModel where Container == any LoadedLLMContainer` (RoutedLLM), with `public enum SessionRecordingWriteError { noDurableRecording, eventsNotWritten(expected:written:) }`. Files: Sources/FoundationModelsRouter/Recording/TranscriptSessionWriter.swift (new), Sources/FoundationModelsRouter/Recording/TranscriptFileDiscovery.swift (skips hidden folders), Tests/FoundationModelsRouterTests/RecordSessionFromTranscriptTests.swift (new, 9 tests), Tests/FoundationModelsRouterPublicSurfaceTests/RecordSessionPublicSurfaceTests.swift (new, 1 test), Tests/FoundationModelsRouterTestSupport/PlainImportResolveStubs.swift (new), Tests/FoundationModelsRouterPublicSurfaceTests/ResolutionProgressPublicSurfaceTests.swift (uses the shared stubs). RED seen for each new test (a stub writer, two mutation runs, the discovery test before the change). Filtered: RecordSessionFromTranscriptTests 9 passed; RecordSessionPublicSurfaceTests 1 + ResolutionProgressPublicSurfaceTests 4 passed. Full `swift test` once: 3211 tests in 363 suites passed, 52 in 28 and 19 in 3 passed, exit 0, no compiler warnings (output in scratchpad/full-suite.txt). Origin stays a configuration parameter; part 2 (^0hdvn00) adds `.import`, `importedFrom` and the directory operation.
    - next: /review
  timestamp: 2026-11-19T22:36:05.967443+00:00
position_column: doing
position_ordinal: '80'
title: A public writer makes a new session recording from a given model transcript, with no live session (D209 (h), part 1)
---
## Goal

An imported session (Claude Code or Codex history) becomes a normal recorded session of our agent: the Router writes a new recording from a given model transcript, and the session opens through the normal restore. Decision D209 (`TestudoApp/features/decisions.md`, commit 56a8a59), part (h); the user chose the full history and the normal automatic compaction at the first turn (Q83, D209 (n)). Brief: `../.briefs/import/router-brief.md` items 1 and 4; overview `overview.md`.

This part needs no Extras change. The provenance fact and the directory operation are part 2.

## Current code

- `SessionRecord` is the frontmatter of `index.md` (`Sources/FoundationModelsRouter/Recording/SessionRecord.swift:4-20`, fields `:85-172`); facts written flat (`SessionFacts.swift`, `origin`).
- `transcript.jsonl` holds one `TranscriptEvent` for each line (`Recording/TranscriptTree.swift:5`, `Recording/TranscriptEvent.swift`), appended by `JSONLAppend.swift:16`.
- No public API makes a session from a given history: `RoutedLLM.makeSession` takes no transcript (`RoutedLLM.swift:111-133`); the seed from a transcript is internal (`Resolution/ModelLoader.swift:50-55`); a fork needs a live source.
- A restore rebuilds the transcript from the recording (`Recording/TranscriptReconstruction.swift`, `Recording/SessionTreeRestoration.swift:428-459`) and gives the session its `autoCompactionBudget` (`SessionTreeRestoration.swift:648`).

## Change

1. A public function that writes a new recording with no live session: a new ULID; the folder `<recording root>/<id>/`; `index.md` with a `SessionRecord` (the `cwd`, the agent facts, the title, the origin `import`, `schemaVersion`, and the slot and profile of the default of the agent); `transcript.jsonl` with one event for each entry of the given `Transcript` (the instructions entry when there is one, prompts, responses; the caller gives tool calls as short text and no thoughts). Use the same event writer and the same entry mapper as a live session (`TranscriptEntryMapper`), so the restore reads the file with no special case. Choose the public name and signature (for example on `RoutedModel` or a `SessionRecordingWriter`).
2. The write is atomic for the folder: write into a temporary folder in the same root, then rename; a failure leaves no folder.
3. The origin `import`: if Extras does not have `SessionDirectoryOrigin.import` yet, keep the origin a parameter of the writer and set it in part 2.
4. Restore: a restore of the written session gives the normal `autoCompactionBudget`. Add no new compaction rule.

Read `routed-session-cancellation-invariants` and `sdk-transcript-read-between-passes` in the memory folder.

## Tests

- [x] Write a recording from a transcript of three turns, then restore it: the effective transcript equals the given one, the session is a `root`, and the record reads back.
- [x] A transcript larger than the budget: the first turn after the restore compacts (the stub model of the tests).
- [x] A failed write leaves no folder (and no temporary folder).
- [x] A public-surface test calls the writer through a plain import.

## After

Push when green. Send the name, the signature and the sha to foundationmodelsacpagent-9e and testudoapp-9a. #d209