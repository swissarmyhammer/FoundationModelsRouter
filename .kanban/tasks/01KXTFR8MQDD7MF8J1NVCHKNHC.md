---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky7pra44mf0fvw4zjscpz5tn
  text: |-
    Implementation complete, tests green.

    What was built:
    - Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift (new Compaction/ directory): `CompactionSegment: PersistableCustomSegment` with a nested `Content: Codable, Equatable, Sendable` struct carrying `liveWindowEntryIds: [String]`, `foldedEntryIds: [String]`, `tokensBefore: Int`, `tokensAfter: Int`, `stagesApplied: [String]`, `promptName: String`. Mirrors the OperationEventSegment precedent (fresh-id-default `init(id:content:)`, `CustomStringConvertible` description).
    - Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift: added `CustomSegmentRegistry.routerDefault` (a static computed var, fresh independent registry per access since the type is a value type) pre-seeded with `CompactionSegment` registered. Also changed `register(_:)` so re-registering the *same* concrete type under its own discriminator is now a no-op instead of a `preconditionFailure` trap — only a genuine collision (two different types claiming the same discriminator string) still traps. This is what lets a consumer build on `.routerDefault` and call `.register(CompactionSegment.self)` again (or register their own distinct types) without tripping the trap.
    - Switched the default `registry:` argument at the three named entry points from `CustomSegmentRegistry()` (empty) to `.routerDefault`: `TranscriptTree.effectiveTranscript(forSession:registry:)` (TranscriptReconstruction.swift), `RoutedModel.restoreSessionTree(root:registry:)` (SessionTreeRestoration.swift), `RoutedModel.makeLanguageModel(resuming:registry:)` (RoutedLLM.swift).
    - Tests/FoundationModelsRouterTests/CompactionSegmentTests.swift (new, 8 tests): Content Codable round-trip; typeDiscriminator default; mapper round-trip of a summary `.response` entry carrying text + CompactionSegment via `.routerDefault`; full recording-mirror round-trip (record -> transcript.jsonl -> reconstruct) calling `effectiveTranscript` with NO registry argument; `restoreSessionTree` with NO registry argument (two-router "fresh process" pattern, mirrors SessionTreeRestorationTests); `makeLanguageModel(resuming:)` with NO registry argument (uses `RecordingLanguageModel.sync(_:)` to inject a fabricated transcript directly, since driving this through a real `LanguageModelSession` can't produce a `.custom` segment via the executor's streaming surface); re-registering CompactionSegment on top of routerDefault does not trap; a consumer's own distinct custom segment alongside routerDefault does not trap.

    Verification (really-done, fresh run this session):
    - `swift build`: green, only the known pre-existing mlx-swift_Cmlx.bundle warning.
    - `swift build --build-tests`: green (removed stale default.metallib first per the known unsealed-bundle issue).
    - `swift test`: 416 tests in 45 suites passed (baseline was 408/44 — exactly +8 tests/+1 suite, zero regressions), 16 gated/skipped in 6 suites (unchanged from baseline, gated on FM_ROUTER_INTEGRATION_TESTS/GPU as expected).

    Adversarial double-check (via really-done's double-check agent) launched; will follow up with its verdict before leaving this task.

    Leaving task in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-23T14:40:57.988671+00:00
- actor: claude-code
  id: 01ky7pwcbv13ebc7d0ps0qyj36
  text: |-
    Adversarial double-check (via really-done) verdict: REVISE (one finding), everything else PASS.

    Finding: in Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift's type-level doc comment, one forward reference to the not-yet-built `CompactionPrompt` type used DocC's double-backtick symbol-link syntax (` ``CompactionPrompt/name`` `) instead of plain single-backtick code text — since `CompactionPrompt` doesn't exist in compiled sources yet (it's a future build-order step per compaction_plan.md §1.4), this would resolve to nothing and surface as an unresolved-symbol-link warning under DocC. The file was internally inconsistent: a second reference to the same not-yet-real type elsewhere in the file already correctly used plain single-backtick text.

    Fix applied: changed the double-backtick reference to plain single-backtick text (`` `CompactionPrompt`'s `name` ``), matching the file's own correct precedent.

    Everything else the double-check verified: CompactionSegment's shape/PersistableCustomSegment conformance faithfully mirrors OperationEventSegment; routerDefault and the three entry-point defaults are wired correctly (verified via source reads of effectiveTranscript/restoreSessionTree/makeLanguageModel(resuming:)); register(_:)'s idempotency change is narrowly scoped and doesn't affect TranscriptEntryMapper.entry(from:kind:)'s own separate empty-registry default (confirmed the pre-existing unregisteredCustomSegmentThrows/customSegmentRoundTripsWithRegistryAndThrowsWithoutIt tests remain valid, since they exercise their own unrelated NoteSegment type); the makeLanguageModel(resuming:) test's use of sync(_:) is not a cheat — sync and generate share the same recording chokepoint, so it genuinely exercises the real persist/reconstruct path. No TODOs/stubs/debug code found.

    Re-ran verification fresh after the fix: swift build, swift build --build-tests (removed stale default.metallib first), swift test — all green. 416 tests in 45 suites passed (baseline 408/44, so +8 tests/+1 suite exactly, zero regressions), 16 gated/skipped in 6 suites (unchanged from baseline). Only warning is the known pre-existing mlx-swift_Cmlx.bundle bundle-root warning.

    Task is done and green. Leaving in `doing` per /implement workflow for /review to pick up.
  timestamp: 2026-07-23T14:43:11.355803+00:00
depends_on:
- 01KXTFQVKKDB1PPCXZQDWS80MS
position_column: doing
position_ordinal: '80'
title: CompactionSegment + default registry registration
---
## What
Create `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift` (new `Compaction/` directory): a `PersistableCustomSegment` whose `Codable` content is the fold metadata (compaction_plan.md §1.2):
- ordered live-window entry ids (the `Transcript.Entry.id`s constituting the compacted window)
- folded entry ids (what the window replaced)
- `tokensBefore`/`tokensAfter`, `stagesApplied: [String]`, and the compaction prompt `name`

**Default registration — name the mechanism and its blast radius.** `CustomSegmentRegistry()` (`Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift`) is empty by design, and every reconstruction entry point defaults to an empty registry that *throws* on any `.custom` segment: `effectiveTranscript(forSession:registry:)` in `TranscriptReconstruction.swift`, `restoreSessionTree(root:registry:)` in `SessionTreeRestoration.swift`, and `RoutedLLM.makeLanguageModel(resuming:)` in `RoutedLLM.swift`. Without changes there, the first compacted session would make every default-argument restore throw. Either introduce `CustomSegmentRegistry.routerDefault` (pre-seeded with `CompactionSegment`) and switch the defaulted `registry:` parameters at all three entry points to it, or pre-register in `init()` — and design around the duplicate-discriminator trap in `register` so a consumer re-registering `CompactionSegment` (or adding their own segments) doesn't trap. No schema work otherwise: the summary entry persists via the existing `SegmentPayload.custom` path in `TranscriptEntryPayload.swift`.

Honor the spike task's findings on entry-id stability (dws80ms).

## Acceptance Criteria
- [x] `CompactionSegment` encodes/decodes all fold metadata fields losslessly
- [x] A synthesized summary entry carrying a text segment + `CompactionSegment` round-trips through the recording mirror (record → `transcript.jsonl` payload → reconstruct) with metadata intact
- [x] Restoring a transcript containing a `CompactionSegment` through `effectiveTranscript`, `restoreSessionTree`, and `makeLanguageModel(resuming:)` with all-default arguments succeeds — zero consumer configuration
- [x] A consumer registering their own custom segments (or re-registering `CompactionSegment`) alongside the default does not trap

## Tests
- [x] `Tests/FoundationModelsRouterTests/CompactionSegmentTests.swift` — Codable round-trip, mirror round-trip via `TranscriptEntryMapper`/reconstruction, all-default-arguments restore of a segment-bearing transcript, duplicate/consumer registration; `swift test --filter CompactionSegmentTests` passes
- [x] Existing reconstruction/restore test suites still pass unchanged (`swift test`)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction