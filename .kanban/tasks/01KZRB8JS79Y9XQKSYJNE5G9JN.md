---
assignees:
- claude-code
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: todo
position_ordinal: 9c80
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
- Old sidecars without the envelope keep restoring with today's behavior (additive schema rule). #transcript