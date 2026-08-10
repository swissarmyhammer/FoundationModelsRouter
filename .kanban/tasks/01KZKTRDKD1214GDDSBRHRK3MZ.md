---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzntgy7am2ypb3nwjyf018wb
  text: |-
    Picked up. Research notes before editing.

    **API surface.** `RoutedSession` is `public protocol RoutedSession: Actor` (Sources/FoundationModelsRouter/Session/RoutedSession.swift). `cancel(_:)` and `replace(_:prompt:)` are `public func` in a `public`-facing `extension RoutedSession { ... }`. So the label rename IS a source-breaking change for any downstream consumer that calls them. No deprecation shim is on the card, so the break is intentional and must be reported.

    **Blast radius (full sweep of Sources, Tests, Examples, Scripts, *.md — no `.docc` catalog exists in this repo):**
    - 6 Swift call sites, all in tests:
      - Tests/FoundationModelsRouterTests/PromptQueueTests.swift — `session.cancel(firstId)`, `session.replace(secondId, prompt:)`, `session.cancel(id)`, `session.replace(id, prompt:)`
      - Tests/FoundationModelsRouterTests/TurnCancellationTests.swift — `session.cancel(queued)`, `session.cancel(id)`
    - 0 production call sites. `outbox.cancel(id:)` / `outbox.replace(id:prompt:)` and `mailbox.cancel(completionToken:)` are different symbols and are NOT affected.
    - 12 doc/comment references that name the old signature: RoutedSession.swift (6), RoutedSessionActorTurnExecution.swift (3, one of which is a plain `//` comment), TurnCancellationTests.swift (1), PromptQueueTests.swift (1), plan.md (1).

    **Prior-decision reversal (important for the next reader).** Cards `^ajkr5dd` (01KY66D7XQTANQD31HSAJKR5DD) and `^213x39` (01KY7E3ZQ0HV4C4SHH88213X39) investigated this exact pair on this exact code and recorded the opposite verdict — "leave as-is, deliberate verb+direct-object convention" — with a codebase-wide grep as evidence. This card supersedes that decision and orders the rename. Anyone re-reading those cards should treat them as superseded, not as a reason to revert.

    **Rule that bounds the extraction.** The `swift`/`fluent-usage` rule ("Omit the first argument label only for value-preserving conversions... Otherwise, label it") applies to the new private helper too, so the helper cannot copy the card's illustrative `_ elicitationId: String` first parameter — the card also says to apply each finding's cause to the whole file. The helper will label its first parameter.

    **Doc-link distinction to keep straight:** DocC symbol links (``…``) use EXTERNAL argument labels, so they change; doc `- Parameter` keys use INTERNAL names, so they do NOT change.
  timestamp: 2026-08-10T12:31:54.602927+00:00
