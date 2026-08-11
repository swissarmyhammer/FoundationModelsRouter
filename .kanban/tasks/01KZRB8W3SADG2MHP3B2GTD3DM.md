---
assignees:
- claude-code
position_column: todo
position_ordinal: 9d80
title: Stamp an explicit schema version on the sidecar and the event log
---
## Problem

Recording compatibility is purely by-optional-decoding: a new field decodes as `nil` on old lines, and nothing anywhere states which schema a file carries. That held for the v1-to-v2 transition. But the filed transcript work adds more shape: history ordinals (^6z1msg1), checkpoint changes (^h1008kb), unknown-case carriers (^9n7fna4), a configuration envelope. Without a version stamp, a future reader cannot distinguish "this field is nil because the recording predates it" from "this field is nil because it was legitimately absent" — the exact ambiguity that already forced the `contentRemoved` workaround (Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:17-23).

## Proposed solution

1. Add a `schemaVersion: Int` to `SessionSidecar` (one per session — sufficient granularity; per-line stamping would bloat every event for no reader benefit). Absent decodes as the current implicit version.
2. Define the version registry in one place: an enum or constant list in the Recording module, each version documented with what it added.
3. Readers gate on it: a version NEWER than the reader knows produces a typed "recording from a newer router" error instead of silent misreads; an older version keeps decoding by the additive rule, as today.
4. Writers stamp the current version on every new sidecar.
5. Land this BEFORE or WITH the first schema-touching task above, so the next shape change is born versioned.

## Acceptance

- New recordings carry the version; old recordings decode as the implicit version.
- A fabricated future-version sidecar fails restore with the typed error.
- The version registry documents every version and its additions. #transcript