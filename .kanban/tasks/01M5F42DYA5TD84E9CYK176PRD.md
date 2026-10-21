---
assignees:
- claude-code
depends_on:
- 01M5F3EMARATMXFR829ZMNM17K
position_column: todo
position_ordinal: '9280'
title: 'ROUTER-3: Copy ProjectRegistry (projects.jsonl) from ACPAgent Transcripts/ into Router Recording/'
---
## Goal
`ProjectRegistry` (`projects.jsonl` in the user layer) becomes a public Router type with the same file name and line format (D72).

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory (second paragraph)
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.2

## Why only this depends_on
Like the `SessionIndex` card, this is a copy of existing code with no ROUTER-1 or EXTRAS-3 type; it depends only on that card for the shared `JSONLines` helper.

## What
- Copy `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Sources/FoundationModelsACPAgent/Transcripts/ProjectRegistry.swift` to `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/ProjectRegistry.swift` as public `ProjectRegistryRecord` and `ProjectRegistry` (`recordSessionStart(workingDirectory:at:)`, `projects()`), using the `JSONLines` helper of the `SessionIndex` card.
- Copy `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/ProjectRegistryTests.swift` into Router's tests. ACPAgent keeps its copy until ACPA-14.
- Re-run the ACPAgent build check of the `SessionIndex` card for the `ProjectRegistry*` names.

## Subtasks
- [ ] Failing test first: the copied `ProjectRegistryTests` fail to compile in Router until the type exists.
- [ ] Compatibility test: a `projects.jsonl` literal in the ACPAgent format reads back to the expected records; a revisit updates `lastSeen` in place, with no second line.
- [ ] Add the public types with doc comments.
- [ ] Public surface test for `SessionIndex` and `ProjectRegistry` without `@testable`.

## Acceptance Criteria
- [ ] The copied `ProjectRegistryTests` pass in Router with only import changes.
- [ ] An old-format `projects.jsonl` reads to the same records.
- [ ] The public surface test compiles and passes.
- [ ] The ACPAgent build result for the `ProjectRegistry*` names is recorded on the card.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/ProjectRegistryTests.swift`
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterPublicSurfaceTests/SessionRecordPublicSurfaceTests.swift`
- [ ] `swift test --filter "ProjectRegistry|SessionRecordPublicSurface"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording #cross-repo