- actor: claude-code
  id: 01kznw0962rnh3cr1x6z33ycyc
  text: |-
    Implementation landed. What was done and how it was verified.

    **1. Argument labels.** `RoutedSession.cancel(_:)` -> `cancel(id:)` and `replace(_:prompt:)` -> `replace(id:prompt:)`.

    Red step was real, not assumed: I changed ONLY the two declarations first and built. The compiler named the call sites for me, which is what proves the sweep was complete rather than merely plausible — `missing argument label 'id:' in call` at PromptQueueTests.swift 273/280/399/425, then TurnCancellationTests.swift 1234/1493 on the next pass. 6 call sites, all in tests, 0 in production.

    **2. Duplicated ULID parse.** Both guard blocks are gone — not left unused. The single parse now lives in one new private helper at the end of the same `extension RoutedSession`:

    ```swift
    private func deliver<Delivery>(
        toElicitation elicitationId: String,
        orReturn unparseableResult: Delivery,
        using delivery: (ULID) async -> Delivery
    ) async -> Delivery
    ```

    `respond(elicitationId:response:)` and `complete(elicitationId:)` are each now a single call into it. `grep -rn 'ULID(elicitationId)' Sources Tests` returns exactly one hit.

    **Deliberate difference from the card's illustrative signature.** The card sketched `parseElicitationIdOrReturnDefault<R>(_ elicitationId: String, defaultValue: R, operation: (ULID) async -> R)`. I kept that shape — generic over the delivery type, taking the fallback value and an operation closure — but LABELLED the first parameter and used a fluent base name. Reason: the same card's own findings 1 and 2 state the rule "Omitting the first argument label is only correct for value-preserving conversions", and the card's Notes order "Apply each finding's cause to the whole file rather than only the cited lines". Copying `_ elicitationId:` into a brand-new function would have re-introduced, in the same file, the exact defect this card exists to remove. Both instructions are satisfiable at once, so this is not a conflict — it is the card applied consistently.

    **Red verification of the extraction (the interesting discovery).** I neutered the helper so it always returned `unparseableResult`, then ran `swift test --filter ElicitationRoutingTests`. It does NOT fail — it **hangs**. Killed at ~794s with zero test output. In hindsight that is correct: with no answer ever delivered, every test that parks a run awaits a resumption that never arrives. Restored the file (sha1 verified byte-identical) and the same filter passes 7/7 in 0.020s. The hang-vs-0.020s contrast is the discriminating evidence that both public routes really do go through the single helper.

    Worth knowing for the next agent: `ElicitationRoutingTests` has no bounded-spin escape hatch, so a regression in the elicitation delivery path presents as a hung suite rather than a red test. `TurnCancellationTests` was given exactly such a hatch (`awaitCancelledUnwind`) for the same reason — see `^p0r7mxew`. Not fixed here; out of this card's scope.

    **Also verified, deliberately NOT changed:** the `- Parameter id:` doc key on `cancel` and the `- id:` entry under `replace`'s `- Parameters:` block. Those keys bind to INTERNAL parameter names, and the internal name stayed `id`. Only the external label changed, so only the ``…`` symbol links moved. The doc-parameter-naming rule is explicit that flagging internal names toward external labels is a validator error; this diff touches no `- Parameter` key at all.

    **Blast radius / source compatibility — stated plainly.** `RoutedSession` is a `public protocol` and both methods are `public` in its extension, so **this IS a source-breaking change for downstream consumers**. Any external caller written as `session.cancel(someId)` or `session.replace(someId, prompt:)` will no longer compile and must add `id:`. There is no deprecated shim — the card did not ask for one, and adding one unasked would have left the old unlabeled spelling in the public surface, which is what the card exists to remove. In-repo the break costs nothing (all 6 call sites are tests, now updated); out-of-repo it is a real break and should be called out in release notes.

    **Verification run:**
    - `swift build --build-tests` — clean; the only warning is the pre-existing `mlx-swift_Cmlx.bundle` one that is present at baseline.
    - `swift test` (ungated, no `FM_ROUTER_INTEGRATION_TESTS`) — **826 tests / 86 suites, 0 failures**, zero `✘`, no new warnings.
    - `python3 Scripts/check-doc-links.py` — **exit 0**, 0 stale, 0 unresolved. Counts moved 1256->1258 symbol links and 2321->2322 declarations, which is exactly the 2 links plus 1 declaration the new helper's doc comment adds.

    **Files changed (5):** Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Tests/FoundationModelsRouterTests/PromptQueueTests.swift, Tests/FoundationModelsRouterTests/TurnCancellationTests.swift, plan.md.

    No new tests were added: `ElicitationRoutingTests.unknownAndMalformedIdsAreNoOps` already exercises the unparseable-id branch for BOTH routes, and the delivery tests exercise the parsed branch for both, so the extraction left no path unexercised — which is the condition the card's Tests item set.
  timestamp: 2026-08-10T12:57:45.922793+00:00
- actor: claude-code
  id: 01kznw0f4erb6apj1j5cdastm7
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Tests/FoundationModelsRouterTests/PromptQueueTests.swift, Tests/FoundationModelsRouterTests/TurnCancellationTests.swift, plan.md. 6 call sites updated (all tests, 0 production), 12 doc/symbol-link references retargeted, 1 duplicated ULID parse collapsed to a single private helper. `swift test` ungated: 826 tests / 86 suites, 0 failures, no new warnings. `Scripts/check-doc-links.py`: exit 0, 0 stale, 0 unresolved. SOURCE-BREAKING for downstream callers of `cancel`/`replace` — no shim.
    - next: /review
  timestamp: 2026-08-10T12:57:52.014766+00:00
- actor: claude-code
  id: 01kznwpdz80mg77w9z7zh909ry
  text: |
    ### review — clean
    - scope: `review sha HEAD~1..HEAD` (sha 45b3930), 18 validator passes, 0 failed, 0 skipped
    - evidence: engine returned 1 finding, 1 confirmed; it is dropped by the review skill's blanket exception for pre-existing test code — `Tests/FoundationModelsRouterTests/TurnCancellationTests.swift:256` (`streamResponse(to:maxTokens:)`, nesting depth) dates to commit f62bb01e (2026-07-25); this delta touches only lines 9, 1234, 1493 of that file (one DocC link, two call sites). Zero recordable findings.
    - helper `deliver(toElicitation:orReturn:using:)` at `Sources/FoundationModelsRouter/Session/RoutedSession.swift:788`: no validator raised a finding on its generic signature, its argument labels, or its fallback-return design.
    - acronym waiver: not needed this pass — the engine raised no `Ram`/`Json`/`Llm`/`Ulid` casing finding.
    - all 6 prior checklist items checked; no prior `## Review Findings` sections existed.
    - next: task moved to `done`.
  timestamp: 2026-08-10T13:09:51.720185+00:00
