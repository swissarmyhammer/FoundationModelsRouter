---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzkrnmbg1sspv1ee171phzck
  text: |-
    Research done. Pulled the deciding rule text first (`review` `dump validators` -> `swift/doc-parameter-naming` and `swift/documentation`) rather than fixing the six cited lines. Both rules say the same thing about links: "DocC symbol links follow the declaration, not this rule. A cross-reference like ``capped(text:)`` uses the function's external argument labels because that is the symbol's name."

    Restated cause in the rule's terms: **a ``…``-delimited symbol link whose argument-label list is not the external argument-label list of any declaration of that name.** Not "these six links are stale". Note a Swift declaration has ONE symbol name covering every parameter, defaulted ones included — so a link that stops at the non-defaulted prefix (e.g. ``makeSession(instructions:workingDirectory:)`` against `makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)`) resolves to nothing exactly like the six the card names.

    Swept the whole target, not just `Session/`. Built a type-scoped checker (scratchpad `doclinks.py`) that avoids both false-positive modes the card warns about:
    - it resolves `func` / `init` / `subscript` / `case` and binds each to its innermost enclosing type body, so ``Router.resolve(_:reporting:)`` is checked against `Router`'s members instead of every `resolve` in the repo (the enum-case/initializer miss);
    - parameter lists are split by a bracket-matching scanner that steps over `->` as a unit and tracks `<>` separately, so a closure parameter type no longer closes a bracket (the `->` mis-parse).

    Result over `Sources/`: 525 ``…`` symbol links scanned, 799 declarations indexed, **42 stale sites**, 0 unresolvable-here. Every one of the 42 was then confirmed by reading the declaration — none is a false positive, and none is a correct link being "fixed" toward internal names.

    Card named 6 sites, all in `Session/`. The sweep found 42, of which 10 are in `Session/` — the 6 named plus 4 the card missed:
    - `RoutedSessionActor.swift:87` and `RoutedSessionActorGeneration.swift:10` — ``generate(grammar:_:)``, declared `generate(grammar:prompt:onEvent:_:)`
    - `RoutedSessionActor.swift:318` and `RoutedSessionActorCompaction.swift:118` — ``finishTurn(grammar:since:usageBefore:pendingEvents:)``, declared `finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)`

    The other 32 are the same cause outside `Session/`: `Guided/GuidedGeneration.swift` (3), `LanguageModelProfile.swift` (3), `Recording/RecordingLanguageModel.swift` (5), `Recording/TranscriptReconstruction.swift` (1), `Resolution/LiveModelLoader.swift` (1), `Resolution/ModelLoader.swift` (2), `RoutedLLM.swift` (9), `Router.swift` (6), `Tools.swift` (2). They predate the split too; the split just moved some of them.
  timestamp: 2026-08-09T17:21:02.320219+00:00
- actor: claude-code
  id: 01kzkttw5qym1r94rrgr0x1mha
  text: |-
    Two false-negative holes turned up mid-sweep and are worth recording, because both hid most of the defect from the first scan:

    1. **DocC's `/` path separator.** The first scanner only accepted `.` between path components, so it silently skipped every ``RoutedModel/makeSession(…)``-shaped link — which is the majority form in this repo. Handling `/` took the `Sources/` corpus from 525 links to 990 and the finding count from 42 to 97. Anyone re-checking this must accept both separators.
    2. **Typealias-qualified links.** ``RoutedEmbedder/embed(_:)`` and ``RoutedLLM/makeSession(…)`` name typealiases (`RoutedModel<any LoadedEmbeddingContainer>` / `RoutedModel<any LoadedLLMContainer>`), which carry no members — fixing only the labels would have left the link just as unresolvable. Retargeted to ``RoutedModel/…``, which is the qualifier every other link in the repo already uses for these members.

    Applied via a table of 40 exact (old link, new link, expected site count) triples with the counts asserted before anything was written, so a replacement that hit more or fewer sites than the audit predicted would abort rather than silently over-apply. All counts matched.

    Verification that the change is doc-only: `git diff -U0 -- '*.swift'` filtered to lines that are not `///` or `//` returns nothing, and the diff is 128 added / 128 deleted across 46 files — a pure in-place rewrite. The single `- Parameter`-adjacent line in the diff is a `- Parameters:` header whose *prose* contains a symbol link (`makeRoutedSessionActor`); no doc key name changed, so acceptance criterion 3 holds.

    Checker kept as `Scripts/check-doc-links.py`. Watched it fail before trusting it: re-broke ``generate(grammar:prompt:onEvent:_:)`` in `RoutedSessionActorGeneration.swift`, confirmed it reported exactly that site and exited 1, restored, confirmed 0 and exit 0. **Flagging for the reviewer:** this is the repo's first tracked non-Swift file (no `Scripts/`, no `.py`/`.sh` existed), so it is a new convention. It is deliberately *not* wired into `swift test` or CI — a parser edge case should never be able to turn the suite red — and the card only asked that the checker be kept, not that it gate anything. Veto the placement if that is not wanted.

    Ran the `swift` + `missing-docs` validators over the whole files rather than counting by hand, per the sweep instruction. `RoutedSessionActor*.swift` (7 files): 0 findings. `Scripts/check-doc-links.py`: 3 findings first pass (two undocumented module constants, `collect_declarations` cognitive complexity 19 > 15) then 1 more (path traversal on the `directories` argument) — all fixed, re-review clean at 0. The two doc findings were applied to the whole file, not just the two constants cited: `NAME_RE` and `LINK_RE` were undocumented too and got comments.

    `RoutedSession.swift` returned 4 findings that are **pre-existing and out of this card's scope** — `cancel(_:)`/`replace(_:prompt:)` omitting their first argument label, and a duplicated elicitation-id ULID parse. This card changes only symbol-link text; those are public-signature and structural changes with callers. Filed as `^rhrk3mz` rather than fixed here or dropped.
  timestamp: 2026-08-09T17:58:51.319119+00:00
