---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0y9jvx1fda43fs6e3wmkr8f
  text: 'Picked up. Baseline recorded: `rg -c ''^\s*///'' Sources | awk -F: ''{s+=$2} END {print s}''` = 16450 lines across 98 files. Gate: final count <= 8225. Citation lines in `///` comments at start: 172. Baseline `swift build --build-tests` OK and `swift test` green (1056 tests in 104 suites + 83 evals tests). Per-folder counts: Session 5892, Recording 3675, Compaction 1584, Resolution 1506, Hosting 1394, root files 1220, Sizing 467, Guided 368, Concurrency 176, Core 168. Plan: fan out sub-agents on disjoint file groups, target <= 45% per file for margin.'
  timestamp: 2026-08-26T05:44:43.681194+00:00
- actor: claude-code
  id: 01m0y9ny6tqjq3sn1v6g8sdaa7
  text: 'Dispatched nine sub-agents on disjoint file groups (Hosting; Session x3; Compaction+Concurrency; Recording x2; Resolution+Sizing; Guided+Core+root). Each group targets <= 45% of its `///` count. Brief: only `///` lines change; contract-only prose; no task-id or plan-file citations; STE prose. The coordinator (me) runs the final gates: count, citation grep, build, full test.'
  timestamp: 2026-08-26T05:46:24.346482+00:00
- actor: claude-code
  id: 01m0yb54qdf4e1cv0kn8hvp4tm
  text: 'Picked up again after a usage-limit reset killed the first implementer and its nine sub-agents mid-edit. Partial work is kept: 30 Sources files edited, count 16450 -> 14546, build green. Next: find the heaviest remaining files and fan out small disjoint sub-agent passes; coordinator runs the final gates.'
  timestamp: 2026-08-26T06:12:11.117436+00:00
- actor: claude-code
  id: 01m0yb9erh84tj2y65tm42syv5
  text: 'Second fan-out: twelve sub-agents on disjoint file groups (RoutedSession; Summarization+TokenBudget+CompactionSegment; SessionProjection+SessionOutbox; Router+RoutedLLM+Tools; RecordingLanguageModel+SessionTreeRestoration+SessionSidecar; Resolution/*; RoutedSessionActor+Compaction+Generation; Transcript*; RepoMetadata+Footprint+SessionMailbox+ToolContext+Elicitation; ActorRecording+TurnExecution+Backend+Reentry+Stall; Guided+LanguageModelProfile+Compactor+RunJournal+TurnGating; sixteen mid-size files). Each file targets <= 40% of its current count. Shared brief in the session scratchpad: only `///` lines change, no builds in sub-agents, verify with a git-diff filter. Coordinator runs count, citation grep, build, and full test at the end.'
  timestamp: 2026-08-26T06:14:32.465393+00:00
- actor: claude-code
  id: 01m0ywefz6v9mynn4122rf6vh2
  text: |-
    Final pass. Removed the last 8 doc-comment citations (task ids and compaction_plan.md) in ResponseTextFold.swift, ToolOutputCapping.swift, RoutedSessionActorForking.swift, and ToolInvocationRecord.swift. Each doc now states only the contract. Only `///` lines changed: a git-diff filter over Sources shows 0 non-doc lines added or removed across 81 files. Note: the mlx-swift `Cmlx.bundle` "missing creator for mutated node" warning comes from the dependency build, not from our code.

    ### implement — changed
    - evidence: `///` count 6006 vs baseline 16450 (gate <= 8225); citation grep `rg -n '^\s*///.*(\^[a-z0-9]{7}|plan\.md|eventplan)' Sources` returns nothing; `swift build --build-tests` 0 errors, 0 warnings from our code; `swift test` 1056 tests in 104 suites + 83 tests in 10 suites passed.
    - next: /review
  timestamp: 2026-08-26T11:14:23.334584+00:00
- actor: claude-code
  id: 01m0yy4sr4w9wxy99pmvw6gkq6
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (local backend), 77 files reviewed, 56 validator runs, 0 findings, 0 confirmed, 0 refuted
    - next: none. The task is in the done column.
  timestamp: 2026-08-26T11:44:02.820673+00:00
- actor: claude-code
  id: 01m0yy5e5gsd2w0t5fc5g7rrsp
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 77 Sources files; `///` lines 16,450 → 6,006; no task-id or plan-file citations; no code line changed (two implementer runs were cut by usage limits and resumed)
    - test: green — swift test, 1056 + 83 tests, 0 failed
    - commit: c0b2b6e
    - review: clean — 77 files, 56 checks, 0 findings; task moved to done
  timestamp: 2026-08-26T11:44:23.728565+00:00
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
- 01M0XGS4FFR5ATBWCME1PCH3EE
position_column: done
position_ordinal: fff980
title: Cut the doc-comment bloat across Router sources
---
## What
The `///` comments narrate essays — edge-case war stories, cross-references, and rationale that repeat the code. Cut them down across `Sources/FoundationModelsRouter/**`, with `Hosting/` and `Session/` first. The rule: a doc comment states the contract — what the symbol does, its parameters, what it returns, and only the constraints the code cannot show. No narration of history, no "(task ^xxxxx)" citations, no restated implementations. Target shape: most member doc comments fit in 1-5 lines; a type-level overview fits in one screen.

Run this AFTER the engine rework — do not polish text that ^bzekmfd deletes.

- [x] Record the baseline first: `rg -c '^\s*///' Sources | awk -F: '{s+=$2} END {print s}'`.
- [x] Pass over `Hosting/`, then `Session/`, then the rest.
- [x] Keep DocC references that still resolve; delete the ones that pointed at removed symbols.

## Acceptance Criteria
- [x] The total `///` line count in `Sources` is at most half the recorded baseline.
- [x] No doc comment cites a kanban task id or a plan file.
- [x] `swift build --build-tests` and the full suite are green.

## Tests
- [x] No behavior change. Run `swift test` — green.

## Workflow
- Use `/tdd` — run the suite before and after each folder pass. #cleanup #docs