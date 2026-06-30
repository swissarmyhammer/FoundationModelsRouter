---
comments:
- actor: wballard
  id: 01kwcxzf33jsyemtxsfe2gdcvx
  text: |-
    Implemented the recording substrate TDD-style (failing RecorderTests first, watched RED = missing symbols, then GREEN).

    Files:
    - Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift — struct TranscriptEvent: Sendable, Codable, Equatable with all provenance fields (routerId/sessionId/parentId?/slot?/model?/seq/ts/kind/grammar?/tokensIn?/tokensOut?/ms?), nested enum Kind: String (session/prompt/response/toolCall/toolOutput/embedding), and nested struct Partial (everything minus seq/ts) with .stamped(seq:ts:) -> TranscriptEvent.
    - Sources/FoundationModelsRouter/Recording/TranscriptRecorder.swift — protocol TranscriptRecorder: Sendable { func append(_:) async }; dot-syntax factories via `where Self ==` extensions: .jsonl(directory:now:), .inMemory, .none.
    - Sources/FoundationModelsRouter/Recording/Sinks.swift — JSONLRecorder (actor; lazy-opened reused FileHandle; one compact JSON line + \n per append; best-effort: catches I/O errors and logs via os.Logger, never throws), InMemoryRecorder (actor; events in seq order), NoneRecorder (stateless struct no-op sharing the async append path). seq assigned monotonically by the actor at append; ts from injectable @Sendable () -> Date clock (defaults to Date()).
    - Sources/FoundationModelsRouter/Core/ModelSlot.swift — added String raw value + Codable (was Sendable, Hashable only; required so TranscriptEvent.slot is Codable; ModelSlot had no other callers). Encodes as clean string matching ModelRef style.

    Design notes: recorder is an actor so seq stamping + storage happen in one isolated critical section -> contiguous 0..<n total order under concurrent appends, asserted deterministically (no sleeps). Forced-error test points JSONLRecorder.directory at a regular file so createDirectory throws every append -> swallowed; asserts the file is untouched and append returns.

    Results (DEVELOPER_DIR=Xcode-beta): `swift build` clean; `swift test --filter RecorderTests` 6/6 pass; full `swift test` 31 tests + 1 integration placeholder all green, no warnings from new code. Left in `doing`. Adversarial double-check running.
  timestamp: 2026-06-30T18:52:00.995988+00:00
- actor: wballard
  id: 01kwcy6krq6sv1ejz897v7gs0g
  text: 'Adversarial double-check: VERDICT PASS. Confirmed concurrency/seq monotonicity is deterministic (500-append TaskGroup asserting Array(0..<500), no sleeps), JSONL line-per-event holds (compact encoder, control chars escaped, lone trailing 0x0A), forced-write-error catch path genuinely exercised (blocker file stays empty/regular), and all 12 provenance fields round-trip (deferredToDate exact at 1000.5). No defects. Only build warnings are pre-existing mlx-swift/HostProfile noise, none in the new code. ModelSlot change has zero external blast radius. Task left in `doing`, green, ready for /review.'
  timestamp: 2026-06-30T18:55:55.159729+00:00
- actor: wballard
  id: 01kwcyp6ksacjq0g9dd663vm3m
  text: 'Resolved review finding: inlined the single-call-site `appendAll` helper into `noneRecordsNothing` in RecorderTests.swift and removed the helper. The protocol-existential intent is preserved by binding `let recorder: any TranscriptRecorder = NoneRecorder.none` and looping `await recorder.append(partial)`, with a comment explaining the existential is used to exercise the shared append path. Test-only change; production Recording/ sources untouched. `swift test --filter RecorderTests` green (6/6); full `swift test` green (31 tests, integration skipped, exit 0). Task left in `doing` for review.'
  timestamp: 2026-06-30T19:04:25.977258+00:00
depends_on:
- 01KWC5BTMHH3K50437WBVFG9NT
position_column: doing
position_ordinal: '80'
title: 'Recording substrate: TranscriptRecorder protocol + sinks + event model'
---
## What
The recording plumbing that sessions are *born holding* (plan "Transcripts & recording"). Built early so the access layer (milestone 5) can take a non-optional recorder with no public way to skip it. Full event emission + lineage nesting come later (milestone 10) — this task is the protocol, sinks, and event type.

- `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift`:
  - `struct TranscriptEvent: Sendable, Codable` with provenance fields: `routerId, sessionId, parentId?, slot?, model?, seq, ts, kind, grammar?, tokensIn?, tokensOut?, ms?` and `enum Kind { session, prompt, response, toolCall, toolOutput, embedding }`.
- `Sources/FoundationModelsRouter/Recording/TranscriptRecorder.swift`:
  - `protocol TranscriptRecorder: Sendable` — the recorder is an actor that **assigns `seq` + `ts` at append** so concurrent forks produce a totally-ordered log. `func append(_ partial: …) async` (the recorder stamps seq/ts).
  - Static factory members `.jsonl`, `.inMemory`, `.none` (a no-op sink) — "off" is a sink, not `nil`.
- `Sources/FoundationModelsRouter/Recording/Sinks.swift`:
  - `JSONLRecorder` (appends `transcript.jsonl` lines; best-effort — a write failure logs, never throws to the caller), `InMemoryRecorder` (collects events for tests), `NoneRecorder` (no-op).
  - `seq` is assigned monotonically by the recorder actor; `ts` from the clock.

## Acceptance Criteria
- [ ] `InMemoryRecorder` records appended events in `seq` order with monotonically increasing `seq` even under concurrent appends from multiple tasks.
- [ ] `JSONLRecorder` writes one JSON object per line to a file; a forced write error is swallowed (logged) and does not throw.
- [ ] `NoneRecorder.append` is a no-op (records nothing) yet shares the identical call path.
- [ ] `TranscriptEvent` round-trips through `Codable` preserving all provenance fields.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RecorderTests.swift` (Swift Testing): inMemory total ordering under concurrent appends; jsonl line-per-event in a temp dir + swallowed write error; none = empty; event Codable round-trip.
- [ ] Run `swift test --filter RecorderTests` — all pass.

## Workflow
- Use `/tdd` — write failing ordering + sink tests first.

## Review Findings (2026-06-30 13:57)

- [x] `Tests/FoundationModelsRouterTests/RecorderTests.swift:37` — Needless helper with a single call site. The appendAll function wraps a trivial for loop and is called only once (in noneRecordsNothing), making it indirection without payoff. Inline appendAll into its single call site in noneRecordsNothing. The test's intent (exercising the recorder through the protocol existential) can be preserved with a comment on the inlined loop.