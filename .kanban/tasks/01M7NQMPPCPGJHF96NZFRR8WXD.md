---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qhrpqm0z0f1pvr21mgjh39
  text: |-
    Research: FoundationModelsExtras 5d86d34 (in b87233e) made the in-memory directory start a new root session for each `.agent` send, with the folder of the address else the folder of the sender. `newestLiveRoot` there stays for the folder address only. The Router resolver had one caller of `newestRoot` with an agent id (`reaching(agent:in:among:)`). No file in docs, README.md or ARCHITECTURE.md tells the agent-address rule.

    Implementation: `SessionAddress.resolution` now gives `.startAgent(agentID:folder: folder ?? sender folder)` for each `.agent`. `reaching(agent:in:among:)` is removed. `newestRoot(among:in:)` has no `agentID` parameter and a non-optional folder (the folder address is its only caller). Doc comments of `SessionAddressResolution`, `startAgent` case, `resolution(from:among:recordedSummary:)`, `RouterSessionDirectory.send(_:)` and `startAgent(_:in:for:chainDepth:userHeader:)` updated.

    Tests: resolver agent rows now expect a start also with a live root session of the agent; the agent part of the link test and the "folder of the sender through a link" test are removed (an agent address does not compare folders now). `RouterSessionDirectoryMessageTests.anAgentWithALiveRootDeliversToIt` became `anAgentWithALiveRootStartsANewOne`. New in `RouterSessionDirectoryDefaultNameTests`: `anAgentAddressStartsANewSessionWhenARenamedSessionOfTheAgentIsLive`, `anAgentAddressStartsASessionWithTheNextNameWhenTheBaseNameIsLive` (title `claude-code-2`). The folder rows of the resolver table and `aFolderWithALiveRootDeliversToIt` keep the folder rule. RED seen: 6 issues in 8 tests; GREEN: 8 tests in 3 suites pass.
  timestamp: 2026-11-18T14:42:55.348213+00:00
- actor: claude-code
  id: 01m7qhrs80per80jv2h7f58ptq
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/SessionAddressResolutionTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryDefaultNameTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryMessageTests.swift. Full `swift test`: exit 0, 2891 tests in 336 suites pass, plus 48 tests in 26 suites and 19 tests in 3 suites; no compiler warnings.
    - next: /review
  timestamp: 2026-11-18T14:42:57.920650+00:00
- actor: claude-code
  id: 01m7qhvt358vwatvcyz2eq1ykz
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b1ad24e6) — 0 findings, 0 confirmed, 0 refuted; 5 files reviewed, 2 .kanban files not reviewed (.reviewignore).
    - next: none. The task is in done.
  timestamp: 2026-11-18T14:44:37.093881+00:00
- actor: claude-code
  id: 01m7qhw420xnkmjec52z3xbe0d
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — SessionAddressResolution.swift, RouterSessionDirectory.swift, 3 test files
    - test: green — swift test in the implement step, 2891 tests in 336 suites (+48, +19), 0 failures, 0 warnings
    - commit: b1ad24e6
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-18T14:44:47.296413+00:00
depends_on:
- 01M7NQM9KJ3QNMNQDA6SWQ7JNM
position_column: done
position_ordinal: ffffffffffac80
title: An agent address always starts a new session (D199 (e))
---
## Goal

Multitool sends `.agent(id:folder:)` only when no session has the slug `<name>` (Multitool brief `mt-brief-at-sessions.md`). Thus the Router does not look for the newest root session of the agent. Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, item 5. Decision D199 (e).

## Current behavior

`Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift:60-77` resolves `.agent` to the newest live root session of the agent with `newestRoot` (`:126-140`), and only starts a session (`startAgent`, `RouterSessionDirectory.swift:1365`) when none is live.

## Change

- `.agent` always starts a new root session of the agent with `startAgent`. The session gets the default name (the task that this task depends on).
- The folder address keeps `newestRoot`.
- Remove the agent branch of `newestRoot` (the `agentID` parameter) if no other caller uses it.
- Update the doc comments and the docs that tell the old behavior.

## Tests

- [x] `.agent` starts a new session also when a renamed session of that agent is live in the folder.
- [x] `.agent` starts a new session also when a session of that agent with the default name is live (Multitool resolves the slug first; the Router does not).
- [x] The new session has the default name, for example `claude-code-2` when `claude-code` is used.
- [x] A folder address still gives the newest root session in the folder. #d199