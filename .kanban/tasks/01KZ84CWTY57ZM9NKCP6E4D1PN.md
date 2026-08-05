---
assignees:
- claude-code
position_column: todo
position_ordinal: '9680'
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