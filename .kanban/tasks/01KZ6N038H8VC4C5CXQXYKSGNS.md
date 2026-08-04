---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz6xb4tw3ne687ka23sqmpjr
  text: |-
    Research done. Discoveries:
    - Basis doc read (../FoundationModelsMultitool/eventplan.md §"The elicitation envelope, fixed to the MCP spec"): form mode per MCP 2025-06-18, url mode per 2025-11-25; carries mode (omitted = form), message, elicitationId (ULID); form carries requestedSchema (flat object, primitive-only subset), url carries url. Response is accept|decline|cancel with content only on form-mode accept.
    - ULID is already re-exported via Core/ULID.swift (@_exported import ULID, yaslab lib, Codable as 26-char string) — no new dependency needed.
    - OperationEvent uses synthesized Codable; its optional `outcome` already decodes via decodeIfPresent, so adding optional `elicitation` the same way keeps recorded events decoding unchanged.
    - Only two code sites branch on OperationEventKind: SessionOutbox.post (coalescing switch) and OperationEventSegment.renderedLine (ternary → must become a switch). Blast radius is contained; adding the case will surface any others via exhaustive-switch compile errors.
    - Plan: TDD — new ElicitationEnvelopeTests.swift (schema subset accept/reject matrix, three-action round trips, content-only-on-accept, omitted-mode-as-form, OperationEvent back-compat + round trip, renderedLine) plus SessionOutboxTests elicitation-never-coalesces cases; then implement Hosting/Elicitation.swift, OperationEvent third kind + optional field + doc update, outbox policy, renderedLine.
  timestamp: 2026-08-04T17:32:34.012054+00:00
- actor: claude-code
  id: 01kz6y5j90nzk60e47ndpnpgge
  text: |-
    Implementation landed via TDD (red observed both times as compile failures on the new API, then green):
    - New Sources/FoundationModelsRouter/Hosting/Elicitation.swift: ElicitationMode (form|url; omitted decodes as form), ElicitationRequest (message, elicitationId ULID, form-mode requestedSchema / url-mode url, mode-aware Codable), ElicitationRequestedSchema (flat object only; non-object root rejected at decode), ElicitationPrimitiveSchema (string/number/boolean/singleSelect/multiSelect; "object" and unknown types throw — nesting is unrepresentable in Swift construction), payload structs with title/description/bounds/formats/enumNames/defaults, ElicitationValue, ElicitationResponse (accept|decline|cancel; private memberwise init + accept()/decline/cancel constructors keep content-on-decline unrepresentable; decode enforces content-only-on-accept).
    - OperationEvent.swift: third OperationEventKind case elicitation (never terminal; terminal-scope contract doc now spans three kinds), optional `elicitation: ElicitationRequest?` field mirroring how `outcome` was added (synthesized decodeIfPresent keeps recorded events decoding — covered by back-compat test).
    - SessionOutbox.swift: post() appends .elicitation like .completed; only .progress coalesces; docs updated.
    - OperationEventSegment.renderedLine: switch over three kinds; elicitation renders "eliciting: <request message>" falling back to detail.
    - Tests: new ElicitationEnvelopeTests.swift (20 tests: subset accept/reject matrix incl. nested object, array-of-objects, enum-less array, unknown type, non-object root; mode semantics; round trips; response actions; content-only-on-accept; OperationEvent back-compat + round trip; renderedLine) and 3 new SessionOutboxTests elicitation-never-coalesces cases.

    Double-check verdict was REVISE with three findings, all implemented:
    1. ElicitationRequest doc claimed "obeys the MCP specification exactly / no invented shape" while init(from:) requires elicitationId in both modes (MCP form mode carries none — its answer rides the JSON-RPC response). Kept the field required in both modes (the respond(elicitationId, response) routing contract in eventplan.md needs the address in form mode too) and rewrote the doc to state this as the one deliberate deviation, including that an MCP passthrough adapter must mint an id for inbound form-mode requests.
    2. ElicitationMultiSelectSchema silently dropped items.enumNames (asymmetric with single-select). Added enumNames property, wired through items decode/encode, TDD'd via the toppings fixture.
    3. OperationEvent struct summary doc still said "progress/completion event" — updated to name all three kinds.

    Evidence: swift test → three bundles green, 632 + 18 + 12 tests, 0 failures; no compiler warnings (the single "missing creator for mutated node" line is a pre-existing SwiftPM build-graph note about the vendored mlx bundle, present before this change).
  timestamp: 2026-08-04T17:46:59.744285+00:00
