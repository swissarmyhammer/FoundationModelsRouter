---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m716anw7k7b3ab44srykvt43
  text: |-
    Research + measurement (2026-11-09).

    Code path: Router.sizeCandidates walks every slot's refs serially, `await metadataResult(for: ref)` one at a time, then the drafter, also serially. The candidate `ModelRef(repo:path:revision:drafter:)` and its drafter `ModelRef(repo:path:revision:)` are different ModelRef keys (drafter is part of Hashable), so the self-drafter is sized twice. The revision is nil (can move), so RepoMetadataReader.refreshedMetadata fetches every time; the disk cache (keyed repo/path/revision) is only a fallback and does not dedup. There is no in-flight dedup anywhere. Metadata depends only on repo/path/revision (stringValue omits the drafter, so even the error names match).

    Header cost: Qwen3.5-0.8B-Q8_0.gguf KV section ends at byte 10,942,704 (tokens 4.85 MB, merges 5.09 MB, token_type 0.99 MB). GGUFHeaderPrefix reads 0..1M, 1..2M, 2..4M, 4..8M, 8..16M = 5 serial Range GETs, 16 MB, plus 5 full re-parses. Timing harness over the live HuggingFaceMetadataSource: tree+config 0.17 s, range reads 0.71/0.29/0.34/0.45/0.86 s; one header = 3.4-3.5 s total (debug), and a second sizing of the same ref costs the same again.

    Gated suite with temporary prints (reverted): plain profile sizing 4.0 s (embedding 0.38 + flash 0.20 + GGUF 3.43, serial); self-drafter profile sizing 10.3 s (0.14 + 0.14 + GGUF 3.62 + same GGUF again as drafter 6.39); mixed-slot GGUF alone took 9.47 s in the same run, so the per-header cost swings 3-9 s with the network. Loads are ~1.2 s and unchanged. Root cause of the delta: the drafter naming the same file is fetched a second time, serially. Contributing: all sizing is serial.

    Not the cause: tree listing (one GET, 0.11 s, 1.3 KB), no retry/timeout paths in the source.

    Plan: size each distinct (repo, path, revision) once, concurrently, in sizeCandidates; map results back to candidates and drafters. preferSuccess becomes dead (each ref gets one fetch). Range-read growth (5 round trips, 16 MB for 11 MB) is a separate improvement for the plain ref; filed as its own task.
  timestamp: 2026-11-09T22:19:43.879776+00:00
