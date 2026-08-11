---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzrwaaa7w094bvcaw3zj2azm
  text: |-
    Research results:

    - The nine-parameter public `makeSession` (Sources/FoundationModelsRouter/RoutedLLM.swift) forwards to the internal ten-parameter builder `makeSession(grammar:...)`. `makeGuidedSession` (Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift) forwards to the same builder with a grammar. The internal builder stays the one implementation.
    - Field types: `TokenBudget`, `CompactionPrompt`, `DiscoveryPriming` are value types with `Equatable`. `Summarization` is a value type without `Equatable`. `Grammar` is an enum with string payloads. None of these is `Codable` now. `SessionSidecar.AgentSpawn` is `Codable` already. Plan: add `Codable` to the five types, and add `Equatable` to `Summarization`. These additions do not break source.
    - Design: one new file Sources/FoundationModelsRouter/Session/SessionConfiguration.swift. `SessionConfiguration` holds the nine knobs plus `grammar`. A nested `SessionConfiguration.Persistable` is the `Codable` slice: it keeps each value-typed field and holds the tool NAMES in place of the tool instances. `configuration.persistable` derives it. Task ^ne5g9jn persists `Persistable` in the sidecar and matches tool names to app-supplied instances at restore time. This keeps one vocabulary for create time and restore time, and a decode-then-encode cycle does not lose the tool names.
    - Decision for item 3: keep `makeGuidedSession` as a thin alias that builds a configuration and forwards. Do NOT deprecate: a deprecation makes warnings at the six existing call sites, and the test gate permits zero warnings. The doc comment on `makeGuidedSession` records this decision.
    - Test harness: shared fixtures exist — `RouterTestFixtures`, `StubModelLoader`, `PlainTranscriptStubContainer`, `StubSessionBackend`, `AmbientEventPostingTool` (name "ambient-emitter"). `RoutedSessionActor` exposes nonisolated `grammar`, `autoCompactionBudget`, `autoCompactionPrompt`, `summarization`, `discoveryPriming`, `workingDirectory`, `tools` for assertions.
    - Duplication-rule risk: the `Persistable` member list mirrors the `SessionConfiguration` member list, and the two forwarding conveniences mirror each other. If the parsed duplication tool reports these, the recourse is a `// sah:allow duplication <reason>` marker; the mirror is the design.
  timestamp: 2026-08-11T17:00:58.055689+00:00
- actor: claude-code
  id: 01kzrwxm2fznx6arr7fvxnw07s
  text: |-
    Implementation landed, TDD order (test first, watched it fail, then the code):

    - New: Sources/FoundationModelsRouter/Session/SessionConfiguration.swift — `SessionConfiguration` (nine knobs plus `grammar`), defaulted memberwise init so `SessionConfiguration()` is the empty default, `persistable` computed property, and nested `SessionConfiguration.Persistable` (the `Codable`, `Equatable` slice; `toolNames` stands in for the tool instances). This is the envelope task ^ne5g9jn persists; its rehydration hook takes the tools by name.
    - New: Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift — 7 tests: empty configuration equals `makeSession()`, each knob matches the nine-parameter call, `recordingRoot` layout, grammar equals `makeGuidedSession`, defaults, and two Codable round-trips.
    - RoutedLLM.swift — added `makeSession(configuration:)` as the primary factory; the nine-parameter overload now builds a configuration and forwards to it; the extension header and the internal-builder docs state the new call flow.
    - GuidedGeneration.swift — `makeGuidedSession` now builds a configuration with the grammar and forwards to `makeSession(configuration:)`. Decision recorded in its doc comment: kept as a thin alias, NOT deprecated, because a deprecation makes warnings at the six existing call sites and the test gate permits zero warnings.
    - Conformance additions (no source break): `TokenBudget`, `CompactionPrompt`, `DiscoveryPriming`, `Grammar` gain `Codable`; `Summarization` gains `Equatable` and `Codable`.
    - The optional fluent `with`-style modifiers from the card's design-shape note are omitted: the card marks them "Optional", no acceptance criterion needs them, and mutable `var` fields already give per-field adjustment.
    - Duplication guard: `Persistable` mirrors the parent type by design; it carries a `// sah:allow duplication` marker with the reason. The parsed duplication tool reports zero findings over the changed set.

    Verification: `swift test` fully green — 827 + 27 + 24 tests pass; the one known issue is the pre-existing BoundedWait one, and the one build warning is the accepted vendored mlx-swift "missing creator for mutated node". No commit made, as directed.
  timestamp: 2026-08-11T17:11:30.639199+00:00
