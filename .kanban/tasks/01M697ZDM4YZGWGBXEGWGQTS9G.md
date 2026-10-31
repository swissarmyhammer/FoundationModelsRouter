---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m69acrqgcb6w5xtjtz4gspfv
  text: |-
    ### implement — changed
    - evidence: doc comments only in SessionInboxWatcher.swift (type doc), RouterSessionDirectory.swift (`register`, `scanInbox(of:)`). The text now says: one directory delivers for each session; the code makes no root check and no claim; two directories on one folder can both deliver a file; the host must not run two live copies of one session. rg over Sources/ found no other doc that says delivery needs root ownership (the other hits are the recorder lock docs). swift build: complete, no source warning (only the existing mlx bundle build-system warning).
    - next: the full suite runs in the test step.
  timestamp: 2026-10-31T15:49:00.272187+00:00
- actor: claude-code
  id: 01m69ahcfeaamh3fk748wxp14c
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (cd7a3030): 0 findings, 0 confirmed, 0 refuted. Docs checked against code: the Directory folder has no root-ownership check, no lock and no claim; the three doc comments (SessionInboxWatcher type doc, `register`, `scanInbox(of:)`) say the same rule and match the code. No doc in Sources/ claims that root ownership is enforced for delivery.
    - next: none; task in done.
  timestamp: 2026-10-31T15:51:31.566084+00:00
- actor: claude-code
  id: 01m69ahq7hqw4qdn0hm08vn1md
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — doc comments in SessionInboxWatcher.swift, RouterSessionDirectory.swift
    - test: green — swift test, 2171 tests, 0 failures
    - commit: cd7a3030
    - review: clean — 0 findings, task done
  timestamp: 2026-10-31T15:51:42.577612+00:00
position_column: done
position_ordinal: ffffffffce80
title: 'Inbox: write the single-delivering-process rule in the code docs'
---
## What
`mailbox-plan.md` says "Only the process that owns the root delivers". The code does not enforce this: the root owner is held by the recorder (`Sources/FoundationModelsRouter/Recording/Sinks.swift`, `RecordingRootOwnership` in `RecordingRootLock.swift`), the directory cannot see it, and `SessionMessageLedger` has always appended to `messages.jsonl` with `JSONLAppend`, not through the recorder. The decision (user, 2026-10-31): do not build a lock or a claim now. One process delivers for each session. Make the docs say what the code does.

- `Sources/FoundationModelsRouter/Directory/SessionInboxWatcher.swift`: correct the type doc. It must not say that only the owner delivers. Say: one directory delivers for each session; two directories that watch one folder can both deliver a file; the host must not run two live copies of one session.
- `RouterSessionDirectory.swift`: put the same rule in the doc comments of `register` (watcher start) and `scanInbox(of:)`.
- Do not change behavior. Do not add a root check or a claim file.

## Acceptance Criteria
- [ ] No doc comment in `Sources/` says or implies that the code enforces root ownership for delivery.
- [ ] The single-delivering-process rule is in the watcher type doc, `register` and `scanInbox(of:)`.
- [ ] `swift build` shows no new warning; behavior and tests are unchanged.

## Tests
- [ ] No new test (documentation only). Run the full `swift test` once. Expected: all pass, same counts as before.

## Workflow
- Documentation task: edit comments only, then run the full suite once.