- actor: claude-code
  id: 01kz6y5qv3n8r2kn4550y9yk67
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Hosting/Elicitation.swift (new), Sources/FoundationModelsRouter/Hosting/OperationEvent.swift, Sources/FoundationModelsRouter/Session/SessionOutbox.swift, Sources/FoundationModelsRouter/Session/OperationEventSegment.swift, Tests/FoundationModelsRouterTests/ElicitationEnvelopeTests.swift (new), Tests/FoundationModelsRouterTests/SessionOutboxTests.swift; swift test green: 632 + 18 + 12 tests, 0 failures, 0 compiler warnings
    - next: /review (task stays in doing; do not commit — orchestrator handles it)
  timestamp: 2026-08-04T17:47:05.443679+00:00
- actor: claude-code
  id: 01kz6z2jgrtkz7cyp3jxwjwd1f
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (backend: local) — 0 findings, 9 validators attempted, 0 failed
    - next: task moved review → done
  timestamp: 2026-08-04T18:02:50.264012+00:00
- actor: claude-code
  id: 01kz6z64yqerx3606yaeyy2ydz
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files (Hosting/Elicitation.swift new, OperationEvent.swift third kind, SessionOutbox never-coalesce, OperationEventSegment rendering, ElicitationEnvelopeTests new 20 tests, SessionOutboxTests +3)
    - test: green — swift test, 632+18+12 = 662 passed, 0 failures, 20 expected FM_ROUTER_INTEGRATION_TESTS skips
    - commit: 83807b2
    - review: clean — 0 new findings on HEAD~1..HEAD, 9 validators, 0 failed
  timestamp: 2026-08-04T18:04:47.447822+00:00
depends_on:
- 01KZ6MY4E1H1RG9SCY8YR4A48H
position_column: done
position_ordinal: e680
title: '[Router] Elicitation envelope, third event kind, outbox coalescing'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"The elicitation envelope, fixed to the MCP spec".

## What
- New `Sources/FoundationModelsRouter/Hosting/Elicitation.swift`: `ElicitationRequest` — `mode` (`form` | `url`; omitted decodes as form), `message`, `elicitationId` (ULID); form mode carries `requestedSchema` restricted to the MCP subset (flat objects, primitive properties only: bounded strings with `email`/`uri`/`date`/`date-time` formats, numbers, booleans, single/multi-select enums, defaults — reject nested objects at construction); URL mode carries `url`. `ElicitationResponse` — three-action model `accept | decline | cancel`, `content` present only on a form-mode accept. Note: FoundationModelsMCP has no `ElicitationRequest` type today (its coordinator passes raw message+schema), so this is the first typed envelope; keep it Codable and spec-shaped so phase 4's MCP passthrough loses nothing.
- `Hosting/OperationEvent.swift`: add the third `OperationEventKind` case (`elicitation`), and carry the typed request on `OperationEvent` as an optional field mirroring how `outcome` was added (`decodeIfPresent` so previously recorded events decode unchanged). Update the terminal-event scope contract doc to span three kinds: elicitation events are never terminal; a run that posts events still posts exactly one `.completed`.
- `Session/SessionOutbox.swift` coalescing policy: elicitation events behave like `.completed` — always appended, never coalesced. Only `.progress` coalesces (existing in-place replacement by `(tool, correlationID)` stays).
- `Session/OperationEventSegment.swift` / `renderedLine(for:)`: render the elicitation kind sensibly in the turn-preamble line.

## Acceptance Criteria
- [ ] `ElicitationRequest` rejects a nested-object schema at construction; accepts every primitive shape in the restricted subset
- [ ] Decoding a recorded `OperationEvent` JSON with no elicitation key succeeds (back-compat); round trip preserves a present request
- [ ] `SessionOutbox` never coalesces elicitation events: two elicitations for the same `(tool, correlationID)` both survive a drain; interleaved `.progress` still coalesces
- [ ] Terminal contract doc names three kinds; `swift test` green

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/ElicitationEnvelopeTests.swift`: schema-subset acceptance/rejection matrix; three-action response codable round trips; form-content-only-on-accept invariant; omitted-mode-decodes-as-form
- [ ] Extend `SessionOutboxTests.swift`: elicitation-never-coalesces cases
- [ ] `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first