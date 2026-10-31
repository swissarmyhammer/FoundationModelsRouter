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
- actor: claude-code
  id: 01m68gk6jqd13r0kkvgqjh1abc
  text: |-
    ### review — findings
    - evidence: review sha HEAD~2..HEAD. 3 findings: SessionInboxFile.swift:169, SessionInboxFile.swift:426, SessionInboxFileTests.swift:31.
    - next: fix the 3 open items. Run the review again.
  timestamp: 2026-10-31T08:18:08.087239+00:00
- actor: claude-code
  id: 01m68gkhna0k036zv2ra0c734m
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionInboxFile.swift, SessionInboxFileTests.swift
    - test: green — swift test, 2136 tests passed (4 older tests fixed; pins updated locally, Package.resolved is gitignored)
    - commit: 62f6b382, 4b2fa8b8
    - review: findings — SessionInboxFile.swift:169, SessionInboxFile.swift:426, SessionInboxFileTests.swift:31
  timestamp: 2026-10-31T08:18:19.434369+00:00
- actor: claude-code
  id: 01m68grhv6txjsasmdpth4q1ye
  text: |-
    ### implement — changed
    - evidence: SessionInboxFile.swift and SessionInboxFileTests.swift. `swift test --filter SessionInboxFileTests`: 28 tests in 1 suite passed. RED run first: build failed (no `maxMessageBytes` on write, no `reservedUnknownKey`).
    - Finding 1: `write(_:to:maxMessageBytes:)` now takes the same limit as `read` and throws `bodyTooLong`. Read and write share `checkBodyLength` and `checkChainDepth`.
    - Finding 2: `.user(clientID: "")` is refused on write with `invalidSender(value: "user:")`. `inboxText` is now optional (nil for an empty client id).
    - Finding 3: new round-trip test with `inReplyTo: nil` and empty unknown keys. `makeMessage` takes inReplyTo, chainDepth, text and unknownKeys parameters.
    - Same-cause cleanup (other write/read mismatches in the file): chain depth below 1 is refused on write; an unknown key named like a known key (`id`, `from`, `inReplyTo`, `chainDepth`) is refused on write with the new `reservedUnknownKey` error (the encoder dropped it silently, so the read gave back a different message). New tests: exact limit, byte count (not character count), default user sender round trip.
    - Note: the write signature changed; the only callers are the tests. The build prints one `missing creator for mutated node` warning from the mlx-swift bundle; it is a build system message, not from this code.
  timestamp: 2026-10-31T08:21:03.462146+00:00
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

## Review Findings (2026-10-31 03:14)

> Scope: `review sha HEAD~2..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift, so its declarations are unread

- [x] `Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift:169` `completeness/inverse-operation-coverage` — `write` has no length check on `message.text`, but `read` rejects any body longer than `maxMessageBytes` (`bodyTooLong`). The writer can therefore produce a file that the reader always moves to `rejected/`. The write and read sides of the size contract do not match. Either check `message.text.utf8.count` in `write` against the same `SessionMessageLimits.maxMessageBytes` and throw the matching error, or document in the write doc comment that the caller must enforce the limit. Add a test for whichever rule is chosen.
- [x] `Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift:426` `completeness/inverse-operation-coverage` — The writer side of `inboxText` emits `user:` plus the client id even when the client id is empty. The reader side (line 441) requires a non-empty client id after `user:`, so `write` succeeds and then `read` of the same file throws `invalidSender`. The round trip is not closed for `.user(clientID: "")`. Guard the write side so an empty client id cannot be written (precondition, or map it to the default `user` form), or make the reader accept `user:` with an empty id. Add one round-trip test for the chosen behaviour.
- [x] `Tests/FoundationModelsRouterTests/SessionInboxFileTests.swift:31` `completeness/inverse-operation-coverage` — The shared `makeMessage` always sets a non-nil `inReplyTo`, so no round-trip test writes a message with no `inReplyTo`. The writer omits the key when it is nil (`encodeIfPresent`), and only the defaults test reads a file without the key. The write-then-read path for a nil `inReplyTo` is never exercised. Add one round-trip test that writes a message with `inReplyTo: nil` and unknown keys empty, then reads it back and asserts equality with the original message.
