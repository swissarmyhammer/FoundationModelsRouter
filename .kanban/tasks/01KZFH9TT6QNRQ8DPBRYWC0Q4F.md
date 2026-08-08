---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzge1wj4gcmvg7q8rdydedg1
  text: |-
    Picked up; moved to `doing`. Research findings before writing code:

    - `PendingRunEnvelope` lives in `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift` with `renderedPrefix`/`renderedSuffix` (both `private static`), `rendered`, and `isRendered(_:)`.
    - Consumers of the wire form: `TokenCappingTool.call` (`Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift`) is the only `isRendered` caller. `ElevatingTool.elevate` is the only producer, and it ALSO stuffs `envelope.rendered` into the synthesized `.progress` event's `detail`.
    - That second use is the "render cap" the card warns about: `SessionMailbox.boundingDetail` truncates a `detail` longer than `SessionMailbox.terminalDetailTailLimit` (4096) by keeping the **trailing** characters — so an envelope that ever grew past 4096 would lose its leading `completionToken`. New envelope is ~370 chars; adding a test that pins `rendered.count < terminalDetailTailLimit`.
    - No `RunPlaneState` type exists in Router. `SessionMailbox.WaitResult` has `.settled(OperationEvent)` / `.deadlineElapsed` / `.unknownToken` but carries no wire strings; `OperationOutcome.wireVocabulary` is the only snake_case wire vocabulary and it has no `settled`/`deadline_elapsed` entries. So the two state names get named `private static` constants on `PendingRunEnvelope`, doc-linked to the `WaitResult` cases they spell — not inline literals. `60` likewise becomes a named constant.
    - Test sites that decode the envelope: `Tests/.../ElevatingToolTests.swift` (private `DecodedEnvelope` + `decodeEnvelope`, used by ~10 tests) and 4 spots in `Tests/.../SessionOutboxToolWiringTests.swift`, one of which is the capping-passthrough test to update.
    - Plan for `isRendered`: keep the fixed-length guard, extract the first token slot, require it to be a valid ULID, then require `text` to equal the rendering of THAT token. That makes twin-token mismatch, any prose edit, and any length change all rejections by construction, and recognition can never drift from rendering.
  timestamp: 2026-08-08T10:17:46.308650+00:00
- actor: claude-code
  id: 01kzgecj580krssgnn30j8g3p3
  text: |-
    Implementation landed, TDD order observed.

    RED first: extended the suite's private `DecodedEnvelope` with a non-optional `next` (so EVERY test that decodes a produced envelope now proves the instruction is there, not just the new ones) and added 7 wire-form tests. `swift test --filter ElevatingTool` went red with 18 issues for exactly the right reasons — `DecodingError.keyNotFound: Key 'next' not found` on the 8 producing tests, and `isRendered` accepting the tampered/legacy variants.

    GREEN: the new wire form is 435 characters, e.g.

    ```
    {"pending":true,"completionToken":"<T>","next":"This run is still going. Do not answer yet, and never invent or guess its result. Call this tool again with a snippet that does: return await wait(\"<T>\", 60). When the returned state is \"settled\", the result is in its detail field. When it is \"deadline_elapsed\", the run is still going: call wait again with the same completionToken."}
    ```

    Notes on the choices:

    - Recognition is now defined AS re-rendering: `isRendered` checks the fixed total length and the prefix, reads the token out of the first slot, requires it to parse as a ULID, then requires `text == rendered(forCompletionToken: thatToken)`. Twin-slot mismatch, any prose edit, and any length change are therefore rejections by construction rather than three separate hand-written checks that could drift.
    - `rendered` and `isRendered` both go through one private `rendered(forCompletionToken:)`, so the frame can never be spelled twice.
    - The prose says "Call this tool again", not "Call runCode again" as the card's example did: the envelope is produced by `ElevatingTool` wrapping ANY tool and only holds the token, and naming the tool would make the frame variable-length, breaking the fixed-length recognition the card also requires.
    - `60`, `settled`, and `deadline_elapsed` are named `private static` constants (`followUpWaitSeconds`, `settledStateName`, `deadlineElapsedStateName`), the last two doc-linked to the `SessionMailbox.WaitResult` cases they spell. There is no `RunPlaneState` type in Router to splice from — see the research comment above.
    - `next` is derived, not stored: no new `Codable` field, so `Equatable`/decode behavior for existing consumers is unchanged and the four `PendingRunEnvelope` decode sites in `SessionOutboxToolWiringTests` keep working untouched.
    - Added a test pinning `rendered.count <= SessionMailbox.terminalDetailTailLimit`, because `ElevatingTool.elevate` also carries the rendered envelope as the synthesized progress event's `detail`, and the mailbox bounds an oversized `detail` by keeping its TRAILING characters — an envelope that outgrew 4096 would silently lose its leading `completionToken`.
    - Updated the two doc comments that described the old single-field wire form (`PendingRunEnvelope`'s own, and `TokenCappingTool.call`'s exemption rationale).

    Not done, deliberately: the last acceptance criterion ("Committed on `main` and PUSHED") stays unchecked. Committing and pushing was explicitly withheld from this step — pushing needs the user's own authorization, which has not been given.
  timestamp: 2026-08-08T10:23:36.104797+00:00
