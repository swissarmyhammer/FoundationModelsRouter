---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7attymx3sbzh1s5t99xf0e
  text: |-
    Research findings:
    - SessionMailbox (Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift) already carries the full respond/complete machinery from ^3g930c4/^b3arjr3: awaitAnswer(to:posting:), respond(elicitationId: ULID, _:) with URL-mode accept -> .acceptedAwaitingCompletion holding the entry open, complete(elicitationId: ULID), and sweep() rejection. Nothing to add at the mailbox level.
    - What is missing is exactly the RoutedSession-level surface: the `extension RoutedSession` convenience block in Sources/FoundationModelsRouter/Session/RoutedSession.swift (enqueue/cancel/replace conveniences over outbox) has no elicitation conveniences over `mailbox`. Plan: add `respond(elicitationId: String, response:)` and `complete(elicitationId: String)` there, parsing the String id with ULID.init?(_:) (unparseable -> .noPendingElicitation no-op) and delegating to this session's own `mailbox` — references the whole way, no task locals, so cross-session routing is impossible by construction.
    - ToolContext.elicit already parks via mailbox.awaitAnswer; acceptance's "parked ToolContext.elicit resumes on session respond" is testable by binding a ToolContext with the session's mailbox + a stub sink.
    - The awaitingUser doc comment in RoutedSession.swift also asserts "Router deliberately does not implement elicitation itself" — must be updated along with plan.md (~816 context, 851-855, 1176-1184) to record the reversed decision.
    - Test scaffolding: per-file StubProbe/StubModelLoader/BasicLLMContainer copies are the prevailing pattern (~20 files); new ElicitationRoutingTests.swift will carry its own copy, modeled on SessionMailboxTests.makeSession.
  timestamp: 2026-08-04T21:28:19.668594+00:00
- actor: claude-code
  id: 01kz7bahz61p0bce43s9xddhfn
  text: |
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/RoutedSession.swift (new `respond(elicitationId:response:)` and `complete(elicitationId:)` conveniences in the `extension RoutedSession` block, delegating by reference to this session's own SessionMailbox with ULID-parse guard so unknown/malformed ids are safe no-ops; awaitingUser doc comment updated to record Router carrying elicitation's envelope + resume plumbing), plan.md (reversed-decision rewrites of the "Router does not implement elicitation" paragraphs at ~851 and the Decisions bullet at ~1186; `grep -i elicit plan.md` shows no remaining denial — line 816 only cites elicitation as a human-wait example), Tests/FoundationModelsRouterTests/ElicitationRoutingTests.swift (new, 6 tests: form round trip through a real parked ToolContext.elicit; decline-is-not-cancel; URL two-step with run-still-parked-after-accept and duplicate-complete no-op; double-elicit independence; unknown/malformed id no-ops; cross-session isolation).
    - TDD: tests written first and confirmed failing (missing surface resolved against respond(to:maxTokens:)), then implementation made them pass.
    - swift test fully green: 680 + 18 + 12 tests, 0 failures. Only warning is the pre-existing SwiftPM "missing creator for mutated node" on the vendored mlx bundle, unrelated to this change.
    - double-check verdict: PASS (verified no-task-locals route, mailbox URL-mode semantics, blast radius additive-only, no remaining ownership denial anywhere in Sources/Tests/README).
    - next: /review
  timestamp: 2026-08-04T21:36:54.758038+00:00
- actor: claude-code
  id: 01kz7bfkm8jnnf334mg2asn3w2
  text: |-
    ### test — green
    - evidence: `swift test` — 710 tests passed (680+18+12 across 3 suites), 0 failed, 29 gated skips (expected, FM_ROUTER_INTEGRATION_TESTS/compaction integration gates); only warning is the known pre-existing llbuild "missing creator for mutated node" from mlx-swift Cmlx bundle
    - next: proceed to review
  timestamp: 2026-08-04T21:39:40.296742+00:00
depends_on:
- 01KZ6MZPV6VDYYDBACD3G930C4
- 01KZ6N038H8VC4C5CXQXYKSGNS
- 01KZ6N1146TF1T334TRB3ARJR3
position_column: doing
position_ordinal: '80'
title: '[Router] RoutedSession elicitation replies: respond and complete'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"The ambient context" (host verb paragraph) and §"The elicitation envelope" (URL-mode two-step).

## What
The inbound answer route: app host → Router → mailbox → resume parked continuation. Add to the `RoutedSession` surface (protocol extension conveniences at RoutedSession.swift:529-664 are the natural home, alongside `awaitingUser`):
- `respond(elicitationId: String, response: ElicitationResponse) async` — look up the pending elicitation in the session's `SessionMailbox` and resume it. Answers address the elicitation, never the run — one run can hold several pending elicitations. Unknown or already-completed ids are safe no-ops per the MCP spec.
- `complete(elicitationId: String) async` — URL-mode second step: the accept only meant the user agreed to open the URL; completion arrives separately. The mailbox holds a URL-mode elicitation open past the accept until this arrives. Duplicates and unknown ids are safe no-ops.
- Semantics: a form-mode `accept` resumes with `content`; `decline` and `cancel` resume with those actions — a declined elicitation is not a cancelled run; the tool decides what to do.
- The route uses no task locals: `respond`/`complete` → `RoutedSessionActor` → that session's mailbox → the entry → its continuation. References the whole way; two sessions sharing a registry can never cross-route.
- Documentation: Router's `plan.md` asserts in SEVERAL places that Router does not implement elicitation ("elicitation lives in FoundationModelsACPAgent" at lines ~850-854; "elicitation itself — it owns no user channel; the coordinator lives in …" at ~1181; a related statement near ~815 — grep `plan.md` for "elicit" and update every such paragraph). This task reverses that decision per ../FoundationModelsMultitool/eventplan.md: record that Router carries the typed envelope and the resume plumbing while the presenting UI stays the host app's. No remaining `plan.md` sentence may deny Router's elicitation ownership.

## Acceptance Criteria
- [ ] A parked `ToolContext.elicit` on a session resumes when `respond(elicitationId:response:)` is called on that session, with the exact response passed through
- [ ] URL-mode: after `respond(.accept)` the run is still parked; it resumes only on `complete(elicitationId:)`; a duplicate `complete` is a no-op
- [ ] Two pending elicitations on one run resolve independently; responding to one leaves the other parked
- [ ] Unknown-id `respond`/`complete` are no-ops
- [ ] `grep -i elicit plan.md` shows no remaining sentence denying Router's elicitation ownership (all occurrences updated: ~850-854, ~1181, ~815)
- [ ] `swift test` green

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/SessionMailboxTests.swift` / new `ElicitationRoutingTests.swift`: form round trip through a real `RoutedSession`-level call; URL two-step; double-elicit independence; unknown-id and duplicate no-ops; cross-session isolation (respond on session A never resumes session B's elicitation)
- [ ] `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first