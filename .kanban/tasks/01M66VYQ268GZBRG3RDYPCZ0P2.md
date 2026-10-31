---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m66yfrbz1w551mmqw3qc6g0e
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift (SessionInboxFile, SessionInboxMessage, SessionInboxFileError) and Tests/FoundationModelsRouterTests/SessionInboxFileTests.swift (20 test cases).
    - API: write(_:to:), pending(in:), read(_:maxMessageBytes:), reject(_:in:), directory(in:), rejectedDirectory(in:), url(of:in:). Plain `user` gives .user(clientID: "user"); the writer writes plain `user` for that client id and `user:<id>` for others. A reject whose name already exists in rejected/ gets a ULID prefix, so no file is lost. The body is kept byte for byte (no trim).
    - BLOCKER for the official command: `swift test --filter SessionInboxFileTests` in the repo fails at the build of mlx-swift (CompileMetalFile steel_attention.metal): Xcode 27.2 (27B52) has no Metal Toolchain installed (`xcodebuild -showComponent metalToolchain` says 27B47 uninstalled). Fix: `xcodebuild -downloadComponent MetalToolchain`. Also Package.resolved pins FoundationModelsExtras at 6670bc0, which lacks FrontmatterDocument.save(to:) and SessionMessageSender, so a `swift package update` is needed too.
    - Verified instead with a scratch proxy package (copies of the Extras files that the new code needs, plus JSONValue/ULID from Router): 20 tests passed, zero warnings. The repo suite is NOT yet run.
  timestamp: 2026-10-30T17:42:26.431923+00:00
position_column: doing
position_ordinal: '80'
title: 'Add SessionInboxFile: parse, write and reject inbox message files'
---
## What
Create `Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift`. It is the on-disk format of one inbox message (see `mailbox-plan.md`, sections "Layout", "File format", "Write procedure").

- Folder: `<root>/<session-id>/inbox/`. Name of a file: `<ulid>.md`. Folder for bad files: `inbox/rejected/`.
- Use the Extras `FrontmatterDocument` (as `SessionIndexFile` does in `Sources/FoundationModelsRouter/Recording/SessionIndexFile.swift`).
- Frontmatter keys: `id` (MailID, optional; the file name gives it when absent), `from`, `inReplyTo` (optional), `chainDepth` (optional; default is `RouterSessionDirectory.firstChainDepth`). Keep unknown keys in a `[String: JSONValue]` field.
- `from` forms: `session:<ULID>`, `user:<clientID>` (the `SessionMessageSender.user(clientID:)` case), and plain `user` (default for a hand-written file). The Router writes `user:<clientID>` for a UI sender so the client id is not lost.
- The body is the message text. The parse function takes the byte limit as a parameter (`limits.maxMessageBytes` is a property of each directory, not a static value). A body that is too long is a parse failure.
- `chainDepth` less than 1 is a parse failure.
- `write(_:to:)`: write `inbox/.<ulid>.md.tmp`, then rename to `inbox/<ulid>.md`. Create `inbox/` when it is absent.
- `pending(in:)`: list `*.md` files in `inbox/`, skip dot files and names that do not end in `.md`, sort by name.
- `reject(_:in:)`: move a file to `inbox/rejected/`.

Decisions (made in this plan): the delivered file is removed (the ledger is the record). A hand-written `from: session:<id>` is accepted; the trust boundary is the user account.

## Acceptance Criteria
- [ ] A written file reads back with equal id, from, inReplyTo, chainDepth, body and unknown keys.
- [ ] A `.user(clientID:)` sender and a `.session` sender round-trip; plain `user` gives the default user sender.
- [ ] A file with no `id` takes the id from its name.
- [ ] `pending(in:)` ignores `.tmp` files and dot files and returns the names sorted.
- [ ] A file that does not parse (no frontmatter, bad `from`, `chainDepth` below 1, body over the given limit) throws a typed error, and `reject` moves it to `inbox/rejected/`.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/SessionInboxFileTests.swift`: round trip, sender forms, unknown keys, defaults, missing id, ignored names, sort order, reject move, body over a lower limit, chainDepth 0.
- [ ] Run `swift test --filter SessionInboxFileTests` (use the struct name). Expected: all pass, and the output shows the tests ran.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.