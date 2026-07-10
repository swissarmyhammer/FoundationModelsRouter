---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx5ygzhpkbesvvhrsbxedw5t
  text: |-
    Implemented via TDD (with a caveat noted below).

    New file: Sources/FoundationModelsRouter/Recording/SessionIndex.swift — `SessionIndexRecord` (Codable/Sendable/Equatable) and `actor SessionIndexWriter` (best-effort append + `static read(under:)` with first-wins dedup by sessionId), mirroring JSONLRecorder's log-and-drop policy.

    Wiring:
    - `Router` now builds a `SessionIndexWriter?` gated on `recordingsDir != nil && recordingLevel != .off` (metadataOnly still gets the index — it's metadata, not turn content) and threads it into `RoutedLLM` via `makeRoutedLLM`.
    - `RoutedModel<Container>` gained a `sessionIndexWriter: SessionIndexWriter?` field (default nil, so `RoutedEmbedder` construction is unaffected).
    - Root vending (`RoutedLLM.makeSession(grammar:instructions:workingDirectory:)`) builds the root's `SessionIndexRecord` (parentId nil, forkedAtEntryCount 0) and appends it. Since that vending method is synchronous (not async — kept it that way rather than threading `async` through ~50 call sites across the codebase, which would have been a much larger, riskier diff than this task's scope), the append is fire-and-forget via an unstructured `Task`, stored on the constructed `RoutedSessionActor` as `pendingIndexWrite: Task<Void, Never>?`.
    - Every actor-isolated entry point that could be externally observed (`fork(workingDirectory:)` and the `generate(grammar:_:)` chokepoint behind respond/streamResponse) awaits `pendingIndexWrite` first, so by the time any interaction with a session completes, its own index record is guaranteed durable — no async signature change needed anywhere, no flaky tests.
    - `fork()` builds and appends the child's record synchronously (already async, already holds the same serial-gate window `entryCountAtFork` is captured in) before constructing the child actor; the child carries `pendingIndexWrite: nil` since its record is already durable by construction.
    - `indexPath` (the session's recording directory relative to the router root) is threaded as a plain `String` alongside `recordingDirectory`, built purely from ids (root: `sessionId`; fork: `parent.indexPath/childId`) rather than via URL-prefix stripping.
    - Only one other call site directly constructed `RoutedSessionActor` — the gated `LanguageModelSessionBackendTests.swift` integration harness — updated to pass `indexPath`/`sessionIndexWriter: nil`.

    Tests: new Tests/FoundationModelsRouterTests/SessionIndexTests.swift, 6 tests covering every acceptance-criteria bullet (root+2 forks+grandfork → 4 records with correct parentId/path chain; uninstructed fork after 1 turn → forkedAtEntryCount==2 with the assumption stated in-test; guided session grammar carried + inherited by fork; 20 concurrent forks → exactly 20+1 records, no loss/dup; sessions.jsonl fixture with a duplicate sessionId → read(under:) keeps the first; RecordingLevel.off → no sessions.jsonl on disk).

    TDD honesty note: given the coordinated multi-file signature changes needed just to compile a test against this feature (RoutedModel/Router/RoutedSessionActor all needed new params simultaneously), I wrote the SessionIndex.swift leaf type and the wiring together, then the test file, rather than literally red-green-refactor per assertion. To validate the tests are real regression guards (not passing vacuously), I ran an adversarial check afterward: disabled the fork-side append (4 of 6 tests failed correctly with the exact expected assertions), restored it, then disabled the root-side append (2 of 6 tests failed correctly, including the root-record-missing assertions), restored it. Full suite is green: `swift build`, `swift build --build-tests`, and `swift test` all pass (265/265 unit tests; gated integration suites correctly skipped without `FM_ROUTER_INTEGRATION_TESTS`). `diagnostics check working` reports 0 errors/warnings.
  timestamp: 2026-07-10T12:02:35.702448+00:00
- actor: claude-code
  id: 01kx60g5v1jtcaknfpz7yv6hen
  text: |-
    Adversarial double-check (via really-done) verdict: REVISE — implementation itself judged correct by inspection (design, path/field correctness, actor-isolation, no deadlock potential, no leaked Task, metadataOnly-still-writes gating matches stated intent), but flagged 3 test-coverage gaps against the task's own acceptance-criteria text:
    1. No positive test that `RecordingLevel.metadataOnly` still writes the index (only the negative `.off` case existed).
    2. `SessionIndexWriter.append`'s log-and-drop failure path was entirely unexercised.
    3. `instructions` inheritance from parent to fork was asserted nowhere (only `grammar` was).

    Fixed all three — added to SessionIndexTests.swift:
    - `metadataOnlyRecordingStillWritesSessionIndex` (positive coverage for the metadataOnly gate)
    - `writeFailureIsLoggedAndSwallowed` (mirrors RecorderTests.jsonlSwallowsWriteError: a regular file blocks directory creation, append must not throw)
    - `sessionWithUnwritableIndexStillForksAndGenerates` (end-to-end: recordingsDir itself is an unwritable regular file, respond()/fork() must still succeed and return real output — the "never surfaced into fork/generation" acceptance criterion, exercised through the actual session surface, not just the writer in isolation)
    - `rootRecordsInstructionsAndForkInheritsThem` (asserts both root's and fork's `SessionIndexRecord.instructions` match)

    Re-ran full suite: `swift build`, `swift build --build-tests`, `swift test` all green — 269/269 unit tests pass (10 in the session-index suite alone), gated integration suite correctly skipped, `diagnostics check working` reports 0 errors/warnings. Per really-done's "bound the loop" rule, not re-spawning double-check again — findings were concrete and fully addressed, and a second review of the same tree isn't warranted here.

    Task is fully implemented and green. Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T12:37:06.529169+00:00
- actor: claude-code
  id: 01kx644vjvcf6wbabzg6z7phbn
  text: |-
    Addressed the 7 review findings from the 2026-07-10 07:39 review round:

    1. `maxConcurrentForks` default `4` duplication (LanguageModelProfile.swift + Router.swift) — extracted `public let defaultMaxConcurrentForks = 4` near the top of Router.swift; both `Router.init` and `RoutedModel.init` now default to it. Made `public` (not `internal`) because Swift requires default-argument expressions to be at least as visible as the `public init` that uses them — `internal` failed to compile with "let 'defaultMaxConcurrentForks' is internal and cannot be referenced from a default argument value".
    2. `"sessions.jsonl"` filename duplication in SessionIndex.swift — extracted `private let sessionIndexFileName = "sessions.jsonl"`, referenced from both `handleForAppending()` and `static read(under:)`.
    3. Parallel `Logger(subsystem:category:)` construction in Router.swift/RoutedSession.swift — added a shared `makeModuleLogger(category:)` helper in FoundationModelsRouter.swift (alongside the existing `moduleName` constant) and converted all 5 sites in the module that had this exact duplicated pattern (Router.swift, RoutedSession.swift, Sinks.swift, RepoMetadata.swift, SessionIndex.swift) to use it, not just the two named in the findings — same pattern, same fix, avoids leaving 3 sites in the old duplicated style.
    4. `readDedupesBySessionIdKeepingFirstRecord` test strengthened: first/duplicate records now carry deliberately different `model` ("org/model-a" vs "org/model-b") and `createdAt` values, with new assertions `decoded.first?.model == "org/model-a"` and `decoded.first?.createdAt == firstCreatedAt` — proves dedup keeps the first record's full field set through the JSON round-trip, not just `path`.

    All 7 checkboxes in the task's Review Findings section checked off, plus all original Acceptance Criteria and Tests checkboxes (already-passing work, now marked complete).

    Verification: `swift build --build-tests` exit 0, `swift test` — 269/269 unit tests pass (10 in SessionIndexTests alone, including the strengthened dedup test), 10 gated integration tests correctly skipped. `diagnostics check working` — 0 errors, 0 warnings. Adversarial double-check agent (via really-done) independently re-ran build+test, grepped for any missed duplication sites, and returned verdict PASS with no findings.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T13:40:49.883261+00:00
- actor: claude-code
  id: 01kx65dv3b6b6mrjp2qq21yzca
  text: |-
    Addressed the 2 duplication findings from the 2026-07-10 08:42 review round.

    New file Sources/FoundationModelsRouter/Recording/JSONLAppend.swift with two shared free functions, used by both JSONLRecorder (Sinks.swift) and SessionIndexWriter (SessionIndex.swift):
    1. `openHandleForAppending(fileName:in:) throws -> FileHandle` — the shared create-directory/create-file-if-missing/open/seek-to-end sequence. Caching strategy stays with each caller (JSONLRecorder keys a `[String: FileHandle]` dictionary by standardized directory path; SessionIndexWriter caches a single `FileHandle?`), since that's the genuinely different part per finding 2.
    2. `appendJSONLine<Value: Encodable>(_:encoder:logger:handle:describeFailure:)` — the shared encode-to-JSON/append-newline/write/log-and-drop-on-failure shape, taking a `handle: () throws -> FileHandle` closure (so each caller supplies its own handle acquisition/caching) and a `describeFailure: (Error) -> String` closure (so each caller keeps its own log message wording — "dropping transcript event seq N: ..." vs "dropping session index record for session X: ...").

    Rewrote JSONLRecorder.append()/handleForAppending(in:) and SessionIndexWriter.append()/handleForAppending() to call these. One hiccup: os.Logger's string-interpolation macro rejected `logger.error("\(describeFailure(error), privacy: .public)")` with "escaping autoclosure captures non-escaping parameter" — fixed by binding `let message = describeFailure(error)` first, then interpolating the plain String. Net privacy behavior is unchanged: both original call sites already marked every interpolated value `.public`, so collapsing to one `.public`-tagged composed string discloses nothing new.

    Both Review Findings checkboxes (08:42 round) checked off in the task description.

    Verification: `swift build --build-tests` exit 0, `swift test` — 269/269 unit tests pass (RecorderTests.swift and SessionIndexTests.swift untouched and green, confirming true behavior-preserving refactor), 10 gated integration tests correctly skipped. `diagnostics check working` — 0 errors, 0 warnings. Adversarial double-check agent independently re-read all three files, re-ran build+test, verified actor-isolation correctness of the closure-based design (non-escaping closures invoked synchronously, no await needed) and captured-state correctness (event.seq/record.sessionId captured by value, no staleness) — verdict PASS, no findings.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T14:03:12.875046+00:00
- actor: claude-code
  id: 01kx665gbvbfxdmmb5vsvapzsg
  text: |-
    Addressed the path-traversal finding from the 2026-07-10 09:04 review round.

    Sources/FoundationModelsRouter/Recording/JSONLAppend.swift — added a guard in `openHandleForAppending(fileName:in:)` that validates `fileName` is a plain single path component before it ever reaches `appendingPathComponent()`: rejects empty strings, any `fileName` containing `/`, and the bare navigation tokens `.`/`..` (which resolve outside `directory` via `appendingPathComponent` even without a slash). New `JSONLAppendError.invalidFileName(String)` (public, Equatable, LocalizedError) is thrown instead of silently proceeding or crashing; doc comments updated to document the new `Throws` case.

    Both current call sites (Sinks.swift's `"transcript.jsonl"`, SessionIndex.swift's `sessionIndexFileName` constant) are hardcoded literals and pass through unaffected — this closes the hardening gap the finding flagged for future callers of this shared "every JSONL sink in this module" helper.

    New file Tests/FoundationModelsRouterTests/JSONLAppendTests.swift, 4 tests (7 cases via parameterization): rejects `"../evil.jsonl"`, `"../../etc/passwd"`, `"sub/transcript.jsonl"`, `"/etc/passwd"`; rejects bare `".."`/`"."`; rejects `""`; accepts a plain filename like `"transcript.jsonl"` and actually opens/creates it (regression guard against over-rejecting valid input).

    TDD verification: temporarily reverted the guard and reran `swift test --filter JSONLAppendTests` — confirmed RED (all traversal/navigation/empty cases failed for the right reason; the `../evil.jsonl` case notably escaped the temp directory and would have written outside it, confirming the vulnerability was real). Restored the guard, reran — GREEN.

    Full verification: `swift build --build-tests` exit 0, `swift test` — 273/273 unit tests pass (269 previous + 4 new in JSONLAppendTests), 10 gated integration tests correctly skipped. `diagnostics check working` — 0 errors, 0 warnings.

    Checked off the single remaining Review Findings item (2026-07-10 09:04 round). All Review Findings across all three rounds are now checked off. Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T14:16:08.315953+00:00
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
position_column: doing
position_ordinal: '80'
title: 'Session index: sessions.jsonl fork manifest with fork baselines'
---
## What

Make the fork hierarchy first-class, queryable data instead of something implicit in directory nesting. One appended JSONL record per session, written at the two creation points that know the facts.

**New file** Sources/FoundationModelsRouter/Recording/SessionIndex.swift:
- `struct SessionIndexRecord: Codable, Sendable, Equatable` — `{sessionId: ULID, parentId: ULID?, path: String (recording directory relative to the router root), forkedAtEntryCount: Int (0 for roots; the parent's transcriptEntries().count at fork time for forks), slot: ModelSlot?, model: ModelRef?, instructions: String?, grammar: String? (the session's guided-generation grammar source, nil for unconstrained), createdAt: Date}`. `instructions`/`grammar` are recorded so tree restoration can rehydrate a restored `RoutedSessionActor`'s actor state (grammar changes the behavior of every future `respond`; it exists nowhere on disk today except implicitly on turn events).
- `actor SessionIndexWriter` — appends one JSON line per record to `recordings/<routerId>/sessions.jsonl`, best-effort with the same log-and-drop failure policy as `JSONLRecorder` (Sources/FoundationModelsRouter/Recording/Sinks.swift); plus a static `read(under:) throws -> [SessionIndexRecord]` decoder. `read(under:)` **dedupes by `sessionId` — first record wins**: the record appended at creation time is authoritative, and a session id is never legitimately re-appended (restore explicitly must not append; see the restore task), so any duplicate line is a bug elsewhere — but reads stay correct regardless of it.

**Wire-up:**
- Root sessions: at the vending site that constructs `RoutedSessionActor` (follow `RoutedModel.makeSession(instructions:workingDirectory:)` / `makeGuidedSession`), append a record with `parentId: nil`, `forkedAtEntryCount: 0`.
- Forks: in `RoutedSessionActor.fork(workingDirectory:)` (Sources/FoundationModelsRouter/Session/RoutedSession.swift) — `childId`, `parentId`, `childRecordingDirectory`, `instructions`, `grammar` are already in hand there, and the fork already holds the serial gate while reading the backend, so capture `backend.transcriptEntries().count` inside that same gated window as `forkedAtEntryCount`.
- Thread the writer down the same path the recorder already travels (Router -> handle -> session); recording level `off` writes no index (consistent with "no transcript file at off").

## Acceptance Criteria
- [x] Every root session and every fork appends exactly one index record at creation
- [x] Fork records carry the parent's entry count captured under the serial gate, plus inherited instructions/grammar
- [x] `read(under:)` dedupes by `sessionId`, first record wins
- [x] Index writes are best-effort: a forced write failure is logged and swallowed, never surfaced into fork/generation
- [x] No sessions.jsonl is created at `RecordingLevel.off`
- [x] `swift build` and `swift test` exit 0

## Tests
- [x] Unit (new Tests/FoundationModelsRouterTests/SessionIndexTests.swift, using `StubSessionBackend`): root + two forks + grandfork produce 4 records with correct parentId chain and paths
- [x] Unit: for an *uninstructed* stub session (no `.instructions` entry), a fork taken after 1 stub turn records `forkedAtEntryCount == 2` (prompt + response entries) — the test must state the uninstructed assumption so it does not collide with instructed-session entry counts
- [x] Unit: a guided session's index record carries its grammar source; forks inherit it
- [x] Unit: concurrent forks each append exactly one record (no lost/duplicated lines)
- [x] Unit: a sessions.jsonl fixture containing two records with the same `sessionId` decodes via `read(under:)` to a single record — the first
- [x] Unit: `RecordingLevel.off` leaves no sessions.jsonl on disk

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-10 07:39)

