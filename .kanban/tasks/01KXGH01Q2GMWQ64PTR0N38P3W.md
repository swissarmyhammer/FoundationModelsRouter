---
comments:
- actor: claude-code
  id: 01kxhc9vf6m9arwdvrndtpmr34
  text: |-
    Implemented Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift, following the exact pattern of the 4 sibling gated integration suites (IntegrationTests.swift, LanguageModelSessionBackendTests.swift, SessionTreeRestorationIntegrationTests.swift, TranscriptReconstructionIntegrationTests.swift).

    Design:
    - Gated on FM_ROUTER_INTEGRATION_TESTS=1 via its own file-scoped `recordingHandleIntegrationEnvVar`/`recordingHandleIntegrationEnabled` (matching the other 4 files' pattern of per-file, not shared, constants).
    - Builds a LanguageModelProfile directly over a freshly loaded MLXFoundationModelsContainer (via LiveModelLoader + real Hub downloader/tokenizer loader macros), bypassing Router.resolve(_:reporting:) — the same manual-harness technique LanguageModelSessionBackendTests/TranscriptReconstructionIntegrationTests use, since only .standard is driven and downloading .flash/.embedding too would be wasted cost.
    - Gets a RecordingLanguageModel handle via profile.standard.makeLanguageModel(), constructs LanguageModelSession(model: handle, tools: [EchoTool()], instructions: ...) directly (mirroring EchoTool/the toolUsingTurnEndToEnd() test in Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift, the closest unit-test analog using a stub model over the identical handle/sync API).
    - Drives one respond() turn with a prompt/instructions pair directing the model to call the echo tool, asserts the on-disk transcript.jsonl before handle.sync(session.transcript) contains .session/.instructions/.prompt/.toolCalls/.toolOutput as an in-order subsequence with no .response yet, then after sync additionally contains .response as the last entry.
    - Asserts the handle's SessionIndexRecord lands in sessions.jsonl with the right slot/model (this required explicitly threading `await router.sessionIndexWriter` into every manually-built RoutedLLM/RoutedEmbedder — RoutedModel's own sessionIndexWriter field defaults to nil unless passed, and Router's own copy is actor-isolated so needs an explicit await; this was a real bug caught by an adversarial double-check pass before landing).
    - Asserts TranscriptTree.effectiveTranscript(forSession:) and MergedTranscript.merged(under:) reconstruction match the live session.transcript kind-for-kind.

    Design decision worth flagging: the acceptance criteria's exact ordered-sequence wording ("contains, in order") is checked via an in-order-subsequence helper rather than exact array equality, specifically to stay robust against a real (probabilistic) tiny model's likely variance — an extra .reasoning entry, or more than one tool-calling round before it settles — which would break brittle exact-equality but not the actual thing being tested (mid-turn back-fill ordering + sync closing the final-response gap). This softening was applied after an adversarial double-check review flagged the original exact-equality assertions as a real design/flakiness risk for a live run on a ~135M-param model.

    Verification performed in this sandbox (no GPU/network, so the live path itself could not be exercised — same limitation as the 4 existing gated suites):
    - `swift build --build-tests` — clean build, no errors/warnings introduced.
    - `swift test` (env var unset) — full suite: "Test run with 326 tests in 39 suites passed" (ungated suite unaffected) plus "Test run with 15 tests in 5 suites passed" for the gated suites, all correctly SKIPPED including the new "Gated real-model integration: a tool-using turn over a RecordingLanguageModel handle round-trips to disk (task 0n38p3w)" suite.

    Not done (cannot be done in this sandbox): actually running with FM_ROUTER_INTEGRATION_TESTS=1 set against a real Apple Silicon machine with network access to download mlx-community/SmolLM-135M-Instruct-4bit, to observe the real event-kind sequence and confirm the reconstruction/sessions.jsonl assertions hold on live hardware. No fabricated "observed sequence" was pasted — see the task description's Sandbox limitation section for what's needed to close this out. Leaving the task in `doing` per the /implement workflow for review.
  timestamp: 2026-07-14T22:35:00.966064+00:00
depends_on:
- 01KXGGZKB5RH9SZ9JP8QTS4V0A
position_column: doing
position_ordinal: '80'
title: 'Gated integration: tool-using turn over a recording handle round-trips to disk'
---
## What
The end-to-end proof on a real model, gated by FM_ROUTER_INTEGRATION_TESTS=1 (Apple silicon + network): resolve a small real profile, build LanguageModelSession(model: profile.standard.makeLanguageModel(), tools: [scripted test tool], instructions: text), run one turn whose prompt reliably invokes the tool, call `handle.sync(session.transcript)` at turn end (exactly as harness frontends will — the turn-final response only reaches disk via sync, per task 3), and assert the on-disk recording. This is the FIRST live traffic ever for the tool-aware recording schema (Kind.toolCalls / Kind.toolOutput / ToolDefinitionPayload).

## Acceptance Criteria
- [ ] transcript.jsonl for the handle session contains, in order: session, instructions, prompt, toolCalls, toolOutput, response events (the response event lands via the turn-end sync)
- [ ] Before sync, everything up through toolOutput is already on disk (mid-turn diff back-fill works live)
- [ ] The session appears in sessions.jsonl with correct slot/model fields
- [ ] Reconstruction (MergedTranscript / TranscriptTree) over the recorded directory returns entries matching the live session transcript
- [x] The ungated test suite is unaffected (test is skipped without the env var)

## Tests
- [x] Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift, gated on FM_ROUTER_INTEGRATION_TESTS=1
- [ ] Run locally with DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer and the env var set; paste the observed event kinds sequence into a task comment

## Workflow
- Use /tdd for the assertion structure; the live run is the final gate.

## Sandbox limitation (see comments for full detail)
This sandbox has no Apple Silicon GPU and no network access to the Hub, so FM_ROUTER_INTEGRATION_TESTS=1 was never actually set against a live run here — the same situation as the 4 pre-existing gated suites in this directory. The new suite is verified to compile cleanly (`swift build --build-tests`) and to correctly skip (not run) under a normal `swift test` invocation without the env var, and the full ungated suite (326 tests) stays green. The acceptance-criteria checkboxes above that require an actual observed live-run event sequence are intentionally left unchecked — no fabricated "observed event kinds" was pasted in. To finish those, someone needs to run this suite on a real Apple Silicon Mac with network access (so `mlx-community/SmolLM-135M-Instruct-4bit` can be downloaded/cached), `FM_ROUTER_INTEGRATION_TESTS=1` set, and DEVELOPER_DIR pointed at a toolchain with the FoundationModels SDK, then report back whether the assertions hold.

#coding-harness

## Review Findings (2026-07-14 17:40)

- [x] `Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift:149` — Two similar JSONL-reading functions handle missing files differently: `recordedEvents` (line 142) guards with `FileManager.fileExists()` and returns `[]` if absent, but `sessionIndexRecords` will throw if `sessions.jsonl` doesn't exist. This inconsistency means if indexing fails to write the file, the test throws a file-not-found error rather than a meaningful assertion failure. Apply the same guard to `sessionIndexRecords` — return `[]` if the file doesn't exist, so test assertions (not file errors) fail if indexing doesn't land in `sessions.jsonl`.
- [x] `Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift:176` — Function `sessionIndexRecords` duplicates the JSONL file reading and decoding logic of `recordedEvents` with only the filename and decoded type varying. This near-match should be refactored into a single generic helper rather than written as a parallel copy. Extract a generic helper function that accepts the directory, filename, and decoded type as parameters, eliminating the duplicate pattern. For example: `private static func readJSONLFile<T: Decodable>(in directory: URL, fileName: String, checkExists: Bool = false) throws -> [T]` called by both functions.
