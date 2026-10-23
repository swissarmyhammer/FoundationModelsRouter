---
position_column: todo
position_ordinal: '80'
title: restoreSession / restoreSessionTree take a hook session key
---
Asked by foundationmodelsacpagent-a5 (2026-10-23), for the user's design: sessions in one process with the same cwd share one snapshot timeline, keyed by sha256 of the resolved cwd. New sessions already pass that key (SessionConfiguration.hookSessionKey -> makeSessionHooks(requestedKey:)), and model-switch replacements carry it through the hook lineage. Restore cannot: restoreSession (Recording/SessionRestoration.swift:145) and restoreSessionTree (Recording/SessionTreeRestoration.swift:233) take no key, so a resumed session falls back to its own id as its hook session key.

Add `hookSessionKey: String? = nil` to both, passed to the restored root's makeSessionHooks(requestedKey:). Sub-agents and same-cwd forks in the restored tree inherit it as they do today. nil keeps today's behaviour. Additive, not a breaking change. The SessionLauncher protocol's restoreSession(id:) is unchanged.

- [ ] Failing test: a session restored with restoreSession(hookSessionKey: "k") runs its hooks under session key "k"; without it, under its own id as today
- [ ] Same for restoreSessionTree: the root gets "k", and a restored sub-agent / same-cwd fork inherits it
- [ ] Parameter added to both, with doc comments pointing at SessionConfiguration.hookSessionKey
- [ ] Reply to foundationmodelsacpagent-a5 with the pushed sha and the exact signatures