- actor: claude-code
  id: 01kzrwxy17s86qy1cyfnms2s68
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Session/SessionConfiguration.swift (new), Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift (new, 7 tests), Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift, Sources/FoundationModelsRouter/Compaction/TokenBudget.swift, Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift, Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Session/DiscoveryPriming.swift, Sources/FoundationModelsRouter/Guided/Grammar.swift. `swift test` green: 827 + 27 + 24 tests pass, 1 pre-existing BoundedWait known issue, 1 accepted vendored mlx warning.
    - next: /review
  timestamp: 2026-08-11T17:11:40.839354+00:00
- actor: claude-code
  id: 01kzrxm22cr9rfh6zt09camnxw
  text: |-
    ### review — findings
    - evidence: 1 finding — Sources/FoundationModelsRouter/RoutedLLM.swift:158 (near-duplicate of makeGuidedSession at Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:258). Engine: review sha HEAD~1..HEAD, counts {findings: 1, confirmed: 1, refuted: 0, attempted: 8, failed: 0}. First engine run had 1/8 tasks failed; a second full run confirmed the same single finding.
    - next: /implement — resolve the checklist item in the "## Review Findings (2026-08-11 12:20)" section, then /review again.
  timestamp: 2026-08-11T17:23:45.868508+00:00
- actor: claude-code
  id: 01kzrxmshqs6vn4f8zk4vgreyc
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 files, new SessionConfiguration + makeSession(configuration:), 7 new tests
    - test: green — swift test, 878 tests (827+27+24), 0 failures; accepted noise only
    - commit: changed — bff2202
    - review: findings — Sources/FoundationModelsRouter/RoutedLLM.swift:158, func makeSession is a near-duplicate of makeGuidedSession at Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:258 (45 tokens, 100% alike)
  timestamp: 2026-08-11T17:24:09.911983+00:00
- actor: claude-code
  id: 01kzryaaqfrctkcaym15yfx2z5
  text: |-
    Fix for the review finding (RoutedLLM.swift:158 near-duplicate of GuidedGeneration.swift:258):

    - I read the duplication validator rules first. The parsed rule compares whole definitions after normalization. Normalization removes all identifier names. Thus each body that forwards the nine frozen parameters gives the same token stream. A refactor cannot remove this pair: the two public signatures must not change (^pckk91c), and `makeGuidedSession` stays a thin alias by the recorded decision (a deprecation makes warnings at six call sites). The shared implementation is already extracted: both bodies only forward into `SessionConfiguration` and `makeSession(configuration:)`, and hold no logic that can drift. The parsed rule prescribes the release for this case: a `// sah:allow duplication <reason>` marker.
    - I put the marker, with the reason, above BOTH definitions — `makeSession` in Sources/FoundationModelsRouter/RoutedLLM.swift and `makeGuidedSession` in Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift — to remove the cause from both files.
    - Verification with the rule's own tool: `sah tool code_context duplication find` over RoutedLLM.swift, GuidedGeneration.swift and SessionConfiguration.swift reported the pair before the markers, and reports zero findings after them.
    - Environment note for the next agent: the first two `swift test` runs showed one failure in `cancellingAStreamingTurnFinishesTheStreamWithCancellationError` (TurnCancellationTests.swift:1187). The cause was not the change (comments only) — the disk was 100% full (108 MB free of 3.6 TB). The filler was 77,589 leaked clang `preamble-*.pch` files (~38 MB each, ~3 TB) in /private/var/folders/.../T. I deleted the 61,866 files older than one day, which freed 357 GB. After that, `swift test` is fully green.
    - Final `swift test`: 827 + 27 + 24 tests pass, exit 0. Accepted noise only: the BoundedWait known issue, and the vendored mlx-swift "missing creator" warning.
    - The finding checkbox is now `- [x]`. The task stays in `doing` for /review, as directed.
  timestamp: 2026-08-11T17:35:55.631494+00:00