- actor: claude-code
  id: 01kzktv50aqm4hfhpfvhq50gva
  text: |-
    ### implement — changed
    - evidence: 99 stale symbol-link sites fixed across 46 Swift files (71 in `Sources/`, 28 in `Tests/`), against the 6 the card named — 10 of them in `Session/`, being the 6 named plus 4 the card missed. 39 distinct broken link texts; every one confirmed against its declaration. Plus 1 new file, `Scripts/check-doc-links.py`. Diff is 128 added / 128 deleted, all comment lines. `swift build` clean; ungated `swift test` green at 824 tests (776 + 24 + 24) in 86 suites, 0 failures — the stated baseline. `Scripts/check-doc-links.py` reports 1256 links / 2319 declarations / 0 stale / 0 unresolved, exit 0. Doc-only change, so no gated run was needed. Nothing in the vendored mlx-swift-lm fork was touched.
    - next: `/review` — note the two open questions for the reviewer: (1) `Scripts/check-doc-links.py` is the repo's first tracked non-Swift file, and (2) `^rhrk3mz` was filed for the 4 pre-existing `RoutedSession.swift` findings this doc-only card left alone.
  timestamp: 2026-08-09T17:59:00.362928+00:00
- actor: claude-code
  id: 01kzkv1s7ag3x958gxxvezdqn2
  text: |-
    ### test — green
    - evidence: `git diff -U0 -- '*.swift'` — 128 added / 128 removed across 46 files; every added/removed line is a `///` or `//` comment line (0 non-comment, 0 blank-only). Paired each hunk's removed/added lines (128 pairs, 0 unmatched) and diffed with backtick-delimited spans stripped: 0 mismatches — every changed line differs *only* inside a `` `..` ``/```` `` .. `` ```` symbol-link span, nothing else in the prose changed. Confirms doc-only, link-only claim.
    - `- Parameter ` (singular key) check: zero matches anywhere in the diff. One `- Parameters:` line changed (`RoutedSessionActorRecording.swift`, a `mirror ``init(...)``` cross-reference) — confirmed the diff is entirely inside the backtick-delimited symbol link, not the `- Parameters:` key itself. No `- Parameter` doc key was touched.
    - `swift test`: `Test run with 776 tests in 72 suites passed` + `24 tests in 9 suites passed` + `24 tests in 5 suites passed` = 824 total, 0 failures. 34 skips, all inside suites in `FoundationModelsRouterIntegrationTests/*`, `CompactionContinuityEvaluationTests.swift`, `CompactionEvaluationTests.swift` — all `FM_ROUTER_INTEGRATION_TESTS`-gated files. 1 warning: `missing creator for mutated node` from vendored mlx-swift-lm fork (pre-existing, out of scope, build-graph note not a compiler diagnostic).
    - `Scripts/check-doc-links.py`: `Package.swift` has zero diff (`git status --porcelain Package.swift` empty) and zero mentions of `Scripts` anywhere in it or in the project's own Swift sources (only coincidental unrelated substring hits like `setupScripts` inside vendored `.build/checkouts`). Not a target, resource, or plugin — inert to the build. Ran the script itself: `symbol links scanned: 1256, declarations indexed: 2319, total stale: 0, total unresolved here: 0`, exit 0.
    - Package builds identically with `Scripts/` present: confirmed via `Package.swift` diff (none) and the successful `swift test` build above.
  timestamp: 2026-08-09T18:02:37.674235+00:00
