---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffffab80
title: ProjectStore.projects() lists files the macOS hidden flag marks
---
iCloud sets the BSD `hidden` flag (UF_HIDDEN) on every file in a synced ~/.config. `ProjectStore.projects()` (Recording/ProjectStore.swift:162) lists with `.skipsHiddenFiles`, which drops flagged files as well as dotfiles, so on such a machine it lists no projects. Evidence: `ls -lO ~/.config/acp-agent/projects` shows `hidden` on every .md. Reported by ACPAgent, which fixed the same bug in its profile loader (0fa207a).

Fix: list without `.skipsHiddenFiles`, and skip dotfiles by name (e.g. AppleDouble `._x.md`).

- [ ] Test: a project file with the hidden flag set (chflags hidden) is listed
- [ ] Test: a dotfile `.md` is not listed
- [ ] Fix projects()