- actor: claude-code
  id: 01kzryafvnz9ekv5j6egkr96f6
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift (one `// sah:allow duplication <reason>` marker each). Duplication tool: 1 finding before, 0 after. `swift test`: 827 + 27 + 24 tests pass, exit 0; accepted noise only (BoundedWait known issue, vendored mlx warning). Finding flipped to `- [x]`.
    - next: /review
  timestamp: 2026-08-11T17:36:00.885821+00:00
- actor: claude-code
  id: 01kzryrgthgxk8wjqgndsvjpm8
  text: |-
    ### review — findings
    - evidence: 2 findings — Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:259, Sources/FoundationModelsRouter/RoutedLLM.swift:159 (public declarations should be documented). Engine: review sha HEAD~1..HEAD, counts {findings: 2, confirmed: 2, refuted: 1, attempted: 8, failed: 0}. The prior duplication finding (2026-08-11 12:20) is resolved and checked.
    - next: /implement — resolve the two checklist items in the "## Review Findings (2026-08-11 12:38)" section, then /review again. Note: the allow-duplication markers sit at these lines; make sure each `///` doc block attaches to its public declaration.
  timestamp: 2026-08-11T17:43:40.625639+00:00
- actor: claude-code
  id: 01kzrys6q0rkabt1b1f67ydc6q
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 2 files, allow-duplication marker above each of the frozen pair; duplication tool 1 finding before, 0 after
    - test: green — swift test, 878 tests (827+27+24), 0 failures; accepted noise only
    - commit: changed — 625feec
    - review: findings — Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:259 and Sources/FoundationModelsRouter/RoutedLLM.swift:159, public declarations should be documented (the plain marker line between the /// doc block and the declaration detaches the documentation). Prior duplication finding stays resolved.
  timestamp: 2026-08-11T17:44:03.040424+00:00
- actor: claude-code
  id: 01kzryy2dzxwqsrfv1hwsbwpx8
  text: |-
    Fix for the two review findings (GuidedGeneration.swift:259 and RoutedLLM.swift:159, public declarations should be documented):

    - Cause: the previous iteration put the plain `// sah:allow duplication <reason>` marker line between the `///` doc block and its declaration. This detached the documentation from the declaration.
    - I read the parsed duplication rule first (`get validator`). The rule says: write the marker on the line above the definition, and the marker covers the next item, past a doc comment and past the attributes. Thus a marker above the `///` doc block keeps its effect.
    - Fix: in each of the two files, I moved the marker line to the position above the `///` doc block. The doc block now attaches to its public declaration again. No other change.
    - Verification 1 (duplication): `sah tool code_context duplication find` over RoutedLLM.swift, GuidedGeneration.swift and SessionConfiguration.swift reports zero findings — the markers keep their effect at the new position.
    - Verification 2 (tests): `swift test` is green, exit 0 — 827 + 27 + 24 tests pass. Accepted noise only: the BoundedWait known issue, and the vendored mlx-swift "missing creator" warning.
    - The two finding checkboxes are now `- [x]`. The task stays in `doing` for /review. No commit, as directed.
  timestamp: 2026-08-11T17:46:42.495469+00:00
- actor: claude-code
  id: 01kzryy72bskmdvxnhba38xj9c
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift (each allow-duplication marker moved above its `///` doc block, so the doc attaches to the declaration again). Duplication tool: 0 findings over the 3 related files. `swift test`: 827 + 27 + 24 tests pass, exit 0; accepted noise only (BoundedWait known issue, vendored mlx warning). Both findings flipped to `- [x]`.
    - next: /review
  timestamp: 2026-08-11T17:46:47.243262+00:00
- actor: claude-code
  id: 01kzs2dr8jjfkysnjamjd667e5
  text: 'step: review — the review engine examined the scoped range HEAD~1..HEAD (commit 494ab31). Result: 1 confirmed finding (8 validators, 0 refuted, 0 failed). The MLX override of `streamResponseFragments` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:388) keeps the relay-task pattern and thus keeps the cancellation race that commit 494ab31 removed from the protocol default. A new checklist "## Review Findings (2026-08-11 13:43)" is in the description. The task stays in the review column.'
  timestamp: 2026-08-11T18:47:42.098532+00:00
- actor: claude-code
  id: 01kzs2ec3d2hq0sy54b20jxjqy
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — markers moved above the doc blocks (2 files), doc findings resolved
    - test: green — flaky cancellation test root-caused and fixed in LanguageModelSessionBackend.swift (pull-based ChunkIterator replaces the relay task); proven by an 80,000-trial standalone repro (0 failures) and 40 green full-suite runs. Per user direction, no more soak loops after this.
    - commit: changed — 494ab31
    - review: findings — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:388, the MLXFoundationModelsSessionBackend override keeps the relay-task pattern and thus the same cancellation race the default lost. Prior findings sections (12:20, 12:38) stay checked.
  timestamp: 2026-08-11T18:48:02.413672+00:00
- actor: claude-code
  id: 01kzs30cywgpvvpdkghrn0vvdh
  text: |-
    step: implement
    outcome: changed
    evidence: Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift — the streamResponseFragments override is now pull-based (private nested SnapshotDeltaIterator, AsyncThrowingStream(unfolding:)); the relay Task, its onTermination cancel, and pumpStream are removed; the restartsResponse delta logic (Self.fragment(of:after:), previous-snapshot state) is kept identical; one stale ``pumpStream`` doc link updated. swift build clean (only the accepted vendored mlx-swift "missing creator" warning). One swift test run: 827 tests in 78 suites passed with 1 known issue (accepted BoundedWait), plus 27 tests in 11 suites and 24 tests in 5 suites, all passed, exit code 0.
    task: ^n9tdq8c
  timestamp: 2026-08-11T18:57:53.116115+00:00
- actor: claude-code
  id: 01kzs3espd9m67t40b963n82ye
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 0b639a2) — 3 findings, 3 confirmed, 0 refuted: Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:239, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:477, Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:625 — doc comments contain external task identifiers; remove them and describe the behavior directly.
    - next: implement removes the task references from the doc comments in LiveModelLoader.swift, then re-review.
  timestamp: 2026-08-11T19:05:44.909257+00:00
