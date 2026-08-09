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

Kept as `Scripts/check-doc-links.py` — the repo's first non-Swift tracked file, so the reviewer should confirm that placement is wanted. It exits non-zero when any link is stale, and was verified to fail on a deliberately re-broken link and pass on the restored tree. #phase-1