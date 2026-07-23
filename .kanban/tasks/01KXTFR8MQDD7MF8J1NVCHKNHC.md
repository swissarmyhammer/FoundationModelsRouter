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
- actor: claude-code
  id: 01ky7qqcjswmh8gdv3aw7rvyhv
  text: |-
    Addressed all 6 review findings (all documentation-comment style):

    1-2. Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift — added doc comments to public properties `id` and `content` (previously undocumented), using the exact wording suggested in the review findings.
    3. Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift — inserted a blank `///` line in the `notARootSession` case's doc comment, separating the summary sentence ("...its ``SessionNode/parentId`` is non-nil).") from the elaboration ("Restoration is a whole-tree operation...").
    4-5. Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift — same fix applied to two separate doc comments: the `legacyEventMissingPayload` case (separating "...``TranscriptEvent/entry`` field existed." from "Reconstruction needs the structural payload...") and the `contentRemoved` case (separating "...``RecordingLevel/metadataOnly``)." from "The shape survives on disk..."). Checked this file (and the other touched files) for any other doc comments with the same missing-separator pattern before stopping — the file's other multi-sentence doc comments (e.g. the type-level doc comment, the `unregisteredCustomSegmentType`/`entryReconstructionFailed` cases, `effectiveTranscript`'s method doc, `isFailedTurnBodylessClose`'s doc) already correctly use the blank-`///`-separator convention, so no further fixes were needed there.
    6. Sources/FoundationModelsRouter/RoutedLLM.swift — same fix applied to `GenerationError.notWiredForLiveInference`'s doc comment, separating "...gated integration suite (milestone 7)." from "The unit suite exercises...".

    The blank-`///`-separator convention (summary sentence ending in period, blank `///` line, then elaboration) was confirmed against this codebase's own existing usage — e.g. CompactionSegment.swift's own type-level doc comment and SessionTreeRestoration.swift's `restoreSessionTree` method doc comment already follow this pattern, so the fixes match established style exactly rather than inventing a new convention.

    No other changes made — scope held strictly to these 6 findings, no unrelated refactors.

    Verification (really-done, fresh run this session):
    - `swift build`: green, only the known pre-existing mlx-swift_Cmlx.bundle warning.
    - `swift build --build-tests`: green (removed stale default.metallib first per the known unsealed-bundle issue).
    - `swift test`: 416 tests in 45 suites passed, 16 gated/skipped in 6 suites — exactly matches the prior verified baseline, zero regressions.

    Adversarial double-check (via really-done's double-check agent) launched to verify the fixes against the codebase's doc-comment conventions and confirm no scope creep; will follow up with its verdict.

    All 6 review-finding checkboxes marked done; task description/tags verified intact after update. Leaving task in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-23T14:57:56.313507+00:00
- actor: claude-code
  id: 01ky7qtrb2n9xp2npdzfjgxb2v
  text: |-
    Adversarial double-check verdict: PASS.

    Confirmed via independent `git diff` review: the diff scope is exactly the 6 described doc-comment changes across the 4 named files, all comment-only additions (no non-comment code lines touched). Confirmed the blank-`///`-separator convention is genuinely established codebase-wide (445 occurrences of the pattern found via grep), not invented for this fix. Confirmed the new `id`/`content` property docs are additive and don't contradict CompactionSegment's type-level doc comment. Confirmed no scope creep (only the 4 source files + kanban bookkeeping changed; `.reviewignore` is auto-generated tooling output, not an authored change). Independently re-ran `swift build`, `swift build --build-tests`, and `swift test` fresh — reproduced the same 416 tests/45 suites passed, 16/6 gated, zero regressions, only the pre-existing mlx-swift_Cmlx.bundle warning.

    Task is done and green. All 6 review findings fixed and checked off. Leaving in `doing` per /implement workflow for /review to pick up.
  timestamp: 2026-07-23T14:59:46.658527+00:00
- actor: claude-code
  id: 01ky7rhx7tsdsp6t9y207fzrhs
  text: |-
    Addressed the new review finding (2026-07-23 10:02): duplicated owning-profile precondition in `restoreSessionTree(root:registry:)`.

    Fix: in Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, replaced the inline
    ```swift
    guard let owningProfile = owningProfileBox.current else {
        preconditionFailure(
            "restoreSessionTree requires a live owning LanguageModelProfile; the handle holds it weakly and the profile was released before this call"
        )
    }
    ```
    with a call to the shared helper already defined in the same `extension RoutedModel where Container == any LoadedLLMContainer` (in RoutedLLM.swift):
    ```swift
    let owningProfile = requireOwningProfile(apiName: "restoreSessionTree")
    ```
    `requireOwningProfile(apiName:)` produces the byte-identical trap message (`"\(apiName) \(missingOwningProfileMessageSuffix)"`), so this is a pure duplicate-removal with no behavior change — same precondition, same wording, same laziness (traps only when `owningProfileBox.current` is nil). Confirmed via `git diff -- Sources/` that this is the only change (single 4-removed/1-added hunk, no other files touched).

    Checked the box for this finding; all 7 review-finding checkboxes across both review rounds are now `[x]` (progress 1.0).

    Verification (really-done, fresh this session):
    - `swift build`: green, only the known pre-existing mlx-swift_Cmlx.bundle warning.
    - `swift build --build-tests`: green (removed stale default.metallib first per the known unsealed-bundle issue).
    - `swift test`: 416 tests in 45 suites passed, 16 gated/skipped in 6 suites — exactly matches the prior verified baseline, zero regressions, zero failures/warnings beyond the known pre-existing one.

    Adversarial double-check (via really-done's double-check agent): PASS. Independently confirmed the diff is minimal and scoped, the helper's trap message/semantics are byte-identical to the removed inline code, nothing else references the removed inline structure, and independently re-ran swift build / swift build --build-tests / swift test with the same 416/45 + 16/6 gated result.

    Also caught and immediately fixed a kanban `update task` description-corruption incident while checking this finding's box: the update flattened real newlines to literal `\n` and dropped the `compaction` tag (the known corruption pattern). Re-verified via `get task` and corrected both in a follow-up `update task` call.

    Leaving task in `doing` per /implement workflow — not moving to review myself.
  timestamp: 2026-07-23T15:12:25.338041+00:00
depends_on:
- 01KXTFQVKKDB1PPCXZQDWS80MS
position_column: done
position_ordinal: ca80
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

## Review Findings (2026-07-23 09:45)

- [x] `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:179` — Public property `id` lacks a documentation comment. Swift requires documentation on all public APIs, and this property is public but undocumented despite other properties in the codebase (including those in the nested Content struct) having individual doc comments. Add a doc comment explaining what `id` represents, e.g.: /// A unique identifier for this segment — a fresh UUID for newly synthesized folds, or the persisted id when rebuilding from disk.
- [x] `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:180` — Public property `content` lacks a documentation comment. Swift requires documentation on all public APIs, and this property is public but undocumented despite the struct-level docs and other properties having individual comments. Add a doc comment explaining what `content` holds, e.g.: /// The fold metadata this segment carries: live-window and folded entry ids, token counts, pipeline stages, and prompt name.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:20` — Doc comment has multiple sentences without a blank `///` line separator. First sentence ends with 'is non-nil).' (line 17) but second sentence 'Restoration is a whole-tree operation...' follows immediately without separation. Add a blank `///` line after '(its ``SessionNode/parentId`` is non-nil).' to separate the first-sentence summary from the elaboration.
- [x] `Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift:20` — Doc comment has multiple sentences without a blank `///` line separator between the first-sentence summary and elaboration. The rule requires: first sentence ending in period, blank `///` line, then elaboration. Add a blank `///` line after the first sentence: separate 'written before the ``TranscriptEvent/entry`` field existed.' from 'Reconstruction needs the structural payload...'.
- [x] `Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift:27` — Doc comment has multiple sentences without a blank `///` line separator between summary and elaboration. First sentence ends with `RecordingLevel/metadataOnly`).' but second sentence 'The shape survives on disk...' follows immediately. Insert blank `///` line after '``RecordingLevel/metadataOnly``).', separating the first summary sentence from the elaboration that follows.
- [x] `Sources/FoundationModelsRouter/RoutedLLM.swift:11` — Doc comment has multiple sentences without a blank `///` line separator. First sentence ends with '(milestone 7).' but second sentence 'The unit suite...' follows immediately. Insert a blank `///` line after 'gated integration suite (milestone 7).' to separate the first-sentence summary from the elaboration about the unit suite.

## Review Findings (2026-07-23 10:02)

- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:178` — The owning profile precondition check is duplicated inline when an identical helper function already exists in the same extension. Replace the inline guard block with `let owningProfile = requireOwningProfile(apiName: "restoreSessionTree")` to reuse the shared helper that already handles this precondition for other functions in the same extension.