- actor: claude-code
  id: 01kzkwynwtegwx3bzsv8qnmy36
  text: |-
    ### review — findings
    - evidence: 11 open findings. Engine `review sha HEAD~2..HEAD` (75 attempted, 2 FAILED — incomplete; 51 confirmed, 15 refuted) contributed 7 in Sources: RecordingLanguageModel.swift:241, ResolutionProgress.swift:68, ResolutionProgress.swift:70, Router.swift:63, Router.swift:66, Router.swift:160, Router.swift:174. Reviewer verification added 4: RecordingLanguageModelTests.swift:7 and ProfileLifecycleTests.swift:10 (typealias-qualified links still unresolvable — sweep incomplete), plus Scripts/check-doc-links.py `find_stale_links` global-pool fallback that hides them, and Scripts/check-doc-links.py placement (unwired, first non-Swift tracked file).
    - refuted by reviewer, do not action: SessionEvent.swift:13, SessionEvent.swift:60, CompactionContinuityEvalRealSubjectRunner.swift:15 — engine asked to add `grammar:`; two `makeSession` overloads exist (RoutedLLM.swift:144 public without `grammar:`, RoutedLLM.swift:196 internal with it) and the links name the public one correctly.
    - dropped per review-skill blanket exception: all existing-test refactor/dedup/dead-code findings.
    - verified independently, not to be redone: retargets to ``RoutedModel/…`` are correct (105 repo-wide uses); a second independently written checker reproduces 1256 links / 0 label-stale on 53e2a06 and 128 stale on 53e2a06~1, corroborating the label half of the sweep.
    - next: fix the 11 findings; decide the Scripts/check-doc-links.py placement question, then re-review.
  timestamp: 2026-08-09T18:35:53.114590+00:00
- actor: claude-code
  id: 01kzkxdjaf2gdbprz9a0efn6cr
  text: |-
    Iteration 2. Headline finding worked first, red-then-green.

    **The checker bug is real and is fixed.** Watched it fail before trusting the fix: on the unmodified tree `Scripts/check-doc-links.py` reported `0 stale / 0 unresolved`, exit 0, while both typealias-qualified survivors were present. The mechanism is exactly as the reviewer described — `pool = everywhere if qualifier is None else by_owner.get(qualifier, everywhere)` widened an unknown qualifier to the whole repo, `if symbol in pool: continue` accepted the link, and the `resolvable = qualifier is None or qualifier in owners` line below it never ran for this input.

    Fixed by extracting `resolution_pool(qualifier, everywhere, by_owner, owners)`, which returns `None` for a qualifier that owns no declaration instead of falling back. The dead `resolvable` test is gone entirely — its job now belongs to the pool lookup, so there is no second place for the two to disagree. Re-ran: it reported exactly the two survivors and nothing else (`total unresolved here: 2`, exit 1). No collateral false positives — every other qualified link in the repo resolves through a real owner, so the fix cost nothing elsewhere.

    Then verified the restructure did not break the label half: deliberately re-broke one label (``RoutedModel/embed(text:)``) and one qualifier (``NoSuchAlias/release()``) in the same file — it reported 1 stale and 1 unresolved, correctly bucketed, exit 1; restored, back to 0/0 exit 0.

    **Two survivors fixed**, plus a third instance of the same wrong qualifier the review did not name:
    - `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift:7` — ``RoutedLLM/makeLanguageModel()`` → ``RoutedModel/makeLanguageModel()``
    - `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift:10` — ``RoutedEmbedder/embed(texts:)`` → ``RoutedModel/embed(texts:)``
    - `Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift:33` — `RoutedLLM/makeLanguageModel()` in single backticks. Not a DocC link (single backticks are code voice, DocC resolves nothing), so the checker cannot and should not see it — but it carries the identical wrong qualifier, and the rule is to remove the cause from the whole file rather than only the cited line. Retargeted to `RoutedModel/...`.

    **Engine findings — read each against its declaration.** Three are false positives of periphery's assign-only analysis and got the marker the `dead-code-swift` rule specifies (`// periphery:ignore`, no trailing text, reason on its own comment line above it):
    - `RecordingLanguageModel.swift:241` `profile` — never read *on purpose*; holding the reference IS the behavior. Deleting it lets the profile and its resident models deallocate mid-handle.
    - `Router.swift:63` `ref` / `:66` `role` — `private struct ResidencyKey: Hashable`, read only through the synthesized `==`/`hash(into:)`. They are the pool key's identity; deleting either collapses every distinct model (or role) onto one bucket of `pool`.

    Four are genuine and need real code changes — see the blocker comment below.
  timestamp: 2026-08-09T18:44:00.975656+00:00