- actor: claude-code
  id: 01m716v3raddd3gs00x1r204xw
  text: |-
    Implementation landed (not committed).

    Router.sizeCandidates now collects the distinct candidates and drafters, maps each to its sizing key (`ModelRef(repo:path:revision:)`, no drafter), and sizes each distinct key once, all at the same time, in a task group (`sizedModels`, nonisolated; `metadataResult` is nonisolated too so parsing does not serialize on the Router actor). Results map back to every ref. `preferSuccess` was deleted: with one fetch per model there is nothing to merge. Drafter warnings now fire for each distinct drafter.

    Behavior change to note: a ref listed in two slots used to be fetched twice, and a transient failure on the first fetch could heal on the second. It is now fetched once, so the one result is its verdict in every slot. The test that pinned the heal (`mergePrefersSuccessOverAnEarlierFailure`) was deleted as no longer valid; the `.failure/.failure` test was retitled to the new contract (one fetch, its failure in every slot) and the `.success/.success` test retitled (it tests the per-slot footprint pricing, not sizeCandidates). ScriptedMetadataSource's doc no longer claims a twice-per-slot fetch.

    TDD: three new tests in GGUFResolveTests failed first (header read 2x, repo metadata read 2x, OverlapGatedMetadataSource gate expired at 60 s under serial sizing) and pass now. New helper Tests/.../Helpers/OverlapGatedMetadataSource.swift; FileServingMetadataSource records `metadataReads`.

    Re-measured with the gated suite (temporary prints, reverted): plain profile sizing 4.0 s -> 3.2 s; self-drafter profile sizing 10.3 s -> 3.3 s (the drafter shares the candidate's fetch, and the MLX candidates overlap the GGUF one). Test durations: self-drafter 32.5 s -> 26.4 s; suite 57.2 s -> 46.2 s. Remaining sizing time is the GGUF header Range reads themselves (5 round trips, 16 MB), filed as ^gnp1jne.

    Verification: `swift build --build-tests` clean (only the known missing-creator notice); `swift test` 2510 + 38 + 19 = 2567 pass (2565 + 3 new - 1 deleted); `swift build --build-tests --package-path IntegrationTests` clean; gated GGUFProfileIntegrationTests 3/3 pass.
  timestamp: 2026-11-09T22:28:42.378870+00:00
- actor: claude-code
  id: 01m716v7f3h1y3m2145146nfww
  text: |-
    ### implement — changed
    - evidence: root cause = the drafter naming the candidate's own file was a different ModelRef key, so its Hub metadata + 16 MB of GGUF header Range reads ran a second time, serially after the candidate (all sizing was serial). Fix: one concurrent fetch per (repo, path, revision). Files: Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/GGUFResolveTests.swift, Tests/FoundationModelsRouterTests/ResolveTests.swift, Tests/FoundationModelsRouterTests/Helpers/FileServingMetadataSource.swift, Tests/FoundationModelsRouterTests/Helpers/OverlapGatedMetadataSource.swift (new). Sizing phase: self-drafter 10.3 s -> 3.3 s, plain 4.0 s -> 3.2 s. swift test 2567 pass; both builds clean; gated suite 3/3.
    - next: /review. Follow-up ^gnp1jne for the Range-read round trips.
  timestamp: 2026-11-09T22:28:46.179562+00:00
- actor: claude-code
  id: 01m7170w9xmr1vv9ncb0qk97g8
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (69a0bd58) — 1 finding (1 confirmed, 0 refuted): Tests/FoundationModelsRouterTests/Helpers/OverlapGatedMetadataSource.swift:58
    - next: fix the open finding in the Review Findings (2026-11-09 16:30) section, then re-review
  timestamp: 2026-11-09T22:31:51.357746+00:00
- actor: claude-code
  id: 01m7171886gm74nsrg2apddrt3
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — Router.swift sizing dedup + concurrency, 4 test files
    - test: green — swift test 2567 passed, IntegrationTests builds
    - commit: 69a0bd58
    - review: findings — Tests/FoundationModelsRouterTests/Helpers/OverlapGatedMetadataSource.swift:58 (code-hygiene/idioms-swift ReplaceForEachWithForLoop)
  timestamp: 2026-11-09T22:32:03.590639+00:00
- actor: claude-code
  id: 01m7173n394nfdhvwg2mnnkev3
  text: |-
    Resolved finding `code-hygiene/idioms-swift` ReplaceForEachWithForLoop: `release()` in OverlapGatedMetadataSource now resumes held reads with a for-in loop. That file had only this one `.forEach`. The diff of HEAD (69a0bd58) added no other `.forEach` in any file. Finding flipped to [x].

    ### implement — changed
    - evidence: 1 source file (Tests/FoundationModelsRouterTests/Helpers/OverlapGatedMetadataSource.swift) + card .md; `swift build --build-tests` clean (only the known mlx-swift_Cmlx.bundle missing-creator notice); `swift test` 2567 pass (2510 + 38 + 19), 0 failures
    - next: /review
  timestamp: 2026-11-09T22:33:22.281897+00:00
position_column: doing
position_ordinal: '80'
title: 'GGUF: sizing a GGUF ref that names a GGUF drafter takes ~15 s longer than the plain ref'
---
## What
Measured by the gated GGUF suite (^44meq1j) on 2026-11-09, over 3 runs, each with a fresh router cache dir. Resolving the profile whose standard ref is `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` spends about 5 s between the `resolve` span's enter and the first `load`. With the same ref plus itself as drafter (`ModelRef(repo:path:revision:drafter:)`), the same sizing phase takes 15–20 s. That phase is `sizeCandidates`: Hub metadata plus the Range-fetched GGUFHeader, for the candidate and for its drafter. One extra GGUF header fetch should not cost 10–15 s.

## To do
Find where the time goes. Candidates: the drafter is sized serially after the candidate; the Range fetch reads more of the header than it needs; a ref and its drafter that name the same file are fetched twice instead of sharing one result. Fix it if the cause is in the router.

#gguf

## Review Findings (2026-11-09 16:30)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 10 not reviewed.

> 10 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 10 file(s)

- [x] `Tests/FoundationModelsRouterTests/Helpers/OverlapGatedMetadataSource.swift:58` `code-hygiene/idioms-swift` — ReplaceForEachWithForLoop: replace use of '.forEach { ... }' with for-in loop.
