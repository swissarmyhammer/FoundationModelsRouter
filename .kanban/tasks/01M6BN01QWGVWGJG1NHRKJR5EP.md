---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bq3p3qe7whb7z5yhhh2757
  text: |-
    ### review — findings
    - evidence: review sha 53d507c3~1..53d507c3, 2 findings (2 confirmed) — Tests/FoundationModelsRouterTests/Helpers/RecordingEmbeddingContainer.swift:10, Tests/FoundationModelsRouterTests/Helpers/RecordingEmbeddingContainer.swift:26
    - next: fix the 2 open findings, then run review again
  timestamp: 2026-11-01T14:09:43.031207+00:00
- actor: claude-code
  id: 01m6bq836zm8a21pgngv0hs85b
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift, Tests/FoundationModelsRouterTests/EmbeddingPrefixTests.swift, Tests/FoundationModelsRouterTests/Helpers/RecordingEmbeddingContainer.swift (deleted). StubEmbeddingContainer now takes an optional EmbedTextLog (Sendable class over Mutex, no @unchecked). EmbeddingPrefixTests 7 pass, EmbedTracingTests 5 pass, full suite 2177 tests pass, 0 warnings.
    - next: review
  timestamp: 2026-11-01T14:12:07.519660+00:00
- actor: claude-code
  id: 01m6bqb1cstjsz8363zpsegs8c
  text: |-
    ### review — findings
    - evidence: review sha 2f18e184~1..2f18e184, 2 findings (confirmed 2, refuted 0): EmbeddingPrefixTests.swift:22, RouterTestFixtures.swift:62. Rule dead-code-swift failed on a build error (HubModelLoader not found in LiveModelLoader.swift:1047) and judged nothing.
    - next: fix both open findings, then review again. The task stays in review.
  timestamp: 2026-11-01T14:13:43.961208+00:00
- actor: claude-code
  id: 01m6bqp4n0hztnmm0cp2v72w86
  text: |-
    ### review — clean
    - evidence: review sha 467fdacd~1..467fdacd, 0 findings (7 attempted, 0 failed), 2 files reviewed. All prior findings are checked.
    - next: none. Task moved to done.
  timestamp: 2026-11-01T14:19:47.745+00:00
position_column: done
position_ordinal: ffffffffd480
title: Handle embedding prefixes and the 128 token limit in the router
---
The Extras Core ML loader adds no prefix to a text, and the model reads only 128 tokens and cuts a longer text. The model needs a prefix for each kind of text: query "task: search result | query: " and document "title: none | text: ". Decide in the router how a caller states the kind of a text (for example a query and a document embed call on RoutedEmbedder), and where the prefix comes from for each model. Tell the caller when a text is cut. Keep the embed span attributes. Add unit tests with a stub container. Depends on the Extras Core ML loader being committed (HubModelLoader, CoreMLModelLoader).

## Review Findings (2026-11-01 08:06)

> Scope: `review sha 53d507c3~1..53d507c3` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 1 not reviewed.

> 1 file(s) not reviewed — no validator matched:
> - `docs/ane-embedding.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterTests/Helpers/RecordingEmbeddingContainer.swift:10` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/Helpers/RecordingEmbeddingContainer.swift:26` `reuse/reuse` — The new RecordingEmbeddingContainer.embed(texts:) reimplements an embedder stub that already exists in the test helpers. It returns one fixed vector per text, the same behavior as the existing stub. Its only addition is recording the texts, so the existing stub could have been extended with a recording option instead of adding a new class. Add optional text recording to the existing StubEmbeddingContainer in RouterTestFixtures.swift, or make RecordingEmbeddingContainer a thin wrapper over it. Then remove the new embed body so the fake vector logic lives in one place.


## Review Findings (2026-11-01 08:12)

> Scope: `review sha 2f18e184~1..2f18e184` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 0 not reviewed.

> Note: tool rule 'code-hygiene/dead-code-swift' failed (build error: cannot find 'HubModelLoader' in scope at LiveModelLoader.swift:1047) and judged nothing. Five code-hygiene rules declined an item because Tests/FoundationModelsRouterTests/Helpers/RecordingEmbeddingContainer.swift no longer exists.

- [x] `Tests/FoundationModelsRouterTests/EmbeddingPrefixTests.swift:22` `swift/naming-clarity` — The tuple label `container` names an `EmbedTextLog`, not a container. The callers bind it as `let (embedder, container)` and then read `container.received`. The name gives the wrong role: the reader expects the container, but the value is the log that the container writes into. Name the label by its role, for example `log`. Change the return type label to `log: EmbedTextLog` and update the two destructuring sites to `let (embedder, log) = Self.makeEmbedder(chosen: ...)` and `log.received`.
- [x] `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:62` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
