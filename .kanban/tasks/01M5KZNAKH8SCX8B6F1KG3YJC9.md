---
comments:
- actor: wballard
  id: 01m5kzvs1nyeravqjbbjb5j4kc
  text: 'Research: PassOutputRelay.OutputWatch reports only the confirmed first token (2nd output event -> GenerationPassObserver.passProducedOutput -> GenerationCallPhase.firstOutput). The session takes a call''s timing from GenerationCallLedger.timingOfEndedCall after drainGenerationPassPhases(). Plan: the relay also reports the FIRST output event at once as a new phase (.firstOutputEvent); the ledger marks a call buffered when it saw that phase and no .firstOutput. Reporting at the first event (not at the end of the pass) keeps the flag race-free: the pump notes an event before the forwarder hands it to the SDK, so the phase is recorded before any tool open or attempt close can take the call. Flag rides in GenerationCallTiming.outputBuffered -> GenerationCallUsage.outputBuffered -> TranscriptEvent.outputBuffered (makePartialEvent) and span attribute generation.output_buffered. No .md (ARCHITECTURE.md, session.md, generation-queue.md, README.md) describes first_token_seen or time to first token, so the doc subtask lands in the Swift doc comments only. Test model MeteredFirstOutput.nothingUntilTheEnd already sends a whole call in one output event.'
  timestamp: 2026-10-23T09:00:54.709711+00:00
- actor: wballard
  id: 01m5m07zmqpgjwd6ff1j9nf602
  text: 'Implementation landed. PassOutputRelay.OutputWatch now reports the first output event at once (GenerationPassObserver.passSentFirstOutputEvent -> GenerationCallPhase.firstOutputEvent), before the pump hands the event to the forwarder, so the phase is in the observer before the SDK sees the event or a tool can open. GenerationCallLedger.sawOutputEvent is set by that phase and cleared at passStarted and at noteEndedCall; timingOfEndedCall returns GenerationCallTiming.buffered (outputBuffered=true, no times) when the pass sent an output event and no firstOutput. The flag rides GenerationCallTiming.outputBuffered -> GenerationCallUsage.outputBuffered (public, init default false) -> makePartialEvent -> TranscriptEvent.outputBuffered / Partial.outputBuffered (journal key outputBuffered, nil on non-generationCall events) and RouterTelemetry.AttributeKey.outputBuffered = generation.output_buffered on every generation call span. Rejected alternative: reporting ''buffered'' at the end of the relay (after run returns) races the SDK tool open, which can take the call before the relay returns. Docs: GenerationCallUsage.timeToFirstToken/decodeTime/firstTokenSeen/outputBuffered, RouterTelemetry timeToFirstTokenMs/firstTokenSeen/outputBuffered and the generationCall span list, TranscriptEvent, PassOutputRelay. No .md file (ARCHITECTURE.md, session.md, generation-queue.md, README.md) describes first_token_seen or time to first token, so none changed. Note: a watch-stopped streamed call cut after exactly one output event also reads as buffered; its first token is equally unobservable.'
  timestamp: 2026-10-23T09:07:34.679313+00:00
- actor: wballard
  id: 01m5m087prx2pvyaen082smpc8
  text: |-
    ### implement — changed
    - evidence: 12 files — Sources/FoundationModelsRouter/Concurrency/{GenerationPassObserver,PassOutputRelay}.swift, Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift, Sources/FoundationModelsRouter/Session/{GenerationCallUsage,GenerationStall,RoutedSessionActorGenerationCalls,RoutedSessionActorGenerationCallSpans,RoutedSessionActorRecording}.swift, Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift, Tests/FoundationModelsRouterTests/{GenerationCallOutputBufferedTests (new),PassOutputRelayTests,TranscriptEventSchemaTests}.swift. RED: 4 new tests failed on missing behavior; GREEN: filtered run 60 tests/4 suites passed; full swift test: 2171 tests/266 suites passed (9 pre-existing known issues), 39/23 passed, 19/3 passed; no compiler warnings (only the pre-existing build-system 'missing creator for mutated node' notice).
    - next: /review
  timestamp: 2026-10-23T09:07:42.936782+00:00
- actor: wballard
  id: 01m5m0amtx4f3njpr04pr2g1v4
  text: |-
    ### test — green
    - evidence: swift test — 3 test products: XCTest 0 tests 0 failures; Swift Testing main run 2171 tests in 266 suites passed with 9 known issues (all pre-existing withKnownIssue cases); other runs 39 tests/23 suites and 19 tests/3 suites passed; 0 ✘ lines; 0 compiler warnings (only the allowed mlx-swift_Cmlx.bundle missing-creator notice); new suite 'Generation call output buffered' passed
    - next: review
  timestamp: 2026-10-23T09:09:01.917996+00:00
