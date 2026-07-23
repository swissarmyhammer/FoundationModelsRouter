---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky805epk2bcytvwt6heh2me9
  text: 'Research done. Confirmed Transcript.Entry.id is a public String (Identifiable) via the installed macOS 27 SDK''s FoundationModels.swiftinterface. Wrote Tests/FoundationModelsRouterTests/NoteCompactionTests.swift first (TDD): 6 tests covering exact-append semantics, pre-fold-untouched, baseline reset (follow-up turn), idempotent repeat, and nested (second, later) compaction. Confirmed RED: swift build --build-tests fails with "value of type ''RecordingLanguageModel'' has no member ''noteCompaction''" — the expected failure. Now implementing: TranscriptDiffer.diffByEntryId(...) (set-based diff by Transcript.Entry.id, sharing a factored-out `partial(for:...)` helper with the existing positional diff), plus RecordingLanguageModelState.noteCompaction(_:) / RecordingLanguageModel.noteCompaction(_:) which append only never-before-seen entries and unconditionally reset lastSeen (no shrink-guard, since a fold is expected to be shorter).'
  timestamp: 2026-07-23T17:25:25.843875+00:00
- actor: claude-code
  id: 01ky80kad4644p891z4jrgxvrw
  text: |-
    Implementation landed, GREEN. Changes:
    - Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift: added `diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)` (set-based diff by Transcript.Entry.id), factored a shared `partial(for:...)` helper reused by both the existing positional `diff` and the new `diffByEntryId`.
    - Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift: added public `RecordingLanguageModel.noteCompaction(_:)`, actor method `RecordingLanguageModelState.noteCompaction(_:)` (sidecar + gate + session-meta, same chokepoint shape as sync/generate), and private `diffAndRecordCompaction(compacted:)` which appends only never-before-seen entries and unconditionally resets `lastSeen` (deliberately no shrink-guard — a fold is expected to be shorter, unlike diffAndRecord's anomaly-guard).
    - Tests/FoundationModelsRouterTests/NoteCompactionTests.swift: 5 new tests (TDD — confirmed RED via real compile failure first) covering exact-append semantics + CompactionSegment round-trip, pre-fold-untouched, baseline reset via a real follow-up turn over the same handle, idempotent repeat, and a second/nested later compaction.

    Verification (fresh, this session): `swift build` clean (only the known pre-existing mlx-swift_Cmlx.bundle warning), `swift build --build-tests` clean, `swift test`: 434 tests in 47 suites passed, 16 gated/skipped in 6 suites — exactly baseline (429/46) + 5 new tests in 1 new suite. Targeted reruns of TranscriptDifferTests/RecordingLanguageModelTests/RecordingHandleResumeTests/CompactionSegmentTests/CompactionSpikeTests/TranscriptEntryMapperTests/SessionSidecarTests/TokenBudgetTests/TokenUsageMeteringTests also all green (96/96).

    Dispatched the really-done adversarial double-check agent on this diff; awaiting its verdict before final handoff. Leaving task in doing per /implement contract (not moving to review myself).
  timestamp: 2026-07-23T17:33:00.196130+00:00
- actor: claude-code
  id: 01ky80t3jrz98yb979g51k8fn8
  text: |-
    really-done adversarial double-check: PASS, no findings. Verified gate handling matches sync/enterGateAndDiff's shape exactly (single acquire/release, no throwing work in between), confirmed the diff/diffByEntryId `partial(for:...)` refactor is a byte-identical extraction (no behavior change to the existing positional differ), confirmed the unconditional lastSeen reset is intentional (a fold is expected to shrink) and validated end-to-end via the nested-compaction test, and confirmed the new tests are discriminating (would fail under a positional-diff implementation) rather than passing by construction. Independently reran swift test: 434/47 passed, 16 gated/6 skipped — matches baseline.

    All acceptance criteria and Tests checkboxes checked off. Task left in `doing`, ready for /review.
  timestamp: 2026-07-23T17:36:42.584948+00:00
- actor: claude-code
  id: 01ky82mh7t2y81z6d5zn52n9xg
  text: |-
    Resolved all 9 review findings. Pulled task back into `doing` per /implement.

    **Argument-label findings (1, 3, 4, 5, 6) — investigated, not blindly applied:**

    The review engine's "swift" validator ("fluent-usage" rule) reads "Omit the first argument label only for value-preserving conversions... Otherwise, label it" — but that same rule also lists `append(x)`/`appending(x)` as an approved unlabeled DO example a few lines later, and this codebase has 30+ pre-existing unlabeled-first-arg methods for verb+direct-object actions (`append(_:)` ×5, `save(_:)` ×2, `cancel(_:)`, `register(_:)`, `post(_:)`, `replace(_:)`, `session(_:)`, etc. — confirmed via `grep -rn 'func \w+(_ \w+:' Sources/`).

    - **Finding 1** (`RecordingLanguageModel.noteCompaction(_:)`), **3** (`RecordingLanguageModelState.sync(_:)`), **4** (`RecordingLanguageModelState.noteCompaction(_:)`), **5** (`enterGateAndDiff(_:)`): all four are effectful verb-methods whose single argument is the direct object of the verb, exactly matching this file's own `sync(_:)` (already established, unchanged code) and the codebase's pervasive `append(_:)`/`save(_:)`/`cancel(_:)` convention. Left unlabeled — adding labels here would fight the established, Apple-guideline-conformant convention rather than match it, and would make these four the odd ones out versus every sibling method. No code change.
    - **Finding 6** (`makePassthroughGeneric(_:)`): initially applied the same reasoning and left it unlabeled — wrong. An adversarial double-check review caught this: `makePassthroughGeneric` is a `make`-prefixed *factory*, not an action-on-direct-object method, and every other `make*` factory in this codebase (`makeSession`, `makeRoutedLLM`, `makeDurableRecording`, `makeRecordingLanguageModelHandle`, `makeGuidedSession`, `makeLadderSuccess`, etc. — ~14 total) labels its parameters. Its own sibling one line above, `makePassthrough(wrapped:)`, already labels this exact value `wrapped:`. Fixed: `makePassthroughGeneric<Wrapped: LanguageModel>(_ wrapped: Wrapped)` → `makePassthroughGeneric<Wrapped: LanguageModel>(wrapped: Wrapped)`, call site updated to `makePassthroughGeneric(wrapped: wrapped)`, doc comment added explaining why this one is labeled unlike its unlabeled siblings.

    **Duplication findings (2, 7) — root-cause extractions:**

    - Finding 2 (`RecordingLanguageModel.swift`): extracted `private func enterGateAndRecordMeta(_ transcript: Transcript) async` (writeSidecarIfNeeded → serialGate.wait() → recordSessionMetaIfNeeded()) shared by `noteCompaction(_:)` and `enterGateAndDiff(_:usage:)`, which previously repeated the identical 3-line prep sequence. Gate-release responsibility is unchanged — still the caller's job in both cases.
    - Finding 7 (`TranscriptDiffer.swift`): extracted `private static func mapPartials(_ entries: some Sequence<Transcript.Entry>, routerId:sessionId:parentId:slot:model:) -> [TranscriptEvent.Partial]`, shared by `diff` (over an `ArraySlice`) and `diffByEntryId` (over a filtered `[Transcript.Entry]`), on top of the pre-existing `partial(for:...)` per-entry helper. No leftover verbatim `.map { entry in partial(...) }` duplication remains.

    **Verification:** `swift build`, `swift build --build-tests`, `swift test` all green — 434 tests in 47 suites passed, 16 gated/6 suites skipped, matching the prior verified baseline exactly. Ran the adversarial `double-check` agent twice: first pass returned REVISE on finding 6 (caught above, fixed); second pass after the fix returned PASS with no further findings.

    Task left in `doing`, ready for `/review`.
  timestamp: 2026-07-23T18:08:37.114123+00:00
depends_on:
- 01KXTFR8MQDD7MF8J1NVCHKNHC
position_column: done
position_ordinal: cd80
title: 'noteCompaction on RecordingLanguageModel: append-only fold recording'
---
## What
Add `public func noteCompaction(_ compacted: Transcript)` to `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` (compaction_plan.md §1.5 bare-session path, §3):

- The handle's differ is count-based append-only. `noteCompaction` appends the *never-before-recorded* entries of the compacted transcript to that session's `transcript.jsonl` — unseen-ness is a set lookup by `Transcript.Entry.id` (payloads already carry `entryId` via `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`). This is how the synthesized summary entry (with its `CompactionSegment`) reaches disk.
- Resets the differ baseline (`Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift` state held by the handle) so post-fold turns record as ordinary appends: retained tail entries keep their entry ids, so they are recognized as already recorded — no divergence, no double-recording.
- Recording stays append-only: nothing before the fold is touched (requirement 2); session id unchanged on every event (requirement 4).
- Document the caller contract: after `noteCompaction`, rebuild `LanguageModelSession(model: same handle, tools:, transcript: compacted)`.

## Acceptance Criteria
- [x] `noteCompaction` appends exactly the unseen entries (the summary entry; nothing retained is re-written) and resets the baseline
- [x] Subsequent turns after the fold record as normal appends with no duplicated events
- [x] All pre-fold events remain intact in `transcript.jsonl`; session id identical on every event

## Tests
- [x] Extend `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift` or add `NoteCompactionTests.swift`: compact a fixture transcript, call `noteCompaction`, assert exact-append semantics, baseline reset (drive a follow-up turn via the existing handle test harness), pre-fold events untouched, repeated compactions
- [x] `swift test --filter 'RecordingLanguageModel|NoteCompaction'` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction

## Review Findings (2026-07-23 12:39)

- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:118` — The first argument label is omitted from `noteCompaction(_:)`, but this is not a value-preserving conversion—it's a side-effectful operation. The rule requires first-argument labels except for value-preserving conversions. Change the signature to `public func noteCompaction(compacted: Transcript) async {` to label the first parameter. Update call sites from `await handle.noteCompaction(compacted)` to `await handle.noteCompaction(compacted: compacted)`.
- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:284` — The gate-acquisition and meta-recording prep sequence (writeSidecar, wait, recordMeta) is duplicated in both `noteCompaction` and `enterGateAndDiff`, with identical logic that could drift if one is modified without the other. Extract the shared prep sequence into a private helper method, e.g. `private func enterGateAndRecordMeta(_ transcript: Transcript) async`, that both `noteCompaction` and `enterGateAndDiff` call before proceeding to their respective diff operations.
- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:312` — The gate-acquisition and meta-recording prep sequence (writeSidecar, wait, recordMeta) is duplicated in both `enterGateAndDiff` and `noteCompaction`, with identical logic that could drift if one is modified without the other. Extract the shared prep sequence into a private helper method, e.g. `private func enterGateAndRecordMeta(_ transcript: Transcript) async`, that both `enterGateAndDiff` and `noteCompaction` call before proceeding to their respective diff operations.
- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:340` — The first argument label is omitted from `sync(_:)` in RecordingLanguageModelState, but this is not a value-preserving conversion. The rule requires first-argument labels except for value-preserving conversions. Change the signature to `func sync(transcript: Transcript, usage: ...)` to label the first parameter for consistency with the fluent-usage rule.
- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:350` — The first argument label is omitted from `noteCompaction(_:)` in RecordingLanguageModelState, but this is not a value-preserving conversion. The rule requires first-argument labels except for value-preserving conversions. Change the signature to `func noteCompaction(compacted: Transcript) async {` to label the first parameter for consistency with the fluent-usage rule.
- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:375` — The first argument label is omitted from `enterGateAndDiff(_:)`, but this is not a value-preserving conversion—it's a side-effectful operation that performs gating and diffing. The rule requires first-argument labels except for value-preserving conversions. Change the signature to `private func enterGateAndDiff(transcript: Transcript, usage: ...) async` and update call sites from `enterGateAndDiff(request.transcript)` to `enterGateAndDiff(transcript: request.transcript)` (line 362) and from `enterGateAndDiff(transcript, usage: usage)` to `enterGateAndDiff(transcript: transcript, usage: usage)` (line 369).
- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:500` — The first argument label is omitted from `makePassthroughGeneric(_:)`, but this is not a value-preserving conversion—it wraps a model in a closure. The rule requires first-argument labels except for value-preserving conversions. Change the signature to `private static func makePassthroughGeneric<Wrapped: LanguageModel>(wrapped: Wrapped) throws` and update the call site from `makePassthroughGeneric(wrapped)` to `makePassthroughGeneric(wrapped: wrapped)` (line 488).
- [x] `Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift:46` — The `.map { entry in partial(...) }` pattern is duplicated verbatim in both `diff` and `diffByEntryId`, with identical parameters that could drift if one is modified without the other. Extract the entry-to-partial mapping into a private helper function, e.g. `private static func mapPartials(_ entries: [Transcript.Entry], routerId: ULID, sessionId: ULID, parentId: ULID?, slot: ModelSlot, model: ModelRef) -> [TranscriptEvent.Partial]`, that both `diff` and `diffByEntryId` call with their filtered entries.
- [x] `Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift:79` — The `.map { entry in partial(...) }` pattern is duplicated verbatim in both `diffByEntryId` and `diff`, with identical parameters that could drift if one is modified without the other. Extract the entry-to-partial mapping into a private helper function, e.g. `private static func mapPartials(_ entries: [Transcript.Entry], routerId: ULID, sessionId: ULID, parentId: ULID?, slot: ModelSlot, model: ModelRef) -> [TranscriptEvent.Partial]`, that both `diff` and `diffByEntryId` call with their filtered entries.