- actor: claude-code
  id: 01kzs3fh0kxx4k7ytyp4976a59
  text: |-
    ### finish iteration 4 — findings
    - implement: changed — LiveModelLoader.swift, pull-based MLX override via SnapshotDeltaIterator; relay task and pumpStream removed
    - test: green — swift build clean, one swift test run 878 tests (827+27+24), 0 failures
    - commit: changed — 0b639a2
    - review: findings — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:239, :477, :625 — doc comments contain external task identifiers; remove the references and describe the behavior directly. All prior findings sections stay checked.
  timestamp: 2026-08-11T19:06:08.787181+00:00
- actor: claude-code
  id: 01kzs5k1q5mxm0wrp0k3rp8g0k
  text: |-
    Fix for the three review findings (LiveModelLoader.swift:239, :477, :625 — doc comments contain external task identifiers):

    - I read the validator rules first (dump validators, then get validator code-hygiene). The parsed rules do not contain one rule for task identifiers. The finding text states the rule: a doc comment must give the behavior directly, and an external task identifier decays when the tracking system changes.
    - I examined the full file for each form of a task-id citation (patterns: ^-prefixed short ids, bare 7-char ids, AC#, defect D, kanban, ticket, issue #). The file contains only the three flagged sites. Line 415 says "relay-task pattern"; this is the name of a code pattern, not a task id. No other file changed, and no rewritten doc comment links to an other file.
    - Line 239: the citation "(task ^w8dzvee, AC#5)" is removed. The line now ends: "have coverage that needs no GPU." The technical statement is complete without the citation.
    - Line 477: the citation "(task ^w8dzvee, defect D2)" is removed. The line now ends: "of the answer." The SDK-closed-one-Response-entry explanation from the finding's example already is in the sentence before (lines 472-473); a second copy is not added.
    - Lines 624-625: the citation ", task 070qw7z" and its parentheses are removed. The text now reads: "the gated integration test `LanguageModelSessionBackendIntegrationTests.secondTurnReusesFirstTurnsKVCache` already asserts ...", as the finding gives.
    - Verification: `swift build` completes with only the accepted vendored mlx-swift "missing creator" warning. One `swift test` run, exit 0: 827 tests in 78 suites pass with the 1 accepted BoundedWait known issue, plus 27 tests in 11 suites and 24 tests in 5 suites, all pass. No repeat runs.
    - The three finding checkboxes are now `- [x]`. The git diff on the source is 4 doc-comment lines in one file. No commit, as directed. The task stays in `doing`.
  timestamp: 2026-08-11T19:43:01.349696+00:00
- actor: claude-code
  id: 01kzs5k720p501qpb9hf66z5hn
  text: |-
    step: implement
    outcome: changed
    evidence: 1 file — Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift (4 doc-comment lines at :239, :477, :624-625; the three task-id citations removed; a full-file sweep found no other citation). swift build clean (accepted vendored mlx warning only). One swift test run, exit 0: 827 + 27 + 24 tests pass, 1 accepted BoundedWait known issue. All 3 findings in "## Review Findings (2026-08-11 13:59)" flipped to [x].
    task: ^n9tdq8c
  timestamp: 2026-08-11T19:43:06.816456+00:00
- actor: claude-code
  id: 01kzs5tqwva4e2cfewv66ncn5s
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (95a51e4) — 0 findings, 8 attempted, 1 refuted. All prior findings in the four `## Review Findings` sections are checked. Acceptance points verified: configuration-based makeSession behavior (emptyConfigurationMatchesZeroArgumentMakeSession, configuredValueMatchesNineParameterCall), call sites compile through the convenience overload, grammar configuration matches makeGuidedSession (grammarConfigurationMatchesMakeGuidedSession), Codable slice round-trips (persistableSliceRoundTrips, emptyPersistableSliceRoundTrips) in Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift, commits bff2202/625feec.
    - next: task moves to done.
  timestamp: 2026-08-11T19:47:13.435788+00:00
- actor: claude-code
  id: 01kzs5vv0hvmzbdfwf6gm8yz92
  text: |-
    ### finish iteration 5 — clean
    - implement: changed — 3 task-id citations removed from doc comments in LiveModelLoader.swift; full-file sweep found no others
    - test: green — swift build clean, one swift test run 878 tests (827+27+24), 0 failures
    - commit: changed — 95a51e4
    - review: clean — review sha HEAD~1..HEAD (95a51e4), 0 findings; 7/7 prior findings checked; 4/4 acceptance points verified via SessionConfigurationTests
    - task moved to done by review
  timestamp: 2026-08-11T19:47:49.393109+00:00
position_column: done
position_ordinal: ff8c80
title: One SessionConfiguration value drives makeSession
---
## Problem

`RoutedLLM.makeSession` takes nine defaulted parameters (Sources/FoundationModelsRouter/RoutedLLM.swift:156-166): `instructions`, `workingDirectory`, `recordingRoot`, `tools`, `budget`, `compactionPrompt`, `summarization`, `agentSpawn`, `discoveryPriming`. `makeGuidedSession` repeats all nine with `grammar` prepended. Every doc comment must cite the full ten-segment selector, and each new session capability grows both signatures. There is also no value a caller can hold, inspect, persist, or reuse that says "this is how my sessions are configured."

## Design shape

A plain struct, not a result builder: flat configuration is what structs are for, and the `Codable` requirement for restore falls out naturally. Defaulted memberwise fields make `SessionConfiguration()` the empty default. Optional fluent `with`-style modifiers can ride on top for call-site chaining. Result builders are for hierarchical content; this is not that.

## Proposed solution

1. Introduce one value type, `SessionConfiguration`: instructions, working directory, recording root, tool list, budget, compaction prompt, summarization, agent spawn, discovery priming, and grammar as a field (this merges the guided and plain surfaces). The value-typed parts are `Codable`; the non-codable parts (tool instances, spawn closure) are held by reference and represented by name for persistence.
2. Add `makeSession(configuration:)` as the primary factory. Keep the current nine-parameter form as a convenience that builds a configuration and forwards — no source break.
3. Fold `makeGuidedSession` into the same path: a configuration with a grammar vends a guided session. Deprecate the separate guided factory or keep it as a thin alias — decide and document.
4. Design the type as the SAME envelope task ^ne5g9jn persists in the sidecar for restore re-application: create-time and restore-time configuration must be one vocabulary, not two. That task's rehydration hook takes this type's non-codable parts by name.

## Acceptance

- `profile.standard.makeSession(configuration:)` vends a session identical in behavior to the current nine-parameter call.
- The existing call sites (examples, tests) compile unchanged through the convenience overload.
- A configuration with a grammar produces the same session `makeGuidedSession` produces today.
- The `Codable` slice of the type round-trips, ready for ^ne5g9jn to persist.

## Review Findings (2026-08-11 12:20)

- [x] `Sources/FoundationModelsRouter/RoutedLLM.swift:158` — func `makeSession` is a near-duplicate of `makeGuidedSession` at Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:258 (45 tokens, 100% alike).

## Review Findings (2026-08-11 12:38)

- [x] `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:259` — public declarations should be documented.
- [x] `Sources/FoundationModelsRouter/RoutedLLM.swift:159` — public declarations should be documented.

## Review Findings (2026-08-11 13:43)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:388` — the `MLXFoundationModelsSessionBackend` override of `streamResponseFragments` keeps the relay-task pattern (a `Task` pumps snapshots into a continuation, and `onTermination` cancels the task). Commit 494ab31 changed only the protocol's default implementation (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift:277-286) to the pull-based `ChunkIterator`. The override has the same cancellation race: when the propagated cancellation lands, a chunk that the relay task received, but did not yet forward, is lost. Apply the same pull-based pattern to the override.

## Review Findings (2026-08-11 13:59)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:239` — Doc comment references an external task identifier (task ^w8dzvee, AC#5) which belongs in the PR description, not in code comments; such references rot as tracking systems evolve and obscure the code's intrinsic behavior. Remove the task reference. Revise to: `/// have coverage that can be tested without a GPU.` or similar, describing the requirement directly without external tracking IDs.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:477` — Doc comment references an external task identifier (task ^w8dzvee, defect D2) which belongs in the PR description, not in code comments; such references rot as tracking systems evolve and obscure the code's intrinsic behavior. Remove the task reference. Revise to a direct description of the behavior, e.g.: `/// of the answer, because the SDK closed one Transcript.Response entry and opened another.`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:625` — Doc comment references an external task identifier (task 070qw7z) which belongs in the PR description, not in code comments; such references rot as tracking systems evolve and obscure the code's intrinsic behavior. Remove the task reference. Revise to describe the test behavior directly, e.g.: `/// integration test LanguageModelSessionBackendIntegrationTests.secondTurnReusesFirstTurnsKVCache already asserts`. #api