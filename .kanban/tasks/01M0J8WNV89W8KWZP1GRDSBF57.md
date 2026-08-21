---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0k615kvy7zxvgaw5xqct5k2
  text: |-
    ### implement — picked up, research done

    Decision (from the orchestrator, recorded here as the card asks): the seven must carry a RULE on the assistant's own later answers. The rule is a fact about the user as a person, in a domain that is not software. One edit restores three of the four lost kinds: rule, fact about the user, non-software domain.

    Fixture chosen: `env-file`. It is a one-fact head, probed by text (not tool), recency window 4, probed index 0. So the rule IS the probed fact. The card forbids `budget-cap-tool-and-owner` and `three-facts-support-escalation` (card ^ghkxf3r changes those next). The fixture id changes to `sesame-allergy`, because a fixture named for an env file that plants an allergy would mislead; the id is not one of the four fields the card holds fixed.

    Method of measurement validated against the CURRENT corpus: a python script over `CompactionEvalDataset.swift` (Swift multi-line literal rules applied, each piece encoded alone with `add_special_tokens=False`, `tokenizers` from the local Hub cache of `Muse-Glimmer-30B-4bit`, `Llama-3.2-1B-Instruct-4bit`, `Qwen2.5-3B-Instruct-4bit`). It gives 41 pieces, 9946 bytes, 2052 / 2061 / 2069 tokens — the table in the doc exactly. The script is in the session scratchpad.

    Plan for the bar: the dataset has no field for the kind of the probed fact. A typed marker `probedFactKind` (enum `CompactionEvalProbedFactKind`: `.verbatimValue`, `.ruleOnLaterAnswers`) goes on `CompactionEvalFixtureSpec`. The new bar in `CompactionEvalRepresentativeSubsetTests` asks for at least one subset fixture with `.ruleOnLaterAnswers`. TDD: the marker lands first with every fixture at `.verbatimValue`, the bar goes red, then the rewrite makes it green.
  timestamp: 2026-08-21T22:10:59.323631+00:00
- actor: claude-code
  id: 01m0k6dk77nrz153rts9bsg372
  text: |-
    ### implement — changed
    - evidence: fixture `env-file` rewritten as `sesame-allergy`; probed fact "I have a severe allergy to sesame, so never put it — the seeds, the oil or tahini — into any recipe or menu you give me."; key phrase `sesame`; `facts.count` 1, `probedFactIndex` 0, `probedFactViaTool` false, `recentTurnCount` 4 unchanged. New typed marker `CompactionEvalProbedFactKind` (`.verbatimValue`, `.ruleOnLaterAnswers`) on `CompactionEvalFixtureSpec.probedFactKind`; new bar `CompactionEvalRepresentativeSubsetTests.subsetProbesARuleOnLaterAnswers`, watched red (all seven `.verbatimValue`) then green. Corpus: 41 pieces, 9946 bytes, 2052 / 2061 / 2069 tokens before (method validated, matches the doc) → 41 pieces, 9824 bytes, 2055 / 2066 / 2074 tokens after, 4.781 / 4.755 / 4.737 bytes for each token; `compactionEvalMeasuredBytesPerToken` 4.85 → 4.79. Re-derived: 128-token summary 621 → 614 bytes (20% over the flat estimate, was 21%); worst-case summary 156 → 154 estimated tokens; required span 234 → 231 (924 bytes); content overrun figure 828 → 819 bytes; tightest seed now `sesame-allergy` at 328 span tokens, 2.13 over the worst case (was `db-port`, 345, 2.21); the `0.25 * 4.85 / 4.0` note → 4.79; the `AutoCompactionTriggerIntegrationTests` comment's dataset-measured rate → 4.79. Files: Tests/FoundationModelsRouterEvalSupport/CompactionEvalDataset.swift, Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionEvalRealSubjectRunner.swift (comment), IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift (comment). Root `swift test`: 1032 tests in 98 suites passed (2 known issues, older than this change) and 81 tests in 10 suites passed; `CompactionEvalTierBarTests` green; subset holds seven seeds. The gated tier was NOT run; no floor moved; no fixture added.
    - next: /review. The batch's own gated run measures the new prose; a red there is a measurement for a card of its own.
  timestamp: 2026-08-21T22:17:46.471680+00:00
position_column: doing
position_ordinal: '80'
title: The compaction eval now plants only machine-shaped facts about software — an allergy, a person's name, a date and a safety rule are no longer measured
---
Found by the review of commit `134342a` (task ^k0d30s4). It is a statement of span, not a defect of that commit. Card ^ghkxf3r holds the STRUCTURAL half of the same finding; this card holds the fact-shape half.

## What happened

Task ^k0d30s4 cut `compactionEvalFixtureSpecs` from 24 fixtures to 7. The user chose to make the test smaller, and the cut was a pure deletion: the seven that stay are byte-for-byte the fixtures they were.

Each FIELD the dataset varies is still fully spanned, and each structural extreme — the longest context, the largest head, the largest recency window, the deepest burial — is a fixture that stays. So the eval is not easier.

What went is the SHAPE of the planted fact. That is not a field, so no bar reads it.

## The gap

