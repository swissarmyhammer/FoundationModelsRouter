---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzt2pfw8wkxhzh5cw8nsappt
  text: |-
    Research complete. Design decisions:

    1. The envelope reuses `SessionConfiguration.Persistable` (task ^9tdq8c made it for this card). A new optional field `configuration` goes on `SessionSidecar`. Old sidecars have no key and decode as nil.
    2. Schema decision: the envelope is additive inside schema v2. An optional field does not change how old readers or old recordings work. No v3 registry entry is necessary. I will add a note to the `RecordingSchemaVersion` registry docs.
    3. `RoutedSessionActor.init` builds the envelope from its own parameters and writes it through `writeSidecarIfNew`. Root sessions and forks both get correct envelopes from this one path. A restored session writes no sidecar, so the restored origin ignores it.
    4. Summarizer hook: the code base does not keep a summarizer on a session. Auto-compaction selects its summarizer at fold time (flash slot first, then the session's own model, then the deterministic stages). Thus a restored budget applies with no summarizer supply. The acceptance condition "given the app supplied a summarizer" is satisfied in a stronger form.
    5. Agent-spawn hook: `agentSpawn` is a Codable value (`SessionSidecar.AgentSpawn`), not a closure. It folds into the envelope per card item 4. No hook is necessary.
    6. Rehydration hook: the existing `tools:` parameter on `restoreSessionTree` supplies the tool instances. The restore matches each node's recorded tool names against the supplied tool names. Tool mounting stays uniform across the tree (the documented contract of `tools:` does not change).
    7. Strictness decision: the recommended option. Missing parts produce a typed report (`missingTools`, one row per session and tool name) on `RestoredSessionTree`. No error option.
    8. Budget re-application also wires `toolOutputLimit` capping at the restore site, so a restored budget caps tool outputs the same way `makeSession` does.
  timestamp: 2026-08-12T04:11:42.856432+00:00
- actor: claude-code
  id: 01kzt5gbbjnxjx5b99qy897jfh
  text: |-
    Implementation complete, TDD (RED first, then GREEN). What changed:

    1. `SessionSidecar` got the optional field `configuration: SessionConfiguration.Persistable?`. New sidecars for roots and forks record it. Old sidecars have no key and decode as nil. The field travels through `withCompactionCount`, the writer, and `writeSidecarIfNew`. Schema stays at v2 (additive rule); the `RecordingSchemaVersion` v2 registry entry documents the decision.
    2. `RoutedSessionActor.init` assembles the envelope from its own effective values through `SessionConfiguration(...).persistable`, so a root and a fork record what they run with. A new `recordingRoot` parameter (default nil) travels only into the envelope; `makeSession` supplies it.
    3. `restoreSessionTree` re-applies each node's envelope: `autoCompactionBudget`, `autoCompactionPrompt`, `summarization`, and `discoveryPriming` come back as recorded, and a recorded budget re-wires `toolOutputLimit` capping into the node's tool chain (the restore site was `cappedToTokenLimit: nil` before).
    4. New public type `SessionConfigurationRestorationReport` with `missingTools` (session id + tool name rows) and `isComplete`. `RestoredSessionTree` carries it as `configurationReport`. The restore matches each node's recorded tool names against the supplied `tools` and reports every miss. No API break: the `restoreSessionTree` signature is unchanged, and the report rides the result.
    5. The stale "loss list" doc on `restoreSessionTree` is now the re-application story.

    Tests (in SessionTreeRestorationTests.swift, watched RED first as compile failures on the new API):
    - restoredTreeReappliesRecordedConfiguration — budget, prompt, summarization, and priming come back on the root and on a fork; empty report.
    - restoreReportsRecordedToolsTheCallerDidNotSupply — the report names the session and the tool name.
    - preEnvelopeSidecarRestoresWithDefaultsAndEmptyReport — the configuration key is stripped from the sidecar JSON; restore gives today's defaults and an empty report.

    Verification: one full `swift test` run — 857 + 27 + 24 tests passed, 0 failures, 1 pre-existing BoundedWait known issue, only the accepted mlx-swift build warning.

    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Recording/SessionSidecar.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Recording/RecordingSchemaVersion.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift; swift test: 908 tests passed, 0 failures
    - next: /review
  timestamp: 2026-08-12T05:00:47.346753+00:00
- actor: claude-code
  id: 01kzt5yabp80gy4mx35ftp97jc
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; 2 findings confirmed — Sources/FoundationModelsRouter/Recording/SessionSidecar.swift:319 (force unwrap in non-test code), Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:18 (doc symbol link does not include the recordingRoot: parameter)
    - next: correct the two findings, then run the review again
  timestamp: 2026-08-12T05:08:25.078147+00:00
- actor: claude-code
  id: 01kzt5z6phfv0q3kna475qr5xc
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 code files
    - test: green — swift test, 857 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 3fe1db8
    - review: findings — Sources/FoundationModelsRouter/Recording/SessionSidecar.swift:319 (force unwrap in non-test code), Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:18 (doc symbol link does not include the new recordingRoot: parameter)
  timestamp: 2026-08-12T05:08:54.097015+00:00
- actor: claude-code
  id: 01kzt6nsmvw49t3wtxrsry5t7r
  text: |-
    Iteration 2: the two review findings are corrected.

    1. SessionSidecar.swift — the force unwrap on `sidecarDirectoryUserInfoKey` is removed. The key now comes from a closure with `guard let` and `preconditionFailure`, the same pattern the repo uses in RepoMetadata.swift for a fixed literal that cannot fail. Sweep result for the rule "no force unwrap in non-test code": the five non-test files this task touched (SessionSidecar.swift, SessionTreeRestoration.swift, RecordingSchemaVersion.swift, RoutedSessionActor.swift, RoutedLLM.swift) contain no other `!` force unwrap, no `try!`, and no `as!`.

    2. RoutedSessionActor.swift — the `RoutedSessionActor/init(...)` symbol link now ends with `agentSpawn:discoveryPriming:recordingRoot:`, which matches the declared parameter order. Sweep result for stale symbol links: no `makeSession` link in Sources omits `recordingRoot:` (the parameter sits between `workingDirectory:` and `tools:` in those symbols, and all 34 links carry it); `makeGuidedSession` has no `recordingRoot:` parameter, so its links are correct as written; the line-18 init link was the only stale one.

    Verification: `swift build` clean, then one `swift test` run — 857 + 27 + 24 tests passed, 0 failures, 1 known issue (the accepted BoundedWait), and only the accepted mlx-swift "missing creator" warning.

    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Recording/SessionSidecar.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift; swift test: 908 tests passed, 0 failures, 1 accepted known issue
    - next: /review
  timestamp: 2026-08-12T05:21:14.395494+00:00
- actor: claude-code
  id: 01kzt75gnevd98eacjwcp8jpfe
  text: |-
    ### review — findings
    - evidence: 1 finding — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:18 (scope: review sha HEAD~1..HEAD; counts: 1 confirmed, 8 refuted)
    - next: correct the open finding in the new "## Review Findings (2026-08-12 00:22)" section, then run the review again
  timestamp: 2026-08-12T05:29:49.486210+00:00
- actor: claude-code
  id: 01kzt7669rza57anfhcg0fh8tz
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 2 files, both prior findings fixed and the cause swept
    - test: green — swift test, 857 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: b9c4d7a
    - review: findings — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:18 (the `- Parameters:` block must list each parameter with nested entries, or be removed in favor of prose that points to the init documentation). This is a new finding, not a repeat: iteration 1 flagged the stale symbol link at the same location; this flags the block format.
  timestamp: 2026-08-12T05:30:11.640727+00:00
- actor: claude-code
  id: 01kzt7m3fvbbne771r6etmp2mq
  text: |-
    Iteration 3: the open finding is corrected.

    The validator rule (swift/documentation): one parameter uses an inline `- Parameter name:` entry; two or more parameters use a `- Parameters:` block with nested names. A `- Parameters:` marker followed by prose is not permitted. The fix uses option (2) from the finding: the `- Parameters:` marker on `makeRoutedSessionActor` is removed. Prose now says that each parameter agrees one-for-one with a parameter of the `RoutedSessionActor` initializer, with the full symbol link kept. The `- Returns:` entry stays because the result is not `Void`.

    Sweep result for the same cause across the five files this task touched (RoutedSessionActor.swift, SessionSidecar.swift, SessionTreeRestoration.swift, RoutedLLM.swift, RecordingSchemaVersion.swift): every other `- Parameters:` block has correct nested entries, and every inline `- Parameter name:` entry documents a one-parameter function with the internal name. The line-18 block was the only violation.

    Verification: `swift build` clean, then one `swift test` run — 857 + 27 + 24 tests passed, 0 failures, 1 known issue (the accepted BoundedWait), and only the accepted mlx-swift "missing creator" warning.

    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift; swift test: 908 tests passed, 0 failures, 1 accepted known issue
    - next: /review
  timestamp: 2026-08-12T05:37:47.515948+00:00
- actor: claude-code
  id: 01kzt81k046afn3vy785d25ky8
  text: |-
    ### review — findings
    - evidence: 1 confirmed finding on scope HEAD~1..HEAD (b58ff8a) — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:478
    - next: apply the finding. Give the initializer a `- Parameters:` block, or give a doc comment to each stored property that the doc comment points to.
  timestamp: 2026-08-12T05:45:09.380318+00:00
- actor: claude-code
  id: 01kzt827g1jrz0bw5853wk81bg
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — 1 file, the entry-less `- Parameters:` marker removed
    - test: green — swift test, 857 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: b58ff8a
    - review: findings — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:478 (the initializer doc points to stored properties, but profile, routerId, id, parentId, recordingDirectory, workingDirectory, and slot have no doc comments). Each round finds a different defect, so the stuck guardrail does not apply.
  timestamp: 2026-08-12T05:45:30.369253+00:00
- actor: claude-code
  id: 01kzt8h0njqc148pkm2d6zqdj2
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift. `swift build` completed. One `swift test` run: 857 + 27 + 24 tests passed, 0 failures, 1 known issue (BoundedWait, accepted).
    - fix: We used option 2 of the finding. We added doc comments to the six stored properties that had none: `profile`, `routerId`, `id`, `parentId`, `recordingDirectory`, `workingDirectory`. Each doc comment points to its `RoutedSession` protocol requirement. The claim in the initializer doc comment is now true. Note: `slot` and `originalTools` already had doc comments before this change.
    - sweep: We examined all 40 stored properties in the file. All other properties have doc comments. The one-for-one claim on `makeRoutedSessionActor` agrees with the initializer's 29 parameters. No other doc comment in the file makes a claim that its targets do not honor.
    - next: The task is ready for /review.
  timestamp: 2026-08-12T05:53:34.898834+00:00
- actor: claude-code
  id: 01kzt8q4mk29e1kbh2pk98mtnv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings, 8 validators attempted; all prior checklist items are checked
    - next: none — the task moved to done
  timestamp: 2026-08-12T05:56:55.571375+00:00
- actor: claude-code
  id: 01kzt8qvhvs5ztwgg0s2214kg7
  text: |-
    ### finish iteration 4 — clean
    - implement: changed — 1 file, six stored properties documented
    - test: green — swift test, 857 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: b53b8a8
    - review: clean — 0 findings, scope HEAD~1..HEAD; all 4 prior findings checked
    - result: the task is in done
  timestamp: 2026-08-12T05:57:19.035387+00:00
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
- 01KZREJ4MJ67R0RBFKKN9TDQ8C
position_column: done
position_ordinal: ff9280
title: Make restore configuration a re-application story, not a loss list
---
## Problem

A restored session silently loses its behavioral configuration: compaction budget and prompt, summarization config, discovery priming, `agentSpawn`, and its tools (Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:221-237 documents most of this). Each loss is individually documented, but together they mean every restored session behaves differently from the saved one until the caller re-configures it by hand — and no API tells the caller what to re-supply. Auto-compaction is the sharpest edge: a session saved WITH a budget restores WITHOUT one and will overflow where the original folded.

## Proposed solution

1. Add a `Codable` configuration envelope to the sidecar: the compaction budget, the compaction prompt, the summarization parameters that are value-typed, a priming on/off flag with its value-typed settings, and the declared tool NAMES (already effectively recorded in the instructions entry's tool definitions).
2. Add a rehydration hook to `restoreSessionTree`: the app supplies the non-codable parts — tool instances, a summarizer, an agent-spawn closure — keyed by the recorded names. The restore matches recorded names against supplied parts and reports what is missing.
3. Decide the strictness: missing parts produce a typed report on the result (recommended), or an option makes them an error. Either way the caller learns exactly what did not come back, instead of silence.
4. Coordinate with task ^xky3j8w: its item 1 (`agentSpawn`) folds into this envelope; the remaining ^xky3j8w items (context mismatch, deleted fork dir, corrupt checkpoint, torn JSONL) stay where they are.

## Acceptance

- A session saved with a budget restores with the same budget applied, given the app supplied a summarizer through the hook.
- The restore result names every recorded configuration item that could not be re-applied.
- Old sidecars without the envelope keep restoring with today's behavior (additive schema rule).

## Review Findings (2026-08-12 00:02)

- [x] `Sources/FoundationModelsRouter/Recording/SessionSidecar.swift:319` — Force unwrap (`!`) appears in non-test code—violates the rule that forbids force unwraps outside tests. Use `guard let` or `??` to safely handle the optional result, or if this is guaranteed to succeed at compile time, use a safe failable initializer pattern: `CodingUserInfoKey(rawValue: "SessionSidecar.sidecarDirectory") ?? CodingUserInfoKey(rawValue: "fallback")` or refactor to avoid the force unwrap.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:18` — Symbol link in doc comment is incomplete—missing the `recordingRoot:` parameter that was added to the init signature. Update the symbol link from `init(…:agentSpawn:discoveryPriming:)` to `init(…:agentSpawn:discoveryPriming:recordingRoot:)` to match the actual init signature.

## Review Findings (2026-08-12 00:22)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:18` — The `- Parameters:` documentation block should list each parameter with its name and description using nested entries, not reference another symbol with prose. Either (1) list each parameter explicitly with nested entries (e.g., `- profile: ...`, `- routerId: ...`), or (2) remove the `- Parameters:` block entirely and describe the relationship in prose without the parameter documentation marker. Since this function forwards all parameters unchanged to the init, option (2) might be cleaner: replace lines 18-19 with prose like `/// Each parameter corresponds one-to-one with a parameter of ``RoutedSessionActor/init(...)`` — see that initializer's documentation for details.`

## Review Findings (2026-08-12 00:39)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:478` — The initializer claims in its doc comment (lines 460–461) that 'Every parameter here is documented on the stored property it initializes, above', but several stored properties that correspond to initializer parameters lack doc comments themselves (profile, routerId, id, parentId, recordingDirectory, workingDirectory, slot). Per the documentation rule, parameters with 2+ count must be documented either via a `- Parameters:` block or each via a `- Parameter name:` entry; indirect documentation through undocumented properties does not satisfy this requirement. Add a formal `- Parameters:` block to the initializer documenting all 32 parameters, using internal parameter names per the documentation rule. Alternatively, add doc comments to each of the undocumented properties (profile, routerId, id, parentId, recordingDirectory, workingDirectory, slot, originalTools, etc.) so the claim in the doc comment becomes accurate. #transcript