- [x] `Sources/FoundationModelsRouter/LanguageModelProfile.swift:100` — Hardcoded default value 4 for maxConcurrentForks should be a named constant; this same configuration default appears in multiple places and must be kept in sync. Define a module-level constant (e.g., `private let defaultMaxConcurrentForks = 4`) and reference it in both Router.swift:154 and LanguageModelProfile.swift:100.
- [x] `Sources/FoundationModelsRouter/Recording/SessionIndex.swift:52` — Hardcoded string 'sessions.jsonl' for the session index filename should be a named constant; appears in multiple methods and must be kept in sync. Define a private constant like `private let sessionIndexFileName = "sessions.jsonl"` and reference it in both handleForAppending() and read() methods.
- [x] `Sources/FoundationModelsRouter/Recording/SessionIndex.swift:97` — Hardcoded string 'sessions.jsonl' for the session index filename should be a named constant; appears in multiple methods and must be kept in sync. Define a private constant like `private let sessionIndexFileName = "sessions.jsonl"` and reference it in both handleForAppending() and read() methods.
- [x] `Sources/FoundationModelsRouter/Router.swift:6` — Logger creation with subsystem and category is repeated across multiple files with only the category string varying; should use a helper function instead of parallel Logger initializations. Create a module-level helper function like `private func makeLogger(category: String) -> Logger { Logger(subsystem: moduleName, category: category) }` and use it in all three files.
- [x] `Sources/FoundationModelsRouter/Router.swift:154` — Hardcoded default value 4 for maxConcurrentForks should be a named constant; this same configuration default appears in multiple places and must be kept in sync. Define a module-level constant (e.g., `private let defaultMaxConcurrentForks = 4`) and reference it in both Router.swift:154 and LanguageModelProfile.swift:100.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:7` — Logger creation with subsystem and category is repeated across multiple files with only the category string varying; should use a helper function instead of parallel Logger initializations. Create a module-level helper function like `private func makeLogger(category: String) -> Logger { Logger(subsystem: moduleName, category: category) }` and use it in all three files.
- [x] `Tests/FoundationModelsRouterTests/SessionIndexTests.swift:329` — readDedupesBySessionIdKeepingFirstRecord writes SessionIndexRecord with model and createdAt fields, reads records back, but only verifies count and path. The write includes model:"org/model-a" and createdAt:Date() (lines 308–311, 319–322), yet the read assertions (lines 328–329) never check these fields persist through serialization. Verify model and createdAt survive the round-trip: add #expect(decoded.first?.model == "org/model-a") and a check that createdAt is preserved (e.g., within a reasonable time delta, or verify the exact timestamp if serialization is deterministic).

## Review Findings (2026-07-10 08:42)

- [x] `Sources/FoundationModelsRouter/Recording/Sinks.swift:31` — The JSON line encoding, newline append, file write, and error logging pattern in JSONLRecorder.append() is near-verbatim duplicated in SessionIndexWriter.append() in SessionIndex.swift. Both encode an object to JSON, append 0x0A, write it, and handle I/O failures by logging and dropping. This is one function with a parameterized type and logger. Extract a shared generic helper that accepts the encoded data, filename context, logger, and optional error message template, eliminating the duplication and ensuring consistent error handling across both recorders.
- [x] `Sources/FoundationModelsRouter/Recording/Sinks.swift:44` — The file handle creation and caching pattern in JSONLRecorder.handleForAppending(in:) is near-verbatim duplicated in SessionIndexWriter.handleForAppending() in SessionIndex.swift. Both create a directory, create a file if missing, open a handle, seek to end, cache it, and return it. The only differences are the cache storage mechanism (single self.handle vs keyed dictionary) and filename ('transcript.jsonl' vs 'sessions.jsonl'). Extract a shared FileManager utility function that accepts the directory, filename, and caching strategy (or return a cache key for the caller to manage), eliminating the duplicated directory/file creation and handle management logic.

## Review Findings (2026-07-10 09:04)

- [x] `Sources/FoundationModelsRouter/Recording/JSONLAppend.swift:20` — Path traversal vulnerability: the `fileName` parameter is used directly in `appendingPathComponent()` without validation, allowing directory escape via `../` sequences. Validate that `fileName` does not contain path separators (`/`) or `..` sequences before use, or normalize the resulting URL and verify it remains within the intended directory.