- actor: claude-code
  id: 01kznpr1mg4j4c0gc85zfc22gq
  text: |-
    User answered the blocker with option A — apply all four code changes. Applied:

    - `Router.swift` — deleted `let cacheDir: URL` and `let redact: (@Sendable (String) -> String)?` plus their two `self.… =` assignments. Both `init` *parameters* survive untouched, so the public signature, its `- Parameter cacheDir:` / `- Parameter redact:` doc keys, and the two type-level ``Router/init(id:headroomReserve:maxConcurrentForks:cacheDir:recordingsDir:recorder:recordingLevel:redact:probe:metadataSource:loader:)`` links all stay valid. The local `resolvedCacheDir` still feeds `HostProfileCache` and `RepoMetadataReader`; the `redact` parameter still feeds `GatingRecorder`. Behavior-preserving.
    - `ResolutionProgress.swift` — extracted `private static let downloadShare = 0.5` on `SlotProgress` and used it at both sites. Named rather than suppressed: swiftlint's exemption comment exists but a name is the fix the rule asks for. Named `downloadShare`, not `downloadShareOfSlot`, per the Swift idioms rule against repeating the enclosing type's name in a static member.

    **Placement of `Scripts/check-doc-links.py` — cost of each option, for the user's decision.** One correction to the finding first: this repo *does* have CI — `.github/workflows/ci.yml` — but it delegates entirely to the reusable `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main`, so nothing local runs the checker. That is why it reads as "wired into nothing".

    - **Cheapest, and the one that actually keeps it honest: a second job in this repo's own `ci.yml`.** About 8 lines — `runs-on: ubuntu-latest`, `actions/checkout`, `python3 Scripts/check-doc-links.py`. No Swift toolchain, no macOS runner, seconds of runtime, and it does not touch the shared reusable workflow in the other repo (which is out of bounds from here anyway). The checker already exits 1 on any finding, so it needs no wrapper.
    - **A test that shells out** (`Process` → `python3 Scripts/check-doc-links.py`, assert exit 0), ~30 lines in `FoundationModelsRouterTests`. Makes it run on every `swift test`. Rejected in iteration 1 on the grounds that a parser edge case should never be able to turn the suite red, and it puts a Python runtime on the critical path of `swift test`. That objection is weaker now that the checker has a red-green fixture behind it, but it is still a real coupling.
    - **A SwiftPM command plugin** (`swift package check-doc-links`): a `Plugins/CheckDocLinks/` target plus ~10 lines in `Package.swift`. Read-only, so no sandbox permission flags. But it is opt-in — nothing forces anyone to run it, which is the exact failure mode the finding is about. A build-tool plugin would force it, but the per-target sandboxed input/output model does not fit a whole-tree scan across `Sources/` and `Tests/`.
    - **Port it to Swift** as a test-target helper, removing the Python dependency argument entirely. ~450 lines to port faithfully, including the comment/string blanker and the bracket scanner. Highest cost, cleanest end state.

    Left the file exactly where it is, per instruction. No `Package.swift` change, no CI change.
  timestamp: 2026-08-10T11:25:53.168621+00:00
- actor: claude-code
  id: 01kznprgtmzhfv260swwwfte7a
  text: |-
    ### implement — changed
    - evidence: 7 files. `Scripts/check-doc-links.py` (+40/-11: `resolution_pool` extracted, the silent global-pool widening removed, the dead `resolvable` test deleted, module docstring states the new resolution rule); `Sources/FoundationModelsRouter/Router.swift` (deleted assign-only `cacheDir` and `redact` stored properties + their assignments; `// periphery:ignore` + reason on `ResidencyKey.ref`/`.role`); `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift` (`private static let downloadShare = 0.5`, used at both magic-number sites); `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` (`// periphery:ignore` + reason on `profile`); and 3 test files retargeting the typealias qualifier — `RecordingLanguageModelTests.swift:7`, `ProfileLifecycleTests.swift:10`, `RecordingHandleIntegrationTests.swift:33`. Total 58 insertions / 24 deletions.
    - checker, red then green: before the fix, `0 stale / 0 unresolved` exit 0 on a tree holding both survivors; after the fix, exactly those two (`total unresolved here: 2`, exit 1) and nothing else; after retargeting, `1256 links / 2319 declarations / 0 stale / 0 unresolved`, exit 0. Fault-injection on the fixed checker (one broken label + one unknown qualifier in one file) reports 1 stale + 1 unresolved in the right buckets, exit 1, and returns to 0/0 exit 0 on restore — so the 0 is a measurement, not a vacuous pass.
    - `grep` for `RoutedLLM/` or `RoutedEmbedder/` across `Sources/` and `Tests/`: zero hits.
    - `swift test`: 776 + 24 + 24 = 824 tests, 0 failures — the stated baseline held across the two stored-property deletions. Zero compiler errors, zero compiler warnings; the one build note is the pre-existing `missing creator for mutated node` from the vendored mlx-swift fork, unchanged and out of scope.
    - all 11 review findings closed: 4 by code change, 3 by the `// periphery:ignore` marker the `dead-code-swift` rule specifies, 3 by doc-link retargeting, 1 (placement) by fixing the bug and leaving the file in place with the wiring cost written up for the user. The 3 reviewer-refuted `grammar:` findings were left untouched and re-confirmed correct.
    - next: `/review`. Open for the user: whether to wire `Scripts/check-doc-links.py` into CI (cheapest option costed in the comment above) or leave it unwired.
  timestamp: 2026-08-10T11:26:08.724190+00:00