- actor: claude-code
  id: 01kzgecs8recam795b6pdqa2jc
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift, Tests/FoundationModelsRouterTests/ElevatingToolTests.swift (+7 wire-form tests, `DecodedEnvelope.next` added), Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift (capping-passthrough test now asserts byte-exact equality with a freshly rendered envelope). Ungated `swift test`: 743 + 20 + 12 = 775 tests passed, 0 failures. RED first: `swift test --filter ElevatingTool` failed with 18 issues before the source change, then 31/31 passed after.
    - next: `/review`. Task stays in `doing`; not committed, not pushed — the "Committed on `main` and PUSHED" criterion is left unchecked pending the user's own push authorization.
  timestamp: 2026-08-08T10:23:43.384895+00:00
- actor: claude-code
  id: 01kzgex6e5x0f9msjw95shjdw1
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 0bbf84e, 4 files, 248+/22-); 9 validators attempted, 0 failed, 0 skipped; counts findings=0 confirmed=0 refuted=0. No Ram/Json/Llm casing findings were emitted, so nothing needed waiving. Independently verified: `isRendered` is exact byte-shape by re-render (length gate on `renderedLength`, prefix gate, token read from first slot, `ULID(...) != nil`, then `text == rendered(forCompletionToken:)`) at Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:213-240 — twin-slot mismatch, prose edited at unchanged length, wrong length, non-ULID slots, and the old instruction-free form are all rejections by construction, each covered by a test at Tests/FoundationModelsRouterTests/ElevatingToolTests.swift:376-524. `TokenCappingTool.call` returns the recognized envelope by `return output` unchanged at Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:169-172, asserted byte-exact at Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:1250-1251. Envelope length gated against `SessionMailbox.terminalDetailTailLimit` (4096) at ElevatingToolTests.swift:442. Production timing unchanged: both ElevatingTool.swift hunks are inside `PendingRunEnvelope`; the sole construction site (ElevatingTool.swift:441) is untouched. Deviation 1 holds — `PendingRunEnvelope` receives only a completionToken and splicing a wrapped tool's name would make the frame variable-length, defeating the card's own fixed-frame `isRendered` requirement. Deviation 2 confirmed independently — no `RunPlaneState` exists in Sources; `SessionMailbox.WaitResult` (SessionMailbox.swift:75-88) is a plain enum with no raw/wire strings, and `OperationOutcome.wireVocabulary` (OperationOutcome.swift:62-69) holds succeeded/failed/timed_out/stopped/cancelled/lost with no `settled` or `deadline_elapsed`; the doc-linked named constants are the only available source of those spellings.
    - next: Acceptance criterion "Committed on `main` and PUSHED" remains unchecked — pushing was not authorized in this pass and was not treated as a review finding. The user owns that checkbox and the push.
  timestamp: 2026-08-08T10:32:41.157926+00:00
