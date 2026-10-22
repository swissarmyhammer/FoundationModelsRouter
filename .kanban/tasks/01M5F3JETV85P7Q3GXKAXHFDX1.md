---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5j2y1gnk494449jcv47mmvh
  text: 'Waits on ^2cqepsd (user decision 2026-10-22): index.md replaces session.json and facts.json. Where this card says facts.json, write the facts into the session''s index.md frontmatter instead (through the ^2cqepsd save path, best-effort and atomic).'
  timestamp: 2026-10-22T15:16:05.781917+00:00
- actor: claude-code
  id: 01m5jkva4cm9z64zyqae1dv2h8
  text: 'Research: addTags/removeTags/setTitle in RouterSessionDirectory throw unknownSession today. The private changeRecord(of:_:) (live: RoutedSessionActor.updateRecord + recordFactsChange; recorded: SessionIndexFile read/change/save + emit) always emits factsChanged, so the no-op rule needs a before/after record compare in both branches. Extras has the same tag rule (InMemorySessionDirectoryState.validate, internal: 1-64 chars, Character.isLetter, ASCII digits, - _ : ., first invalid in name order) but it is not public, so Router gets its own SessionTagRule with the same semantics. Archived sessions: nothing in changeRecord refuses them, so tag/rename on an archived recorded record works as is. Extras SessionDirectory protocol needs no change.'
  timestamp: 2026-10-22T20:11:42.092783+00:00
- actor: claude-code
  id: 01m5jmnjyj3zhpws25sqs3thjc
  text: 'Implementation landed (facts go to the index.md frontmatter, per the 2026-10-22 comment). addTags/removeTags validate every tag with the new SessionTagRule first, then go through changeRecord(of:_:); setTitle goes through the same path. changeRecord now compares the record before and after the change: on no change, a recorded session''s index.md is not written and nothing is emitted, and a live session sends no factsChanged. This also applies to setAdditionalDirectories (same folders = no event); its doc says so. Live path note: RoutedSessionActor.updateRecord still saves index.md on a no-op, with the same content. Tests: extracted the two-router fixture of RouterSessionDirectoryRecordedTests into Helpers/SessionDirectoryRouterPair.swift so the new suite reuses it instead of copying it. Gotcha: restoreSession(id:) in a second router throws sessionNotFound unless it gets recordingRoot:, because the default root is <recordingsDir>/<thatRouterId>/.'
  timestamp: 2026-10-22T20:26:03.090416+00:00
- actor: claude-code
  id: 01m5jmnnzttssy9t3tzfhr8m3x
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Directory/SessionTagRule.swift (new), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/SessionTagRuleTests.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryTagTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryRouterPair.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecordedTests.swift. `swift build --build-tests` clean; full `swift test`: 2139 tests in 261 suites passed (9 known issues come from existing withKnownIssue tests), plus 35 and 19 in the other targets, 0 failures.
    - next: /review
  timestamp: 2026-10-22T20:26:06.202379+00:00
depends_on:
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
- 01M5F3HHXA8XHWQWDZJ2CC8D3F
- 01M5F43CQ0KR0A2E8FA8CAT9XK
- 01M5HS4PZCZH6W43MM72CQEPSD
position_column: doing
position_ordinal: '80'
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
- [x] Failing test first: `addTags(["reviewer"], to: id)` on a live session gives a summary with the tag, `facts.json` has it, and an `events()` stream gets `factsChanged`.
- [x] Add `SessionTagRule` with tests for the length limits and each allowed and refused character.
- [x] `removeTags` and `setTitle` with the same write and event rules; no event for a no-op.
- [x] Persist and read back: tag, restore in a new router, and `sessions(matching: SessionQuery(tag:))` finds it.
- [x] A recorded, not live session: tag it, and its `facts.json` on disk changes.

## Acceptance Criteria
- [x] Add, remove and rename each rewrite `facts.json` and send exactly one `factsChanged`.
- [x] An invalid tag throws `invalidTag` and changes nothing on disk.
- [x] An unknown id throws `unknownSession`.
- [x] After a restore, the query by tag finds the session.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryTagTests.swift`
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionTagRuleTests.swift`
- [x] `swift test --filter "RouterSessionDirectoryTag|SessionTagRule"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api