- actor: claude-code
  id: 01kznq2s4vy0nd6wme1v32krn7
  text: |-
    ### test — green

    **Suite:** `swift test` — 824 tests total (776 + 24 + 24), 0 failures, 0 warnings actionable (the one `warning:` hit is the vendored mlx-swift-lm `missing creator for mutated node` note, out of scope per project constraints), 0 skipped that aren't `FM_ROUTER_INTEGRATION_TESTS`-gated (36 skip lines, all under `.enabled(if:` gates, 19 refs to the env var, zero `.disabled(`).

    **Scrutiny of the 7-file, +58/-24 code diff:**

    1. **`Router.cacheDir` / `Router.redact` deletion — confirmed safe.** `git diff` on `Router.swift` shows both were plain `let` (internal access) inside `public actor Router`, not `public let` — so they were never part of the public API surface; only the `cacheDir:`/`redact:` init *parameters* (unchanged) are public-facing. Repo-wide grep for `.cacheDir`/`.redact` found zero reads of these stored properties (only unrelated `HostProfileCache.cacheDir`, test-harness `cacheDir`, and `GatingRecorder.redact` — different types entirely), and `extension Router` doesn't exist anywhere. Deletion is confirmed dead code, not source-breaking.

    2. **`periphery:ignore` markers — format correct; `ref` is proven load-bearing, `role` is not test-proven.** `RecordingLanguageModel.profile` and `ResidencyKey.ref`/`.role` all carry the marker in the specified form (reason comment above, then a bare `// periphery:ignore` line). For `ResidencyKey.ref`: test `PooledResidencyTests.sameRepoDifferentRevisionDoesNotShare` pins two different revisions of the same repo to the same slot and asserts 2 distinct loads — if `ref` were collapsed out of `Hashable`, this test would fail (the second resolve would find the first's pool entry and skip loading). For `ResidencyKey.role`: I searched the whole test suite for a scenario where the same `ModelRef` is used under two different `Role` values (e.g., the same ref as both an `.embedding` and `.llm(context:)` candidate, or the same ref/context reused across profiles) and found none — every fixture uses distinct ref strings per slot. So while the reasoning that `role` must stay distinct is sound (removing it would let an LLM-role entry satisfy an embedding-role lookup, hitting the `preconditionFailure` in `makeRoutedModel`'s `unwrap`), there is currently no test that would fail if `role` alone were dropped from the key. Stating this plainly per the instruction, not softening it.

    3. **`SlotProgress.downloadShare` (0.5) — confirmed same concept at both sites.** `.downloading` scales `downloadShare * bytesDownloaded/bytesTotal` (partial credit while bytes arrive); `.loading` returns `downloadShare` flat (download is complete/fully earned the moment the last byte lands, now loading). Same constant, correctly shared — not two unrelated halves. Pre-existing tests in `ResolveTests.swift` (lines pinning `SlotProgress(state: .downloading, bytesDownloaded: 100, bytesTotal: 100).progressFraction == 0.5` and `SlotProgress(state: .loading).progressFraction == 0.5`) already pin the literal value at both sites and stayed green.

    4. **Remaining changes confirmed as described.** The three test files (`RecordingHandleIntegrationTests.swift`, `ProfileLifecycleTests.swift`, `RecordingLanguageModelTests.swift`) each retarget exactly one DocC qualifier (`RoutedLLM/` → `RoutedModel/`, `RoutedEmbedder/` → `RoutedModel/`) in a doc comment, nothing else. `Scripts/check-doc-links.py`'s diff replaces the widening fallback `pool = everywhere if qualifier is None else by_owner.get(qualifier, everywhere)` with `resolution_pool(qualifier, everywhere, by_owner, owners)`, which returns `None` when a qualifier owns no declaration instead of silently falling back to the whole-repo pool; the dead `resolvable` check is removed. Ran the script directly: `symbol links scanned: 1256`, `total stale: 0`, `total unresolved here: 0`, exit 0 — matches the claimed clean state.

    evidence: `swift test` → 776+24+24=824 passed, 0 failed; `grep -c "error:"` = 0, only warning is the out-of-scope mlx-swift-lm node warning; `python3 Scripts/check-doc-links.py` → 0 stale / 0 unresolved, exit 0.
    next: none — iteration 2 verified clean on both the green-suite axis and the four specifically-scrutinized code changes.
  timestamp: 2026-08-10T11:31:44.923860+00:00