- actor: claude-code
  id: 01kzgf1sxx5r90682df5qsqarb
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files: Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift, Tests/FoundationModelsRouterTests/ElevatingToolTests.swift, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift. TDD RED first: 18 issues before the source change, 31/31 green after
    - test: green — ungated `swift test` 743+20+12=775 passed, 0 failures. Only `warning:` in output is the pre-existing SwiftPM/llbuild `missing creator for mutated node: mlx-swift_Cmlx.bundle/Contents/MacOS`, which reproduces on a bare `swift build` and belongs to the vendored dependency's build graph, not this change
    - commit: changed — 0bbf84e `feat(router): teach pending envelope its next-step instruction`, 4 files, 248 insertions / 22 deletions. `.kanban/` deliberately left unstaged so HEAD~1..HEAD is exactly the code delta
    - review: clean — `review sha HEAD~1..HEAD` (0bbf84e); findings=0 confirmed=0 refuted=0; 9 validators attempted, 0 failed, 0 skipped; no Ram/Json/Llm findings to waive
    - next: task moved to done by the review gate. Two card deviations independently confirmed by review: (1) prose says "Call this tool again" not "Call runCode again" because PendingRunEnvelope's initializer takes only a token and splicing a tool name would make the frame variable-length, contradicting the card's own fixed-frame isRendered requirement — the card carries an internal tension, resolved in favor of the stated recognition contract; (2) no RunPlaneState equivalent exists in Sources/ (WaitResult has no raw value; OperationOutcome.wireVocabulary has only succeeded/failed/timed_out/stopped/cancelled/lost), so settledStateName/deadlineElapsedStateName are the only way to name those spellings
    - OPEN: acceptance criterion "Committed on `main` and PUSHED" remains UNCHECKED. Push is not authorized by the user; MultiTool pins Router by branch so the fix stays invisible to MultiTool's gated suite until pushed. Awaiting user authorization.
  timestamp: 2026-08-08T10:35:12.189486+00:00
position_column: done
position_ordinal: f480
title: '[Router] Pending envelope must teach the collect step: render next-step instructions into PendingRunEnvelope'
---
HUMAN-DIRECTED ROOT-CAUSE FIX (2026-08-07). This card is Router-native; it edits only FoundationModelsRouter sources.

## Why (evidence, researched in source — not inferred)

`PendingRunEnvelope.rendered` (`Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:141`) is the ONLY model-facing wire output in the elevation system that carries no next-step instruction. Its exact bytes today:

```
{"pending":true,"completionToken":"<26-char ULID>"}
```

A model whose long tool call parks receives this and nothing else. To proceed it must recall one sentence buried at the tail of MultiTool's runCode description. Measured consequence (MultiTool card 01KZ6N5Z39W4ZBBE74JTKRDWB8, 2026-08-07): `elevationInCodeMode` red 3/3, every failure at the collect step with `pendingEnvelope=pass`; a control run hallucinated the report code outright — the signature of a model holding a token it does not understand while the user demands an answer.

The contrast is decisive and comes from the same day's measurements: every in-band text that DOES teach the next move succeeds — MultiTool's deliberately vague booking tool repairs 4/5 because the error text names the fix; `liveContextCapError` is "phrased as repair instructions, like every other error this package hands a model" (MultiTool's own stated house rule); the unknown-tool near-match hints produced 8/8 clean invocations. The parked envelope is the one violation of that rule, and it sits exactly where the suite fails.

## What

Make the rendered envelope self-describing while keeping recognition byte-exact:

- New wire form: fixed `prefix` + token + fixed `midfix` + token + fixed `suffix`, e.g.:
  `{"pending":true,"completionToken":"<T>","next":"Still running — do not answer yet and never invent the result. Call runCode again with a snippet that does: return await wait(\"<T>\", 60) — when its state is \"settled\" the result is in its detail field; if \"deadline_elapsed\", call wait again with the same token."}`
  Adjust wording freely; the facts that MUST be present, in this order: still running; do not answer / do not invent; the exact follow-up snippet with the real token spliced in; result is in `detail` when state is `settled`; on `deadline_elapsed` wait again. Splice state names from `RunPlaneState`-equivalent constants where they exist rather than retyping.
- `isRendered` stays an exact byte-shape check: fixed frame lengths, both token slots must be the SAME valid ULID.
- `TokenCappingTool` passthrough keeps recognizing it (it calls `isRendered`; verify with its existing test, updated).
- Total length stays far under any render cap.
- No change to WHEN the envelope is produced — only its wire text.

## Acceptance Criteria
- [x] `rendered`/`isRendered` round-trip exact for random ULIDs; tampered variants (mismatched twin tokens, wrong lengths, edited prose) rejected
- [x] `TokenCappingTool` passes the new envelope through untouched
- [x] `swift test` green in FoundationModelsRouter (ungated)
- [ ] Committed on `main` and PUSHED — MultiTool consumes Router via `.package(url:branch:)`, so the fix is invisible to MultiTool's gated suite until it is on the remote branch (push 159aada with it, or as agreed with the human)

## Tests
- [x] Unit tests for the new wire form incl. adversarial variants (same file's existing envelope tests extended)
- [x] `swift test` in FoundationModelsRouter, 0 failures

## Workflow
- Use `/tdd` — write the failing recognition/rendering tests first.
#phase-1