- actor: claude-code
  id: 01kznwreaxfmvnv551zwfwzm2v
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files. `cancel(_:)`→`cancel(id:)`, `replace(_:prompt:)`→`replace(id:prompt:)`; duplicated ULID parse replaced by one private helper `deliver(toElicitation:orReturn:using:)`. Declarations changed first, then built — the compiler located the call sites, which is what proves the sweep complete.
    - test: green — swift test 826 tests / 86 suites, 0 failures, no new warnings. check-doc-links.py exit 0 (1258 links, 0 stale, 0 unresolved). Independently verified: 6 call sites (4x cancel, 2x replace) all in Tests/, 0 in Sources/Evals/Scripts/docs; exactly one `ULID(elicitationId)` remains (RoutedSession.swift:788) with both respond() and complete() routing through it; `- Parameter` keys correctly left on internal names while DocC symbol links moved to the new external labels.
    - commit: 45b3930 `refactor(router)!:` — 9 files, +163/-34, local only. Also carries ^6ejrrr7's board state (its done-move and ledger landed after c6d9606).
    - review: clean — zero new findings; 6 prior items checked. Engine: 18 passes, 0 failed. 1 finding dropped by the skill's written pre-existing-test-code exception (TurnCancellationTests.swift:256, from f62bb01e). The new helper drew no finding from any of the 18 passes.
    - **API BREAK — needs a release note.** `RoutedSession` is a `public protocol` and both methods are `public` in its extension. Downstream code calling `session.cancel(someId)` / `session.replace(someId, prompt:)` will no longer compile and must add `id:`. No deprecation shim was added — the card did not ask for one, and a shim would keep the old spelling in the public surface.
    - next: task moved to done. Discovery filed separately as ^6fszv54 — ElicitationRoutingTests hangs (~794s) instead of failing when the delivery path breaks, because it lacks the bounded-spin escape hatch TurnCancellationTests has.
  timestamp: 2026-08-10T13:10:57.629277+00:00
position_column: done
position_ordinal: fb80
title: RoutedSession's cancel/replace omit the first argument label, and its two elicitation methods duplicate the ULID parse
---
Surfaced by the `swift` + `missing-docs` validators while verifying `^6ejrrr7` (a doc-comment-only card). All four are pre-existing defects in `Sources/FoundationModelsRouter/Session/RoutedSession.swift` that `^6ejrrr7` deliberately did not touch: that card changes only ``…`` symbol-link text, and these are production signature/structure changes with callers.

Verbatim findings from `review file Sources/FoundationModelsRouter/Session/RoutedSession.swift --validators swift,missing-docs`:

- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:692` — The first parameter of `cancel(_:)` is unnamed, making the call read as `session.cancel(someId)` instead of the grammatically clearer `session.cancel(id: someId)`. Omitting the first argument label is only correct for value-preserving conversions (e.g., type conversions), not for operations on identifiers. The delegate call on line 693 uses the label (`outbox.cancel(id: id)`), so the wrapper should too. Change the signature to `public func cancel(id: SessionOutbox.ItemID) async` to make the call site read fluently: `session.cancel(id: someId)`.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:708` — The first parameter of `replace(_:prompt:)` is unnamed, making the first argument position read unclearly. Omitting the first argument label is only correct for value-preserving conversions (e.g., type conversions), not for operations on identifiers. The delegate call on line 709 uses the label (`outbox.replace(id: id, prompt: prompt)`), so the wrapper should too for consistency. Change the signature to `public func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async` to match the delegate's labeled style and improve call-site clarity: `session.replace(id: someId, prompt: newPrompt)`.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:739` — ULID parsing logic duplicated at lines 739-741 and 760-762. Both `respond(elicitationId:response:)` and `complete(elicitationId:)` contain identical guard blocks that parse the elicitation ID string and return `.noPendingElicitation` on failure. This pattern could drift if one is changed without updating the other. Extract a shared helper that wraps the ULID parsing and delegates to the mailbox method: `private func parseElicitationIdOrReturnDefault<R>(_ elicitationId: String, defaultValue: R, operation: (ULID) async -> R) async -> R`, then call it from both methods with their respective mailbox operations and default return values.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:760` — ULID parsing logic duplicated at lines 760-762 and 739-741 (see line 739 finding). See line 739 finding above.

## Notes for whoever picks this up

`cancel` and `replace` are `public` on `RoutedSession`, so renaming the first label is a source-breaking API change: sweep every caller (`get callgraph` inbound on both) and every ``…`` symbol link naming `cancel(_:)` / `replace(_:prompt:)`, since renaming the label changes the symbol name and would re-stale those links. `Scripts/check-doc-links.py` (added by `^6ejrrr7`) reports any link left behind — run it after the rename and expect exit 0.

Apply each finding's cause to the whole file rather than only the cited lines.

## Acceptance Criteria
- [x] `cancel` and `replace` label their first parameter, and every caller and symbol link is updated with them
- [x] The duplicated elicitation-id ULID parse exists in exactly one place
- [x] `Scripts/check-doc-links.py` exits 0 afterward
- [x] Ungated `swift test` stays green

## Tests
- [x] Existing session tests cover both call paths; extend them only if the rename or the extraction leaves a path unexercised #phase-1