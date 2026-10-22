---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5j2y1gnk494449jcv47mmvh
  text: 'Waits on ^2cqepsd (user decision 2026-10-22): index.md replaces session.json and facts.json. Where this card says facts.json, write the facts into the session''s index.md frontmatter instead (through the ^2cqepsd save path, best-effort and atomic).'
  timestamp: 2026-10-22T15:16:05.781917+00:00
depends_on:
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
- 01M5F3HHXA8XHWQWDZJ2CC8D3F
- 01M5F43CQ0KR0A2E8FA8CAT9XK
- 01M5HS4PZCZH6W43MM72CQEPSD
position_column: todo
position_ordinal: '8880'
title: 'ROUTER-3: addTags, removeTags and setTitle write facts.json and send factsChanged (covers ROUTER-2)'
---
## Goal
Tags and the title change only through the directory: `addTags`, `removeTags` and `setTitle` validate, rewrite `facts.json`, and send `factsChanged`. This is the ROUTER-2 behavior that ROUTER-3 carries (tags at creation already come from `SessionConfiguration.tags`, ROUTER-1).

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-2-session-tags and /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.3
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 7 (`factsChanged`), 8.2 (tag rule), 13.3

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionTagRule.swift`: a tag has 1 to 64 characters, each a letter, a digit, `-`, `_`, `:` or `.`; another tag throws `SessionDirectoryError.invalidTag(tag)`. Examples that pass: `reviewer`, `travel`, `scheduled`, `kanban:task-42`.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: replace the provisional bodies of `addTags(_:to:)`, `removeTags(_:from:)`, `setTitle(_:of:)`:
  - a live session: `updateFacts` on the session (ROUTER-1 card), which rewrites `facts.json`;
  - a recorded session that is not live: read, change and write its `facts.json` on disk;
  - an unknown id throws `unknownSession(id)`;
  - each change that alters the facts sends `factsChanged(summary)`; a call that changes nothing (a tag that is already there) gives the summary and sends no event;
  - an archived session can still be tagged and renamed (only messages are refused) unless the spec owner says otherwise.
- Validate all tags of a call before writing any.

## Subtasks
- [ ] Failing test first: `addTags(["reviewer"], to: id)` on a live session gives a summary with the tag, `facts.json` has it, and an `events()` stream gets `factsChanged`.
- [ ] Add `SessionTagRule` with tests for the length limits and each allowed and refused character.
- [ ] `removeTags` and `setTitle` with the same write and event rules; no event for a no-op.
- [ ] Persist and read back: tag, restore in a new router, and `sessions(matching: SessionQuery(tag:))` finds it.
- [ ] A recorded, not live session: tag it, and its `facts.json` on disk changes.

## Acceptance Criteria
- [ ] Add, remove and rename each rewrite `facts.json` and send exactly one `factsChanged`.
- [ ] An invalid tag throws `invalidTag` and changes nothing on disk.
- [ ] An unknown id throws `unknownSession`.
- [ ] After a restore, the query by tag finds the session.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryTagTests.swift`
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionTagRuleTests.swift`
- [ ] `swift test --filter "RouterSessionDirectoryTag|SessionTagRule"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api