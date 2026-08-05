---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz8h36b2ss17rxjs55n5h91b
  text: 'Research done. Re-measured the inventory with a signature-parsing script (scratchpad scan_doc_params.py) rather than trusting the card''s stale count of 91: current count is 104 doc-parameter entries across 30 files that document the internal name where a differing external label exists. Largest concentrations: RoutedSession.swift (17), TranscriptTree.swift (10), SessionSidecar.swift (9), GuidedGeneration.swift (12). One apparent extra hit (RepoMetadata.swift `endpoint` init) is a scanner false positive — label and internal name are identical there; the scanner tripped on comment lines inside the init''s parens. JointFit.swift hits from a first scan pass were also parser artifacts (`->` in closure types) and are NOT real sites. Pattern to follow is the one ^ew49xjj established: entry name becomes the external label verbatim (e.g. `- toTokenLimit:` for `toTokenLimit limit: Int`), and prose references to the old internal name inside the same doc comment become the label or plain English where the label reads badly (preposition labels like `to`/`in`/`of`). Doc-only sweep; no signature or behavior changes.'
  timestamp: 2026-08-05T08:36:59.362762+00:00
- actor: claude-code
  id: 01kz8khqg9s603kbtxtxmf5b7d
  text: |-
    BLOCKER — true conflict between this card's requirement and the review engine's current application of the swift documentation rule. A human must decide the direction; I am not resolving it.

    The written rule (swift validator, `documentation`): "Optionally Document exactly the parameters, return, and throws the signature has — no more, no less. ... Documented names must match the signature." It does not say whether "match the signature" means the external argument label or the internal parameter name.

    This card (validator-derived, per its own text and per ^ew49xjj's three fixed findings) requires the EXTERNAL LABEL: "for every function whose external label differs from its internal parameter name, rename the `- Parameter`/`- Parameters:` entry to the external label". Acceptance criterion: "Zero doc-parameter entries in Sources/ or Tests/ name the internal parameter where an external label exists". Evidence the engine enforced this direction before: Session/ToolOutputCapping.swift documents `- toTokenLimit:` for `toTokenLimit limit: Int` in HEAD today, written to satisfy a review finding on ^ew49xjj, and that review then passed clean.

    The sweep was implemented in that direction: all 104 sites across 33 files renamed to external labels, prose aligned; diff verified doc-only (`///` lines only in Sources/Tests); `swift build` clean; `swift test` green — 735+20+12 = 767 passed, 0 failures, gated integration suites skipped as expected.

    Then `review working` (2026-08-05 03:46, counts: findings 71, confirmed 71, refuted 23, attempted 63, failed 1 — "results are INCOMPLETE") confirmed findings applying the SAME rule in the OPPOSITE direction, e.g. word for word: "`Sources/FoundationModelsRouter/Compaction/Compactor.swift:210` — Parameter documentation uses argument label 'of' instead of parameter name 'transcript'. Parameter documentation must reference the declared parameter name. Change '- Parameter of:' to '- Parameter transcript:'." and "`Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:483` — Parameter documentation uses external parameter label `for` instead of the actual parameter name `ref`; documentation must name the actual parameter, not the label." There are ~24 such findings covering the exact renames this card mandates. Obeying them reverts the card; obeying the card violates them. Two rules that cannot both be correct — the flip-flop the card was created to eliminate is inside the review engine itself, one file at a time or one run at a time.

    Needs a human decision: amend the swift validator's documentation rule to state the direction explicitly (label vs internal name), then restart this card in that direction. Note: Apple/Xcode/DocC convention uses the internal parameter name in `- Parameter` entries, which matches today's findings and contradicts the card — but that choice is not mine to make.

    The 104-site sweep is left in the working tree (uncommitted, doc-only, build+test green) so whichever direction is chosen can proceed without redoing the mechanical work: keep it if the label direction wins, revert Sources/Tests doc lines if the internal-name direction wins.

    The same review run also carries findings not part of the conflict, recorded here so the next agent has the full picture (they surfaced because the sweep touched these files; most ask for code changes outside this card's doc-only scope): Summarization.swift:404 duplicate token estimation vs `Compactor.estimatedTokenCount(of:)`; TokenBudget.swift:206 force unwrap in non-test code; GuidedGeneration.swift:132/133/167/300/347/373 and RuntimeJSONSchemaConverter.swift:164 doc-name findings (same conflict class); ModelRef.swift:61, ElevatingTool.swift:17/871/998/1023, TokenBudget.swift:196, Compactor.swift:210/225/246, Summarization.swift:452, RepoMetadata.swift:483/499, CompactionEvalSeed.swift:42, CompactionContinuityDataset.swift:237, CompactionContinuityEvaluation.swift:192/296, CompactionEvaluation.swift:192 (same conflict class); plus ~40 "first line of doc comment is not a complete sentence ending with a period" findings in SessionProjection.swift, RepoMetadata.swift, and the four Evals files.
  timestamp: 2026-08-05T09:19:52.841047+00:00
- actor: claude-code
  id: 01kz8khyjddmhg906n3tsrcnf8
  text: |-
    ### implement — stuck
    - evidence: 33 files, 104 doc-parameter sites renamed to external labels (doc-only diff in Sources/Tests, left uncommitted); swift build clean; swift test 767 passed / 0 failed; review working confirmed 71 findings, ~24 of which demand the internal parameter name — the exact reverse of this card's acceptance criteria. True conflict recorded in the blocker comment above; a human must fix the swift validator's documentation rule to state the direction, then restart this card.
    - next: human decision on doc-parameter naming direction (external label vs internal name); then either keep the working-tree sweep (label direction) or revert the Sources/Tests doc lines and sweep the other way (internal-name direction).
  timestamp: 2026-08-05T09:20:00.077808+00:00
- actor: claude-code
  id: 01kz8kpg1dredreaqg0gsbfpp8
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 104 doc-parameter sites across 33 files renamed to external labels (card direction); build clean, swift test 767 passed; but review engine confirmed ~24 findings demanding the exact reverse (internal names). True conflict between the card's acceptance criteria and the validator rule, which names no direction. Blocker recorded; stuck tag applied; no validator edits made.
    - Orchestrator action: the green doc-only sweep will be committed locally as a labeled pending-decision checkpoint so subsequent tasks' diffs stay clean; the human decision (amend the validator rule direction, then re-open) governs whether it stands or is reverted.
    - Task left in doing+stuck — NOT forced to done.
  timestamp: 2026-08-05T09:22:29.037786+00:00
- actor: claude-code
  id: 01kz8ry3703t9ggffhn0x07dmp
  text: |-
    ### resolved — card obsolete (validator direction fixed by human decision)
    - The conflict is settled: the swift documentation rule now explicitly requires INTERNAL (local) parameter names in `- Parameter` entries — the names Swift-DocC and Xcode resolve against. Changes: new builtin rule `swissarmyhammer/builtin/validators/swift/rules/doc-parameter-naming.md` (uncommitted, in the sah source repo) and a disambiguated parameter bullet in the live `~/.validators/swift/rules/documentation.md`.
    - Under the fixed rule, this card's acceptance criteria (converge on EXTERNAL labels) pointed the wrong way; the 104 pre-sweep sites already documented internal names correctly. The sweep commit 6df1105 was reverted as fa04931 (code files only, build clean).
    - Residual: a handful of sites that documented external labels BEFORE the sweep (e.g. the ToolOutputCapping label alignments from ^ew49xjj iteration 2, commit ca654aa) now violate the fixed rule; future reviews will flag them toward internal names file-by-file as code changes touch them.
    - Card archived as obsolete — no remaining work.
  timestamp: 2026-08-05T10:54:00.928839+00:00
position_column: doing
position_ordinal: '80'
title: '[Repo] Converge doc-comment parameter naming on external argument labels repo-wide (91 sites)'
---
Repo: this repo (FoundationModelsRouter). Discovered while implementing ^ew49xjj's review pass.

The review engine's `swift` validator documentation rule ("Documented names must match the signature") is applied by the engine as: a `- Parameters:` entry must use the function's *external argument label*, not the internal parameter name. It produced three such findings on ^ew49xjj's changed files (RoutedLLM.swift, Session/ToolOutputCapping.swift), which were fixed there — including aligning each doc comment's prose to the renamed entries.

The rest of the repo still documents the *internal* name where the label differs. Measured 2026-08-04 (script over `Sources/` + `Tests/`): 91 doc-parameter entries across ~20 files use the internal name where an external label exists (largest: MLXChatSession.swift and the Recording/ files; also SessionProjection.swift, Sizing/RepoMetadata.swift, and the evals/test helpers). Until converged, every future change to one of those files will re-surface the same finding one file at a time.

## What
One mechanical, doc-only sweep: for every function whose external label differs from its internal parameter name, rename the `- Parameter`/`- Parameters:` entry to the external label, and align that doc comment's prose references (backticked internal names → the label, or plain English where the label reads badly — the pattern ^ew49xjj established in RoutedLLM.swift and Session/ToolOutputCapping.swift). No code changes, no behavior changes.

## Acceptance Criteria
- [ ] Zero doc-parameter entries in Sources/ or Tests/ name the internal parameter where an external label exists
- [ ] Prose inside each touched doc comment agrees with its renamed entries
- [ ] `swift build` and `swift test` green; zero warnings #router-first