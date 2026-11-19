---
assignees:
- claude-code
depends_on:
- 01M7RSS1HNR7E0G704X1VESQJJ
position_column: todo
position_ordinal: '8680'
title: A fork goes through the host launcher, so the host gives its surface before the first prompt runs (D205)
---
## Goal

A fork that the `sessions` tool makes (`fork session`) runs on the tools of the source, and its first prompt starts at once. When a client later resumes the fork, the host stops the live fork and restores it on its own surface (the MCP servers and directories of the client or of the source). That stop can cancel the first prompt, and the first prompt ran on the wrong surface. Request from foundationmodelsacpagent-9e (D205).

## Decision

The Router already asks the host to build a session through `SessionLauncher` (`Sources/FoundationModelsRouter/Directory/SessionLauncher.swift:39`) for `startAgent` and for a restore. A fork uses the same way:
- Add a launcher operation for a fork, for example `forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession`, with the source id, the cut position, and the fork id that the directory chose. Give it a default implementation that keeps the current behavior (the Router builds the fork with the tools of the source), so a launcher that does not implement it compiles.
- `RouterSessionDirectory.fork(_:)` calls the launcher operation when the directory has a launcher, so the host builds the fork with its surface. Then the directory registers the fork and mails the first prompt. Thus no prompt runs before the host gave the surface, and the host holds the fork from its start (no stop and restore).
- Keep the record, the recording node, the name, the hooks and the cut rule of ^3hxcxee.
- Write the rule in the doc of `fork(_:)` and of the launcher operation.

## Tests

- [ ] With a launcher that implements the fork operation: the launcher gets one call with the source, the cut position and the fork id; the fork uses the session that the launcher gave; the first prompt runs on that session.
- [ ] With a launcher that does not implement it: the fork works as before.
- [ ] The first prompt does not start before the launcher returns.
- [ ] A launcher that throws: the fork is refused, nothing is registered, no recording node stays.

## After

Push when green. Send the sha and the name of the launcher operation to foundationmodelsacpagent-9e. #d205