**Almost every answer is now a machine-shaped string.** The seven probed answers are `.env.example`, `6543`, `eu-west-2`, `4,200`, `AES-256-GCM`, `WX-ARCHIVE-6` and `2 hours`. Six are identifiers, slugs or numbers, and the seventh is a duration.

Ten of the seventeen fixtures that went probed ORDINARY ENGLISH: `tabs`, `shellfish`, `Longbow`, `Priya`, `Riverside`, `router`, `coconut oil`, `supply closet`, `second week`, `platform team`.

The two shapes measure different things:

- An opaque identifier can only be carried word for word. It measures whether the summary COPIED the fact.
- A common word can be guessed from the prose around it. It measures whether the model really KEPT the fact, or only wrote a plausible one. A summary that drops `coconut oil` and answers "olive oil" is wrong in a way that a summary which drops `AES-256-GCM` cannot be, because no model guesses an algorithm name.

The seven measure copying almost alone.

**Four kinds of fact now have ZERO fixtures:**

| kind of fact | the only fixtures that had it | all deleted |
|---|---|---|
| a person's name as the answer | `meeting-time-and-reviewer` (`Priya`) | yes |
| a date or a clock time as the answer | `pet-name-and-vet`, `meeting-time-and-reviewer` | yes |
| a fact about the USER as a person | `allergy`, `flight-number`, `pet-name-and-vet`, `travel-itinerary-hotel`, `recipe-substitution-and-timing` | yes |
| a fact that is a RULE on the assistant's own later answers | `allergy` | yes |

`Marcus` and `Dana` are inside the facts of fixtures that stay, but neither is ever the probed phrase.

**The last row is the sharpest one.** The `allergy` fixture planted a rule: the user must never be given a recipe that holds shellfish. A fold that loses a port number gives a wrong answer. A fold that loses that rule does HARM. No fixture that stays has that shape, so the eval no longer measures whether compaction can drop a constraint on the assistant's own output.

**Subject matter is now one domain.** The seven are config, infrastructure, cloud, finance operations, support operations, security and an archive brief — software work throughout. Cooking, travel, personal health, pets, gaming, office facilities, a calendar and onboarding all went. A summarizer tuned to software prose scores well on all seven, and this eval cannot tell.

## Why this is worth doing

The correction costs NO time. It does not add a seed, so the tier still runs seven samples, `compactionEvalSubsetTimeLimitMinutes` stays at 2, and the measured 89.0 s does not move. The work is to re-write the prose of a fixture that stays, not to add one.

## Work

Decide first, then do. The user chose a smaller test, so this card must NOT grow the dataset.

1. Decide which of the four lost kinds the seven must carry. The rule on the assistant's own later answers is the strongest candidate, because its failure is a harm and not a miss.
2. Re-write the head of ONE fixture that stays to carry that kind. Keep its `facts.count`, its `probedFactIndex`, its `probedFactViaTool` and its `recentTurnCount` the same, so no bar of `CompactionEvalRepresentativeSubsetTests` and no derivation changes.
3. Re-measure `compactionEvalMeasuredBytesPerToken`. Any change to the prose changes the corpus. Its doc states the method: run the three tokenizers of the local Hub cache over the whole corpus, and keep the LARGEST rate, rounded up. Validate the method against the current corpus first — it must give 41 pieces, 9946 bytes and 2052, 2061, 2069 tokens.
4. Re-derive everything that reads it, as ^k0d30s4 did: the bytes for a 128-token summary, the worst-case summary tokens, the required span, and the content byte figure.
5. Add a bar that holds the chosen kind, so a later edit cannot lose it in silence.

## Care needed

Do NOT add a fixture. Eight seeds derive a bound of 2.14 minutes, which the limit of 2 does not cover, and `CompactionEvalTierBarTests` refuses it from the upper side.

Do NOT weaken a retention floor. Both are 0.71, and an English answer may be recalled at a different rate than an identifier. If the re-written fixture makes the tier red, that is a MEASUREMENT and it belongs on a card of its own. Do not move the floor to make the run green.

Do NOT run the gated tier to pick the new prose. Pick it, then let the batch's own gated run measure it.

## Decision

The seven must carry a RULE on the assistant's own later answers, stated as a fact about the user as a person, in a domain that is not software. One edit restores three of the four lost kinds. The fixture `env-file` became `sesame-allergy`: the probed fact is a severe allergy to sesame, and the probed phrase is `sesame`. The kind is a typed marker on the fixture spec, `CompactionEvalFixtureSpec/probedFactKind` (`CompactionEvalProbedFactKind`), and the bar `subsetProbesARuleOnLaterAnswers` holds it.

## Acceptance Criteria

- [x] A decision is written down: which lost kind of fact the seven must carry, or why none is carried
- [x] One fixture that stays carries the chosen kind, with every field value unchanged
- [x] `compactionEvalMeasuredBytesPerToken` is measured again over the new corpus by the method its doc states, and the doc states the new corpus figures
- [x] Each value derived from that constant is derived again with it
- [x] A bar holds the chosen kind, and it goes red if the fixture loses it
- [x] The subset still holds seven seeds, and `CompactionEvalTierBarTests` stays green
- [x] A plain `swift test` at the root stays green #compaction #eval #test-debt