- actor: wballard
  id: 01m5m10880sd8v7n72mshm45te
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (local backend), 1 finding (1 confirmed, 0 refuted, 14 attempted) — Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:261 completeness/invariant-propagation
    - next: /implement the open Review Findings item, then /review
  timestamp: 2026-10-23T09:20:49.920925+00:00
- actor: wballard
  id: 01m5m10rr4wr7dh0518x0mwg8c
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 12 files
    - test: green — swift test, 2171 + 39 + 19 passed (9 expected known issues)
    - commit: e9169b5f
    - review: findings — Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:261
  timestamp: 2026-10-23T09:21:06.820233+00:00
- actor: wballard
  id: 01m5m14c7drv9k8g3q3nt81h15
  text: 'Review finding (TranscriptEventSchemaTests.swift:261, completeness/invariant-propagation) addressed: added generationCallWithoutOutputBufferedKeyDecodesAsNil — a hand-written .generationCall line with callMs and firstTokenSeen=false but no outputBuffered key (a recording made before the key existed) decodes with kind .generationCall, firstTokenSeen false, outputBuffered nil. The decoded default is nil (TranscriptEvent.outputBuffered is Bool?, synthesized Codable), so the name ends AsNil, matching lineWithoutAgentSpawnKeyDecodesAsNil. Cause applied across the file: outputBuffered is the only TranscriptEvent field this change (e9169b5f) added, so no other absent-key test was missing. The test covers existing behavior, so it passed on its first run (no production change needed).'
  timestamp: 2026-10-23T09:23:05.069175+00:00
- actor: wballard
  id: 01m5m14d3tpt0eyn311tkfmgcc
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift (new test generationCallWithoutOutputBufferedKeyDecodesAsNil); finding flipped to [x]. swift test --filter TranscriptEventSchemaTests: 45 tests in 1 suite passed. Full swift test: 2172 tests in 266 suites passed with 9 known issues (pre-existing), 39 tests in 23 suites passed, 19 tests in 3 suites passed; XCTest 0 tests; 0 failures; only the pre-existing mlx-swift_Cmlx.bundle missing-creator notice.
    - next: /review
  timestamp: 2026-10-23T09:23:05.978752+00:00
- actor: wballard
  id: 01m5m16212m0zc79g0ykgdcms4
  text: |-
    ### test — green
    - evidence: swift test — three runs passed: 2172 tests in 266 suites (9 known issues, withKnownIssue), 39 tests in 23 suites, 19 tests in 3 suites; 0 failures, 0 ✘ lines, 0 compiler warnings (only the allowed mlx-swift_Cmlx.bundle missing-creator notice)
    - next: review/commit
  timestamp: 2026-10-23T09:24:00.162547+00:00
position_column: doing
position_ordinal: '80'
title: Label passes whose output arrives in one buffered event (generation.output_buffered)
---
Replaces ^4g1pdrz. Decision 2026-10-23: no change to mlx-swift-lm. Its allowed-tool path sends a tool-call-only pass (no reasoning) as one output event at the end of generation, and its public API carries no prefill timing, so Router cannot observe the first token of such a pass. Today those calls record first_token_seen=false with nothing to say why (45 of 105 calls in router-telemetry-16), which looks like lost data.

Label them instead. A pass whose output reached Router as exactly one output event (PassOutputRelay saw a first output and no second) is buffered: its first-token time is unobservable, not missing.

- [x] Failing test: a pass with a single output event records output_buffered=true and first_token_seen=false; a streamed pass records output_buffered=false with its time to first token; a pass with no output event records neither as buffered
- [x] GenerationCallUsage carries the flag (public, documented beside timeToFirstToken / firstTokenSeen)
- [x] The generationCall transcript/journal event records it (TranscriptEvent, beside firstTokenSeen)
- [x] The generation span gets attribute generation.output_buffered (RouterTelemetry.AttributeKey, beside generation.first_token_seen)
- [x] Docs (GenerationCallUsage, RouterTelemetry, and ARCHITECTURE.md / session.md wherever first_token_seen is described) say time to first token is measured only on streamed passes, and buffered passes are excluded by design

## Review Findings (2026-10-23 04:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 12 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:261` `completeness/invariant-propagation` — The new test verifies round-trip encoding/decoding with `outputBuffered: true`, but does not test the backward-compatibility case when this field is absent from JSON. The established pattern in this test file (as shown by `lineWithoutAgentSpawnKeyDecodesAsNil` at line 277) is to test both the happy path (field present) and the default case (field absent). This gap means the default decoding behavior for missing `outputBuffered` is untested, mirroring the omission pattern for other optional fields. Add a test (e.g., `generationCallWithoutOutputBufferedKeyDecodesWithDefault`) that creates a generationCall event JSON without the `outputBuffered` field and verifies it decodes with the expected default value, matching the pattern established for `agentSpawn` and other optional fields in the same test class.