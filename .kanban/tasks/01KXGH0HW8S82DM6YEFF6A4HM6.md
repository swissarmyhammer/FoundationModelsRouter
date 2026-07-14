---
position_column: todo
position_ordinal: '8580'
title: Optional ProfileDefinition.context; native max context from repo metadata
---
## What
Make context derivable instead of caller-supplied. Two coordinated changes:

- Core/ProfileDefinition.swift: context becomes Int? (nil means derive at resolve time). Existing callers passing an Int keep exactly current behavior. Codable stays back-compatible: JSON lacking the key decodes to nil; old JSON with a number still decodes.
- Sizing/RepoMetadata.swift: surface nativeMaxContext parsed from the config.json it ALREADY fetches per candidate. Key fallback chain: max_position_embeddings, then n_positions, then max_seq_len / seq_length. Apply a hard sanity cap (suggest 1048576) and a floor (4096). Metadata missing entirely: treat native max as 8192 and attach a diagnostic so resolution failure messages can say why.

Footprint continues to take a concrete context value — the derivation itself (the ladder) is the dependent JointFit task, not this one. This task only makes the inputs available.

## Acceptance Criteria
- [ ] ProfileDefinition with context nil flows through the resolve path (compiles; JointFit temporarily substitutes the old 8192 default until the ladder task lands)
- [ ] Explicit context behavior is bit-for-bit unchanged; decoding legacy profile JSON works
- [ ] RepoMetadata exposes nativeMaxContext with the fallback chain, cap, and floor

## Tests
- [ ] Sizing tests over fixture config.json variants: max_position_embeddings present; only n_positions; only max_seq_len; absurd value capped; tiny value floored; missing metadata yields default plus diagnostic
- [ ] ProfileDefinition Codable round-trip tests: nil, explicit, legacy JSON
- [ ] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness