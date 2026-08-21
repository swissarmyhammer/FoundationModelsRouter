---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
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

## Acceptance Criteria

- [ ] A decision is written down: which lost kind of fact the seven must carry, or why none is carried
- [ ] One fixture that stays carries the chosen kind, with every field value unchanged
- [ ] `compactionEvalMeasuredBytesPerToken` is measured again over the new corpus by the method its doc states, and the doc states the new corpus figures
- [ ] Each value derived from that constant is derived again with it
- [ ] A bar holds the chosen kind, and it goes red if the fixture loses it
- [ ] The subset still holds seven seeds, and `CompactionEvalTierBarTests` stays green
- [ ] A plain `swift test` at the root stays green
#compaction #eval #test-debt