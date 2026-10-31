---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m69akeaqyz3htxwmcapmhfp0
  text: |-
    ### implement — stuck
    - blocker: `SessionSendReceipt.Outcome` is not in this repo. It is in the package FoundationModelsExtras: `FoundationModelsExtras/Sources/FoundationModelsExtras/Sessions/SessionSendReceipt.swift` (cases delivered, queued, started, refused). Router uses Extras as a git dependency: `branch: "main"`, locked in Package.resolved at revision a23cd80 (the same revision as the sibling checkout head). Router builds against `.build/checkouts`, not against the sibling folder.
    - Router code cannot use `.sent` until a new Extras commit with `sent` is pushed and the Router pin moves to it. The task bans a pin change, and the run bans a commit. No code was changed in any repo.
    - Outside Router, the places to change after Extras: Extras `InMemorySessionDirectory*` (check for exhaustive switches), Multitool `SessionsToolText+Messages.swift` (switch near the delivered/queued/started cases), `SessionsGraphTypes.swift` (the Outcome mapping near the `.delivered`/`.queued`/`.started` lines), `SessionsGraphMutations.swift` (the Value(...) list of outcome descriptions), plus Multitool tests and `Fixtures/ForwardingSessionDirectory.swift`.
    - Router work that is ready once `sent` exists: `SessionAddressResolution.sendToRecorded(ULID)`, `RouterSessionDirectory.sendToRecorded(_:chainDepth:to:)`, delete `restoreThenDeliver`, `restore(_:through:)`, `restores`; tests in RouterSessionDirectoryInboxTests and SessionAddressResolutionTests (line with `.restoreThenDeliver`).
    - decision needed: how to ship `sent` in Extras (commit and push order, then Router pin move, then Multitool).
  timestamp: 2026-10-31T15:52:38.999923+00:00
- actor: claude-code
  id: 01m69d6e6mqfwgn4bnz2db0f7k
  text: |-
    ### implement — stuck (Multitool part only)
    - Router part is done and green by filter: 79 tests in 6 suites (Delivery, Inbox, SessionAddressResolution, Archive, Message, Launcher) plus 2 public-surface launcher tests. Router pin: Extras 7959524 via `update FoundationModelsExtras` (no edit override).
    - Router changes: `.sendToRecorded(ULID)` replaces `.restoreThenDeliver`; `restoreThenDeliver`, `restore(_:through:)`, `restores`, `recordedSummary(of:in:)` removed; new private `sendToRecorded(_:chainDepth:to:)` writes the inbox file and answers `sent`; launcher is not called. SessionLauncher docs updated (restoreSession stays on the port; the directory no longer calls it). FakeSessionLauncher lost its unused `restoreError`.
    - Multitool: source and test edits are written (SessionsToolText+Messages, SessionsGraphTypes, SessionsGraphMutations, Goldens/sessions.graphql, SessionsToolMessageTests) but NOT built. Blocker: after `update FoundationModelsExtras`, Extras main needs `MLXSpeculativeDecoding` from mlx-swift-lm, and the Multitool pin of mlx-swift-lm (08d789b) lacks it (Router pin d4bab58 has it). Building needs `swift package update mlx-swift-lm` in Multitool, which moves a pin. Not done by order.
    - decision needed: allow the pin move of mlx-swift-lm in Multitool (Package.resolved is gitignored), then build and run the Multitool tests.
    - mailbox-plan.md line "restoreThenDeliver: write the file, then restore" is now wrong (file not edited).
  timestamp: 2026-10-31T16:37:58.612591+00:00
position_column: doing
position_ordinal: '80'
title: 'Send to a recorded session that is not live: write the inbox file, never restore, receipt `sent`'
---
## What
A message to a session must not restore it. A send to a recorded session that is not live writes the file in the `inbox/` of the session and stops. The message is delivered later, when some host opens the session (the watcher then starts and its first scan delivers the file).

- `Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift`: replace the case `.restoreThenDeliver(ULID)` with `.sendToRecorded(ULID)` (line 24, and `reaching(session:)` at line 55). Update the doc comments. An archived session stays refused.
- `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: remove `restoreThenDeliver(_:chainDepth:to:)`, `restore(_:through:)` and the `restores` map. Add `sendToRecorded(_:chainDepth:to:)`: find the folder with `recordedFolder(of:)` (`SessionDirectoryError.unknownSession` when no root holds it), write the file with `writeInboxFile`, and return a receipt with the new outcome `sent` (the file is written, no delivery yet). The directory never calls the launcher for a send. `SessionDirectoryError.noLauncher` stays for `startAgent` only. Update the doc comments of `send(_:)` and the Throws lists.
- `SessionSendReceipt.Outcome` (public): add `sent`. Update every caller of the outcome in the same change, also in the packages that depend on it (the FoundationModelsMultitool `sessions` tool, `SessionsToolMessageOperations`): no deprecated alias, no old overload (see `ARCHITECTURE.md`).
- `mailbox-plan.md` says "`restoreThenDeliver`: write the file, then restore". Do not edit that file (it is untracked and not part of this change). Say in the final report that the line is now wrong.

## Acceptance Criteria
- [ ] `send(_:)` to a recorded session that is not live writes one file in its `inbox/`, returns the outcome `sent` with the id of the message, and never calls the launcher (a launcher that fails the test when it is called).
- [ ] The message is delivered when the session is registered later: the first scan of the watcher puts it in the ledger and starts the turn; the `messageDelivered` event follows.
- [ ] An archived session is still refused; a session id that no root holds still throws `unknownSession`.
- [ ] `restoreThenDeliver`, `restore(_:through:)` and `restores` are gone from the sources.

## Tests
- [ ] Update `Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift`: replace the restore tests (`aRestoreDeliversTheFileItFinds`, the failed-restore test and similar) with: send to a recorded session writes a file and does not call the launcher; register the session later and the message is delivered. Wait on events, not on the clock.
- [ ] Update the other suites that expect a restore on send (find them with `rg "restoreSession|restoreThenDeliver" Tests`), and `SessionAddressResolution` tests.
- [ ] Run the filters for the suites you touch, then the full `swift test` once. Expected: all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.