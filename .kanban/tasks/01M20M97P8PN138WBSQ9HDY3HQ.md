---
comments:
- actor: claude-code
  id: 01m20n5bt8nh9javz778wmmpq5
  text: |-
    Picked up. Research and RED evidence.

    What differs between two readings, byte for byte: the order of the JSON object keys in `ToolDefinitionPayload.parametersSchemaJSON` (and `TranscriptEntryPayload.responseFormatSchemaJSON`). `TranscriptEntryMapper.jsonString(for:context:)` encoded a `GenerationSchema` with a plain `JSONEncoder()`. `GenerationSchema.encode(to:)` writes its objects from dictionaries, and Swift seeds a dictionary's iteration order with the address of its storage. So one unchanged schema encodes to bytes with a different key order on each reading whose temporary storage lands at a new address. Every key set, the values and the `x-order` array are equal; only the key order moves.

    Evidence (scratch experiment, then deleted):
    - 50 encodings of one `GenerationSchema` in a tight loop: 1 distinct byte string. The tight loop reuses one address, so this hides the defect.
    - 200 encodings of the same schema instance with a retained allocation of a new size between encodings: 38 distinct byte strings.
    - 100 readings of `LanguageModelSession(tools:instructions:).transcript`, entry 0 mapped through `TranscriptEntryMapper.event(from:)`: 98 distinct `parametersSchemaJSON` strings. The top-level key order and the `properties` key order both move.
    - The same with `.sortedKeys`: 1 distinct byte string.

    RED (before the fix), four new tests fail for that reason:
    - `TranscriptEntryMapperTests/toolDefinitionSetEncodesToIdenticalBytesAcrossReadings`: 127 distinct encodings of 128 readings.
    - `TranscriptEntryMapperTests/responseFormatSchemaEncodesToIdenticalBytesAcrossReadings`: 124 distinct of 128.
    - `TranscriptDifferTests/unchangedEntryReadAgainComparesEqual`: `divergence(from:in:)` returns `.rewrittenInPlace` for one unchanged instructions entry.
    - `TranscriptFidelityTests/unchangedToolSurfaceAcrossTurnsRecordsNoDivergence`: the handle records exactly the field marker, "backend transcript rewrote the recorded entry at index 0 in place: entry id instr-1 is unchanged but its content differs from what was recorded", and the first turn's prompt and response are lost (recorded kinds: session, instructions, divergence, prompt, response).

    Which of the three answers is true: answer 1, an unstable serialization order. Answer 2 is not the cause: the comparison compares the mapped payload, which is stable once the encoder is. Answer 3 is not the cause: the SDK does not rewrite entry 0; the entry id, the text and the tool set are equal on every reading.

    Not the cause, checked and left alone: `GuidedShapes.derivedSchema(for:)` also uses a plain `JSONEncoder()`, but its output feeds the grammar engine and the recorded `grammar` string, and nothing compares it. `Sinks.swift`'s line encoder writes events to disk and feeds no comparison. `GeneratedContent.jsonString` (tool-call arguments, structured segments) is the SDK's own order-preserving rendering.

    Fix: `TranscriptEntryMapper.jsonString(for:context:)` now encodes with `.sortedKeys`. The `x-order` array in the schema carries the property order, so sorted `properties` keys lose nothing on decode.

    Test support added in `Tests/FoundationModelsRouterTestSupport`: `HeapChurn` (repeats a read with a retained allocation of a new size between reads, so an address-dependent encoding shows itself) and `FixedToolSurface` (a four-tool surface with multi-property schemas, like the consuming agent's).
  timestamp: 2026-09-08T14:01:14.824481+00:00
- actor: claude-code
  id: 01m20nb3gvnd5ejkkvnz3s870t
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift (schema encoder now `.sortedKeys`), Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift (docs), Tests/FoundationModelsRouterTestSupport/HeapChurn.swift (new), Tests/FoundationModelsRouterTestSupport/FixedToolSurface.swift (new), Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift (+2 tests), Tests/FoundationModelsRouterTests/TranscriptDifferTests.swift (+1 test), Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift (+1 test). RED: the 4 new tests failed before the fix (`swift test --filter` on the four `Target.Suite/test` ids: 4 tests in 3 suites, 5 issues). GREEN: the same command, 4 tests in 3 suites passed. Full run: `swift test` — 1238 tests in 134 suites passed with 2 known issues (pre-existing `withKnownIssue` marks in the BoundedWait suite), plus 83 tests in 10 suites in the Evals target passed. The only warning is the pre-existing build-system notice "missing creator for mutated node" for the mlx bundle.
    - discovery: the first full run failed one unrelated test, `ToolInvocationLivenessTests/backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles`, on a wall-clock `BoundedWait` under load. It passes alone and on the next full run. Filed as ^z5pbt5e.
    - next: /review. The task stays in `doing`. Not committed, not pushed, no worktree.
  timestamp: 2026-09-08T14:04:22.939373+00:00
- actor: claude-code
  id: 01m20nvxkcgznc3hz90gvabd9g
  text: |-
    ### test — green
    - evidence: `swift package clean` then `swift build --build-tests` (clean build of the changed files, confirmed no cache hit) — 0 warnings outside the pre-existing mlx-swift C++ dependency warnings (4x `-Wc++17-extensions` in `.build/checkouts/mlx-swift`, plus the pre-existing "missing creator for mutated node" bundle notice); no warnings in any file this task touched. `swift test` — FoundationModelsRouterTests: 1238 tests in 134 suites passed, 0 failed, 0 skipped, with 2 known issues (pre-existing `withKnownIssue` marks in `RealModelHarness.swift` and `BoundedWait.swift`, unrelated to this change). FoundationModelsRouterEvals: 83 tests in 10 suites passed, 0 failed, 0 skipped. Targeted confirmation with a `<Target>.<Suite>/<test>` filter (non-zero count, per the filter rule) on the four new tests — `swift test --filter 'FoundationModelsRouterTests.TranscriptEntryMapperTests/toolDefinitionSetEncodesToIdenticalBytesAcrossReadings|FoundationModelsRouterTests.TranscriptEntryMapperTests/responseFormatSchemaEncodesToIdenticalBytesAcrossReadings|FoundationModelsRouterTests.TranscriptDifferTests/unchangedEntryReadAgainComparesEqual|FoundationModelsRouterTests.TranscriptFidelityTests/unchangedToolSurfaceAcrossTurnsRecordsNoDivergence'` — 4 tests in 3 suites passed.
    - flake check: `ToolInvocationLivenessTests/backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` (filed as ^z5pbt5e by the implementer) passed cleanly in this run — no recurrence observed.
    - next: /review. No commit, no push, no worktree used.
  timestamp: 2026-09-08T14:13:33.932694+00:00
- actor: claude-code
  id: 01m20nxvs17m2ewencshx6nyeq
  text: |-
    ### commit — changed
    - evidence: a3612d3 fix(recording): encode schema JSON with sorted keys (^9hdy3hq); 13 files changed
    - next: none
  timestamp: 2026-09-08T14:14:37.601988+00:00
- actor: claude-code
  id: 01m20p3vc9ztjdptaamhkztv5w
  text: |-
    ### review — findings
    - evidence: 1 finding on `review sha HEAD~1..HEAD` (commit a3612d3) — `Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift:708` `code-hygiene/idioms-swift` preferContains
    - next: correct the finding in the `## Review Findings (2026-09-08 09:15)` section, check its box, then run `/review 01M20M97P8PN138WBSQ9HDY3HQ HEAD~1..HEAD` again
  timestamp: 2026-09-08T14:17:53.801571+00:00
- actor: claude-code
  id: 01m20p4eg4t2n4v96kwmq9e47t
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files (TranscriptEntryMapper.swift, TranscriptEntryPayload.swift, HeapChurn.swift, FixedToolSurface.swift, 3 test files)
    - test: green — swift test, 1238 passed + 83 passed in Evals, 0 failed, 0 skipped
    - commit: a3612d3
    - review: findings — Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift:708 preferContains
  timestamp: 2026-09-08T14:18:13.380768+00:00
- actor: claude-code
  id: 01m20p9pbpjamhs9pc7490v75g
  text: |-
    Picked up again from `review` to correct the one open finding: `Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift:708` `code-hygiene/idioms-swift` — preferContains: Prefer contains over filter(_:).isEmpty, first(where:) != nil, and range(of:) != nil.

    Change: in `unchangedToolSurfaceAcrossTurnsRecordsNoDivergence`, `#expect(events.filter { $0.kind == .divergence }.isEmpty)` is now `#expect(!events.contains { $0.kind == .divergence })`. That is the shape the swiftformat `preferContains` rule writes.

    Whole-file check: a grep of the full file for `filter(_:).isEmpty`, `first(where:) != nil`, `first { } != nil`, `range(of:) != nil` and `firstIndex != nil` finds no other use of the cause. The other `.filter` and `.first` uses in the file (lines 250, 254, 299, 307, 386, 388, 556, 609, 656, 745, 787) keep a value or a count; they are not the cause named by the finding, and all of them existed before this task, so they stay as they are.

    The other files this task added or changed — TranscriptEntryMapperTests.swift, TranscriptDifferTests.swift, HeapChurn.swift, FixedToolSurface.swift, TranscriptEntryMapper.swift, TranscriptEntryPayload.swift — hold none of the cause forms.

    Two files outside this task hold the same pattern (`Tests/FoundationModelsRouterTests/PromptQueueTests.swift:342` `filter { }.isEmpty`, `Tests/FoundationModelsRouterTestSupport/RecordingRedactionScan.swift:139` `range(of:) != nil`). They are outside the scope of this task and were not changed.

    Did not run `swiftformat`, per the rule for this repo. No commit, no push, no worktree.
  timestamp: 2026-09-08T14:21:05.270226+00:00
- actor: claude-code
  id: 01m20paced0964nmyrj6v1yxaf
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift (`filter { }.isEmpty` replaced by `!contains { }` in `unchangedToolSurfaceAcrossTurnsRecordsNoDivergence`). The finding at `Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift:708` is checked in the `## Review Findings (2026-09-08 09:15)` section. Test: `swift test --filter 'FoundationModelsRouterTests.TranscriptFidelityTests/'` — build rebuilt the test target (Build complete, 8.17 sec), 12 tests in 1 suite passed, 0 failed, 0 skipped. The only build warning is the pre-existing "missing creator for mutated node" notice for the mlx bundle.
    - next: /review 01M20M97P8PN138WBSQ9HDY3HQ. The task stays in `doing`. Not committed, not pushed, no worktree.
  timestamp: 2026-09-08T14:21:27.885562+00:00
- actor: claude-code
  id: 01m20peskdrzxqd37wg02qey68
  text: |-
    ### test — green

    - evidence: `swift build --build-tests` recompiled the changed file (FoundationModelsRouterTests-product rebuilt) with zero errors and one pre-existing, unrelated warning (`missing creator for mutated node` from the mlx-swift dependency's Cmlx bundle build step, not from any Swift source in this change). `swift test` full run: FoundationModelsRouterTests target — 1238 tests in 134 suites passed, 0 failed, 0 skipped (2 known issues from intentional `withKnownIssue` blocks, not failures). FoundationModelsRouterEvals target — 83 tests in 10 suites passed, 0 failed, 0 skipped.
    - The only uncommitted source change, `TranscriptFidelityTests.swift:708`, replaced `events.filter { $0.kind == .divergence }.isEmpty` with `!events.contains { $0.kind == .divergence }` per review finding `preferContains`. Checked the whole file for the same pattern (`.filter{}.isEmpty`, `first(where:) != nil`, `range(of:) != nil`) — no other instances remain.
    - The test containing the changed line, "two turns over one unchanged tool surface record no divergence marker", passed.
    - `mcp__sah__diagnostics check working` reports 0 errors, 0 warnings.
    - The known flaky liveness test ^z5pbt5e was not triggered/timed out in this run.
    - next: none — build is clean.
  timestamp: 2026-09-08T14:23:52.429913+00:00
- actor: claude-code
  id: 01m20pg6ra9w7th4c9e81sm2bd
  text: |-
    ### commit — changed
    - evidence: b4930a7, 3 files changed (2 kanban files, 1 test file)
    - next: none. This is a green checkpoint commit for ^9hdy3hq. It uses contains in place of filter(_:).isEmpty in TranscriptFidelityTests.swift, per the preferContains rule.
  timestamp: 2026-09-08T14:24:38.666083+00:00
- actor: claude-code
  id: 01m20pmpt9jeb41frtpj5rprrs
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~2..HEAD` — 0 findings. The given range `HEAD~1..HEAD` is commit 807b179, which changes only `.kanban/` files. The named commit b4930a7 is `HEAD~2..HEAD~1`. The review used `HEAD~2..HEAD` so that it contains both. 1 file reviewed (`Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift`), 2 `.kanban/` files excluded by `.reviewignore`. The one prior finding (2026-09-08 09:15, TranscriptFidelityTests.swift:708) is checked.
    - next: none. The task moved from `doing` to `review` to `done`.
  timestamp: 2026-09-08T14:27:06.185908+00:00
- actor: claude-code
  id: 01m20pnewxbphyf8tsb34mmhn5
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift, preferContains finding)
    - test: green — swift test, 1238 passed + 83 passed in Evals, 0 failed, 0 skipped
    - commit: b4930a7 (plus 807b179, kanban files only)
    - review: clean — 0 findings on HEAD~2..HEAD; task moved to done
  timestamp: 2026-09-08T14:27:30.845841+00:00
position_column: done
position_ordinal: ffffcb80
title: An append-only entry compares unequal on re-read, so the baseline check raises a false divergence
---
### What

The baseline check reports that an append-only entry changed. It cannot
have changed. Find why the check says it did, and stop it.

The recorded marker, 29 times over 24 transcripts of a 2026-09-07
evaluation run in `FoundationModelsACPAgent`:

```
kind:  divergence
slot:  standard
text:  backend transcript rewrote the recorded entry at index 0 in
       place: entry id 5193D004-5EF6-4230-8250-7D8951B8B401 is
       unchanged but its content differs from what was recorded
```

Index 0 is the `instructions` entry.

### Why this is a check defect and not a data defect

**A transcript appends. An entry that is already written does not
change.** So entry 0 did not change. The check compared two readings of
one unchanged entry and called them different, which means the reading
is not stable.

The measured facts agree. The `instructions` entry holds
`toolDefinitions`, and over the recorded runs it holds exactly the
declared surface of that agent, unchanged from turn to turn:

```
entry keys: entryId, toolDefinitions, contentRemoved, segments
  searchTools: yes   runCode: yes   wait: yes   skills: yes
```

The consuming agent mounts a FIXED surface of four tools and discovers
capabilities inside its `runCode` snippets, so the declared tool set is
constant by design. `contentRemoved` is `true` zero times, so no
redaction changed anything either.

The consuming agent also holds one `LanguageModelSession` for the life
of the session — `liveSession` is a `let`, created once — so the session
is not rebuilt between turns.

### What to do

Find what differs between two readings of one entry. Test these in
order, and stop at the one the evidence supports:

1. **An unstable serialization order.** If `toolDefinitions`, or a
   schema inside one, serializes from a set or a dictionary, the byte
   order moves between readings while the value is equal. This fits the
   marker exactly: same id, same meaning, different content.
   `Recording/SessionSidecar.swift:231` sets
   `[.prettyPrinted, .sortedKeys]` for the WRITE path. Read whether the
   comparison path sets the same, and make every encoder that feeds a
   comparison deterministic.
2. **The comparison reads volatile content.** If the check compares a
   re-encoding rather than an identity and a length, it will report a
   difference that the append-only contract says is impossible. Compare
   what the contract promises.
3. **The backend normalizes the entry after first use.** Read whether
   `Transcript` rewrites entry 0 when the session first responds. If it
   does, that is the one real answer and the contract statement above is
   wrong — say so plainly on this card.

- [x] Name what differs between the two readings, byte for byte
- [x] Remove the cause, so a stable entry compares equal
- [x] State which of the three answers was true

### Finding

Answer 1 is true: an unstable serialization order.

What differs, byte for byte: the order of the JSON object keys in
`ToolDefinitionPayload.parametersSchemaJSON` (and in
`TranscriptEntryPayload.responseFormatSchemaJSON`). The key sets, the
values and the `x-order` array are equal on every reading. Only the key
order moves.

Why: `TranscriptEntryMapper.jsonString(for:context:)` encoded a
`GenerationSchema` with a plain `JSONEncoder()`. `GenerationSchema`
encodes its objects from dictionaries, and Swift seeds a dictionary's
iteration order with the address of its storage. Each reading of the
transcript builds the schema's dictionaries at a new address, so each
reading encodes to a new key order.

Evidence: 100 readings of `LanguageModelSession(tools:instructions:)
.transcript`, entry 0 mapped through `TranscriptEntryMapper.event(from:)`,
gave 98 distinct `parametersSchemaJSON` strings. With `.sortedKeys` the
same 100 readings gave 1. A tight loop of 50 encodings gave 1 distinct
string because the loop reuses one address; that is why the defect hid.

Answer 2 is not the cause: the check compares the mapped payload, and
that payload is stable once the encoder is. Answer 3 is not the cause:
the SDK does not rewrite entry 0. The entry id, the text and the tool
set are equal on every reading. The contract statement above is
correct.

Fix: `TranscriptEntryMapper.jsonString(for:context:)` encodes with
`.sortedKeys`. The schema's `x-order` array carries the property order,
so sorted keys lose nothing on decode. `GuidedShapes.derivedSchema(for:)`
also uses a plain encoder, but its output feeds the grammar engine and
the recorded `grammar` string; nothing compares it, so it is unchanged.

### Acceptance Criteria

- [x] A multi-turn session records no `divergence` entry when nothing
      changed.
- [x] The comparison of one unchanged entry is stable across readings.
- [x] Every encoder that feeds a comparison is deterministic.
- [x] The card names the true cause with the evidence that found it.

### Tests

- [x] A test reads one unchanged entry twice and asserts the two
      readings compare equal.
- [x] A test drives two turns of a session whose tool surface does not
      change, and asserts no `divergence` is recorded.
- [x] A test asserts a tool definition set serializes to identical bytes
      across two encodings.

### The companion card

`^cybh869` makes the recorder append the turn whatever this check says.
That card lands on its own, and it is the more important of the two: a
transcript must never lose a turn. This card stops the false alarm that
made the loss happen.

Raised from FoundationModelsACPAgent, card ^jz016kq.

## Review Findings (2026-09-08 09:15)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsRouterTests/TranscriptFidelityTests.swift:708` `code-hygiene/idioms-swift` — preferContains: Prefer contains over filter(_:).isEmpty, first(where:) != nil, and range(of:) != nil.