position_column: doing
position_ordinal: '80'
title: Stale DocC symbol links in the split session files name signatures that no longer exist
---
Discovered while working `^5m97h14`'s iteration-3 review findings. Not one of those findings, and deliberately not fixed there: `^5m97h14`'s findings are about `- Parameter` doc *keys* and about magic numbers, and the `swift/doc-parameter-naming` rule explicitly separates the two concerns — "DocC symbol links follow the declaration, not this rule … do not 'fix' symbol links to internal names, and do not cite them as violations of this rule." These links are broken for a different reason: they name an argument list the declaration no longer has, so DocC resolves nothing at all.

## The six confirmed links

Each was verified against the declaration by grep, not inferred.

- `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift` — ``recordTranscriptDelta(grammar:since:usage:)`` in `makePartialEvent`'s doc comment. Declared (same file) as `recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)` — the link is missing two labels.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — ``recordTranscriptDelta(grammar:since:usage:pendingEvents:)`` in `generate`'s doc comment. Missing `onEvent:`.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:)`` in `dispatchNextPrompt`'s doc comment. Missing `onEvent:`; declared in `RoutedSessionActorRecording.swift` as `finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:onEvent:)`. Note the *other* two links to this same symbol in the same file already spell it correctly, so this one is inconsistent with its own file.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — ``generate(grammar:prompt:_:)``, twice. Declared as `generate(grammar:prompt:onEvent:_:)`.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift` — ``generate(grammar:prompt:_:)``, once. Same defect.

All six predate the `RoutedSession.swift` split (`^5m97h14` iteration 2, commit `2adf089`) — the split moved them between files but did not create them; they went stale when `onEvent:` was added to those signatures.

## Do not trust a naive scanner here

A first pass at counting these module-wide reported 97 "stale" links in `Session/` alone. That number is wrong twice over: it counted enum-case links (``turnEnded(_:)``, ``toolCall(id:name:argumentsJSON:)``, ``compaction(_:)``) as unresolved because the collector only gathered `func` declarations, and its parameter-list splitter treated the `>` in a `->` closure return as a bracket close, so any signature with a closure parameter was mis-parsed. Whatever finds the rest of these must resolve enum cases, initializers, and properties too, and must parse closure parameter types correctly — or be checked by hand.

## What the sweep actually found (implement step)

The cause, restated in the deciding rule's terms: **a ``…``-delimited symbol link whose argument-label list is not the external argument-label list of any declaration of that name.** A Swift declaration has ONE symbol name covering every parameter, defaulted ones included — so a link that stops at the non-defaulted prefix resolves to nothing exactly like the six above.

**99 sites, against the 6 the card named.** 71 in `Sources/`, 28 in `Tests/`, spanning 39 distinct broken link texts across 46 files. Each was confirmed by reading the declaration; none is a false positive, and no correct link was moved toward internal names.

Two false-negative holes in the first scan had to be closed to get there:
- DocC's `/` path separator (``RoutedModel/makeSession(…)``) — the first pass only handled `.`, and that form is the majority of the corpus (525 links became 990 in `Sources/` once `/` was handled).
- Typealias-qualified links (``RoutedEmbedder/embed(_:)``, ``RoutedLLM/makeSession(…)``): `RoutedEmbedder`/`RoutedLLM` are typealiases of `RoutedModel<…>` and carry no members, so these were retargeted to ``RoutedModel/embed(texts:)`` — the qualifier the rest of the repo already uses.

In `Session/` the sweep found 10, being the 6 named plus 4 the card missed: ``generate(grammar:_:)`` (`RoutedSessionActor.swift`, `RoutedSessionActorGeneration.swift`) and ``finishTurn(grammar:since:usageBefore:pendingEvents:)`` (`RoutedSessionActor.swift`, `RoutedSessionActorCompaction.swift`).

## Acceptance Criteria
- [x] The six links above name the argument lists their declarations actually have
- [x] The rest of the module is swept for the same defect with a method that does not produce the false positives described above — enum cases, initializers, and properties resolved, closure parameters parsed correctly
- [x] No `- Parameter` doc key is changed by this work: this task is only about `` `` ``-delimited symbol links, and the rule forbids moving doc keys toward external labels
- [x] Ungated `swift test` stays green

## Tests
- [x] Documentation-only change, so no behavioral test. If the sweep is mechanized, the checker itself is the durable artifact worth keeping.

Kept as `Scripts/check-doc-links.py` — the repo's first non-Swift tracked file, so the reviewer should confirm that placement is wanted. It exits non-zero when any link is stale, and was verified to fail on a deliberately re-broken link and pass on the restored tree.

## Review Findings (2026-08-09 13:06)

