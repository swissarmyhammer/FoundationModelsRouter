---
comments:
- actor: claude-code
  id: 01kxhfrjkrb43bnrtb68ecdepf
  text: |-
    Implementation complete via TDD.

    ProfileDefinition (Core/ProfileDefinition.swift):
    - context changed from Int to Int?, default parameter still ProfileDefinition.defaultContext (8192) so omitted-context callers see identical behavior to before.
    - Added Codable conformance (previously had none). Since context is a stored Optional, Swift's synthesized Codable already gives the exact back-compat semantics needed: missing key -> nil, present number -> that Int. No custom encode/decode needed.
    - Router.swift's two read sites (loadLLM call, sizeCandidates) now do `def.context ?? ProfileDefinition.defaultContext` with a TODO pointing at the JointFit ladder task as the place that will replace this temporary fallback.

    RepoMetadata (Sizing/RepoMetadata.swift):
    - Added nativeMaxContext: Int and nativeMaxContextDiagnostic: String? fields, plus public constants nativeMaxContextCap (1_048_576), nativeMaxContextFloor (4096), defaultNativeMaxContext (8192).
    - SizingFields (used for both top-level and text_config, VLM coherent-source rule) gained maxPositionEmbeddings/nPositions/maxSeqLen/seqLength; ResolvedSizing carries the picked-first value as nativeMaxContextRaw.
    - New private resolveNativeMaxContext(raw:) applies the fallback chain -> cap -> floor -> default-with-diagnostic logic, called from init(raw:).
    - Memberwise init gained two new params with defaults (nativeMaxContext defaults to 8192, diagnostic to nil) so the existing direct-construction call sites (e.g. RepoMetadataTests.codableRoundTrip) are unaffected — this mirrors how numFullAttentionLayers was added previously.

    Tests added: 5 in CoreTypesTests.swift (nil context, explicit-context round-trip, nil-context round-trip omits the key, legacy JSON with number, JSON missing the key), 8 in RepoMetadataTests.swift (max_position_embeddings/n_positions/max_seq_len/seq_length fallback tiers, cap, floor, missing-all-fields default+diagnostic, VLM text_config coherent-source).

    swift test: 339 unit (326+13) / 15 gated, all green, zero warnings, zero diagnostics.
  timestamp: 2026-07-14T23:35:29.144122+00:00
- actor: claude-code
  id: 01kxhgb6rep8809gbcbbdyqthz
  text: |-
    really-done + adversarial double-check pass complete.

    Verification command run fresh (twice): `swift test` with DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer -> 0 failures both times, zero diagnostics errors/warnings.

    double-check verdict: REVISE with one finding — the cap/floor logic was correct by inspection but untested at the exact boundary values (1_048_576, 4096) and for non-positive raw values, so a future off-by-one (e.g. `>` -> `>=`) regression would go undetected. Everything else (ProfileDefinition optional-context change, Codable synthesis claim, Router.swift fallback sites, RepoMetadata init defaults not affecting existing direct-construction callers) was confirmed correct and on-intent.

    Fixed: added 3 tests to RepoMetadataTests.swift — exactly-at-cap (1048576, passes through, no diagnostic), exactly-at-floor (4096, passes through, no diagnostic), and a negative value (-1, floors to 4096 with a diagnostic).

    Final state: swift test -> 342 unit tests (326 original + 16 new) in 39 suites passed, 15 gated tests passed (unaffected), zero warnings, zero diagnostics errors. Task left in `doing` for /review per the implement workflow.
  timestamp: 2026-07-14T23:45:39.598620+00:00
position_column: doing
position_ordinal: '80'
title: Optional ProfileDefinition.context; native max context from repo metadata
---
## What
Make context derivable instead of caller-supplied. Two coordinated changes:

- Core/ProfileDefinition.swift: context becomes Int? (nil means derive at resolve time). Existing callers passing an Int keep exactly current behavior. Codable stays back-compatible: JSON lacking the key decodes to nil; old JSON with a number still decodes.
- Sizing/RepoMetadata.swift: surface nativeMaxContext parsed from the config.json it ALREADY fetches per candidate. Key fallback chain: max_position_embeddings, then n_positions, then max_seq_len / seq_length. Apply a hard sanity cap (suggest 1048576) and a floor (4096). Metadata missing entirely: treat native max as 8192 and attach a diagnostic so resolution failure messages can say why.

Footprint continues to take a concrete context value — the derivation itself (the ladder) is the dependent JointFit task, not this one. This task only makes the inputs available.

## Acceptance Criteria
- [x] ProfileDefinition with context nil flows through the resolve path (compiles; JointFit temporarily substitutes the old 8192 default until the ladder task lands)
- [x] Explicit context behavior is bit-for-bit unchanged; decoding legacy profile JSON works
- [x] RepoMetadata exposes nativeMaxContext with the fallback chain, cap, and floor

## Tests
- [x] Sizing tests over fixture config.json variants: max_position_embeddings present; only n_positions; only max_seq_len; absurd value capped; tiny value floored; missing metadata yields default plus diagnostic
- [x] ProfileDefinition Codable round-trip tests: nil, explicit, legacy JSON
- [x] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness