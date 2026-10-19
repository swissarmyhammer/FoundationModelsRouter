---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffff9480
title: A root session that does a code change by hand gets one hint to give it to an agent
---
Request from foundationmodelsacpagent-a5 (owner design). Bench: 32 instances started no agent; with a system-prompt rule the root still read and analysed first, so the work ran twice.

A root session (no parentCall, no agentSpawn) whose original tools include an Extras `AgentLaunching` tool with a non-empty `launchableAgents()` list, and that has not called `agents` with op "start agent", gets ONE hint appended to the outer, model-facing tool result. It fires at the first file edit or the 3rd code read, whichever comes first; both are configurable through `SessionConfiguration.agentDelegationHint`.
- Inner calls (runCode → tools.files.*) are counted through the Extras `ToolCallWitness` on the root MountSite. Outer calls are counted by the Router decorator.
- The text names an agent only when exactly one launchable entry matches the code keywords. Otherwise it says "the agent whose description matches".
- At most one hint per session. No hint in a child session.
- The hint is advice only: it never blocks or changes a call, takes no lease and queues no mail, so the no-work idle is unchanged.
- The decorator sits over the capping layer, so the hint is never truncated. A pending envelope gets no hint; the hint stays due for the next result.

Depends on Extras: ToolCallWitness + AgentLaunching (foundationmodelsextras-8f). Agents conforms its tool (foundationmodelsagents-93).

TDD: failing tests first in AgentDelegationHintTests.