> Scope: `review sha HEAD~2..HEAD` (code reviewed in `53e2a06`; `506b8c9` is a board-state-only commit and was not reviewed as code).
> Engine: 75 tasks attempted, **2 failed — engine results are INCOMPLETE**. 51 raw findings, 51 confirmed, 15 refuted.
> Findings whose subject is refactoring/deduplicating pre-existing test code are dropped under the review skill's blanket exception and are not listed.

### Engine findings

- [x] `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift:241` — var.instance `profile` is assignOnlyProperty. **Iteration 2:** read against the declaration — never read *on purpose*, since holding the reference IS the retention that keeps the profile's resident models alive for the handle's lifetime. Deleting it would let them deallocate mid-handle. Given the marker `dead-code-swift` specifies: `// periphery:ignore`, no trailing text, reason on its own comment line above it.
- [x] `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift:68` — Magic numbers should be replaced by named constants. **Iteration 2:** both sites are the same concept — the share of a slot's work that downloading accounts for. Extracted `SlotProgress.downloadShare` (`private static let`) and used it at both.
- [x] `Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift:70` — Magic numbers should be replaced by named constants. **Iteration 2:** same constant; a loading slot reads exactly `downloadShare` because the download half is fully earned the moment the last byte lands.
- [x] `Sources/FoundationModelsRouter/Router.swift:63` — var.instance `ref` is assignOnlyProperty. **Iteration 2:** `private struct ResidencyKey: Hashable`; read only through the synthesized `==`/`hash(into:)`, which is exactly what makes it a pool key. Deleting it would collapse every distinct model onto one bucket of `pool`. Marked `// periphery:ignore` with the reason above it.
- [x] `Sources/FoundationModelsRouter/Router.swift:66` — var.instance `role` is assignOnlyProperty. **Iteration 2:** same structure, same reason — deleting it would collapse `.llm(context:)` and `.embedding` residency onto one key.
- [x] `Sources/FoundationModelsRouter/Router.swift:160` — var.instance `cacheDir` is assignOnlyProperty. **Iteration 2:** genuinely dead, confirmed. `init` assigns it from the local `resolvedCacheDir`, and both real consumers (`HostProfileCache`, `RepoMetadataReader`) read that local, not the property; zero reads repo-wide and no `extension Router` exists anywhere. Deleted the stored property and its assignment. The `cacheDir:` init *parameter* is untouched, so the public signature and its doc keys are unchanged.
- [x] `Sources/FoundationModelsRouter/Router.swift:174` — var.instance `redact` is assignOnlyProperty. **Iteration 2:** genuinely dead, confirmed. `init` consumes the *parameter* to build the `GatingRecorder`; the stored property is never read, and its own doc already said redaction is "enforced through ``recorder``". Deleted the stored property and its assignment; the `redact:` init parameter is untouched.

### Reviewer-verified findings — the sweep is not complete

The sweep closed the *label* half of the defect but not the *qualifier* half. Two typealias-qualified links remain, unresolvable by this card's own stated reasoning — the same reasoning used to justify retargeting ``RoutedEmbedder/embed(_:)`` and ``RoutedLLM/makeSession(…)``.

