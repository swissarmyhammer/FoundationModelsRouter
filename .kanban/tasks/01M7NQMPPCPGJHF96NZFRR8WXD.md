---
assignees:
- claude-code
depends_on:
- 01M7NQM9KJ3QNMNQDA6SWQ7JNM
position_column: todo
position_ordinal: '8180'
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

- [ ] `.agent` starts a new session also when a renamed session of that agent is live in the folder.
- [ ] `.agent` starts a new session also when a session of that agent with the default name is live (Multitool resolves the slug first; the Router does not).
- [ ] The new session has the default name, for example `claude-code-2` when `claude-code` is used.
- [ ] A folder address still gives the newest root session in the folder. #d199