- [x] `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift:7` — ``RoutedLLM/makeLanguageModel()`` is typealias-qualified and resolves to nothing. `RoutedLLM` is `typealias RoutedLLM = RoutedModel<any LoadedLLMContainer>` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:211`) and owns no members; `makeLanguageModel()` is declared in `extension RoutedModel where Container == any LoadedLLMContainer` (`Sources/FoundationModelsRouter/RoutedLLM.swift:472`). Retarget to ``RoutedModel/makeLanguageModel()``. (Pre-existing line, `git blame` 76a31df1 2026-07-14 — same provenance as the 99 sites the sweep did fix.) **Iteration 2:** retargeted.
- [x] `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift:10` — ``RoutedEmbedder/embed(texts:)`` is typealias-qualified and resolves to nothing. The argument labels are correct; the qualifier is not. `RoutedEmbedder` is `typealias RoutedEmbedder = RoutedModel<any LoadedEmbeddingContainer>` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:219`); `embed(texts:)` is declared in `extension RoutedModel where Container == any LoadedEmbeddingContainer` (`Sources/FoundationModelsRouter/RoutedEmbedder.swift:30`). Retarget to ``RoutedModel/embed(texts:)``. (Pre-existing line, `git blame` d40f4823 2026-07-07.) **Iteration 2:** retargeted. A third instance of the same wrong qualifier turned up outside the checker's reach and was fixed too — `Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift:33` spells `RoutedLLM/makeLanguageModel()` in *single* backticks, which is code voice rather than a DocC link, so nothing resolves it and no checker can see it; it carried the identical wrong qualifier and was retargeted per "remove the cause from the whole file". `grep` now finds zero `RoutedLLM/` or `RoutedEmbedder/` qualifiers anywhere in `Sources/` or `Tests/`.
- [x] `Scripts/check-doc-links.py` — `find_stale_links` cannot detect the two links above, which is why the tree reports clean while they are broken. The qualifier check is defeated by a silent fallback: `pool = everywhere if qualifier is None else by_owner.get(qualifier, everywhere)`. When a qualifier owns no declarations — exactly the typealias case — the pool widens to every declaration in the repo, the bare selector is found, and the link is accepted by the `if symbol in pool: continue` short-circuit before the `resolvable = qualifier is None or qualifier in owners` test on the next line is ever reached. An unknown qualifier must be reported, not silently widened to the global pool. Fix the whole class: any link whose qualifier names no owner is unresolved. **Iteration 2:** fixed, red-then-green. Watched it fail first — on the untouched tree it reported `0 stale / 0 unresolved`, exit 0, with both survivors present. Extracted `resolution_pool(qualifier, everywhere, by_owner, owners)`, which returns `None` for a qualifier owning no declaration instead of widening; the dead `resolvable` test is gone entirely, so the two can no longer disagree. Re-ran: exactly the two survivors, `total unresolved here: 2`, exit 1, and no collateral false positives anywhere else in the repo. Then proved the restructure kept the label half: re-broke one label and one qualifier in one file — 1 stale + 1 unresolved, correctly bucketed, exit 1 — restored, back to 0/0 exit 0.
- [x] `Scripts/check-doc-links.py` — placement. This is the repository's first tracked non-Swift file. It is wired into nothing: `Package.swift` is unchanged, there is no `Scripts` target, resource, or plugin, and no CI step runs it, so it introduces a Python toolchain requirement into a pure-Swift package with nothing that executes it. Nothing keeps it accurate, and it has already exhibited that failure mode — it reports `0 stale / 0 unresolved` on a tree containing two instances of the defect it exists to catch. Either wire it into the build so it runs on every change and stays honest, or remove it and keep the sweep as a one-time correction. Recorded as a finding; the user has the final call on placement. **Iteration 2:** the actionable half is done — the bug that made it dishonest is fixed and the file is left exactly where it is, per explicit instruction not to delete it and not to wire it in unilaterally. The placement decision itself is reserved for the user; the cost of each option is stated in the implement report and in the comment thread so it can be made cheaply.

### Engine findings refuted by the reviewer — do not action

Three engine findings ask for `grammar:` to be added to ``RoutedModel/makeSession(…)`` links, on the stated premise that "the function signature was updated to add this parameter in this commit". That premise is false. `makeSession` has two overloads: `public func makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)` at `Sources/FoundationModelsRouter/RoutedLLM.swift:144` — no `grammar:`, it forwards with `grammar: nil` — and the internal `makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)` at `Sources/FoundationModelsRouter/RoutedLLM.swift:196`. The three cited links name the public overload correctly. Applying these would trade a working link for a broken one, and would point public documentation at an internal-only overload.

- `Sources/FoundationModelsRouter/Session/SessionEvent.swift:13` — refuted, link is correct as written. Iteration 2: left untouched, confirmed.
- `Sources/FoundationModelsRouter/Session/SessionEvent.swift:60` — refuted, link is correct as written. Iteration 2: left untouched, confirmed.
- `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift:15` — refuted, link is correct as written. Iteration 2: left untouched, confirmed.

### Independent verification performed (do not redo)

- **Retarget correctness (confirmed).** `RoutedEmbedder` and `RoutedLLM` are typealiases of `RoutedModel<…>` and own no members; `embed(texts:)` and both `makeSession` overloads are declared in `extension RoutedModel where Container == …`. ``RoutedModel/…`` is the repo-wide qualifier: 105 uses against 1 remaining each for ``RoutedLLM/…`` and ``RoutedEmbedder/…`` (the two findings above). The retargets are correct.
- **Sweep completeness, label half (confirmed).** A second checker was written from scratch by the reviewer with an independent design (paren-matching declaration scanner, unlabelled-associated-value handling so enum cases resolve, both `/` and `.` separators). On `53e2a06` it reports 1256 parenthesised links and 0 label-stale, matching `Scripts/check-doc-links.py`'s 1256 / 0. On `53e2a06~1` it reports 128 label-stale, matching the commit's 128-line diff. The 0 is therefore corroborated by an independent tool, not taken on trust.
- **Shared blind spot.** Both checkers match on base name plus argument labels and ignore the qualifier, which is precisely why the two typealias-qualified links above survived both. The `0 stale / 0 unresolved` result is evidence about labels only, not about resolvability. **Iteration 2: this blind spot is now closed in `Scripts/check-doc-links.py`** — the qualifier is checked, and a qualifier owning no declaration is reported rather than widened away. #phase-1