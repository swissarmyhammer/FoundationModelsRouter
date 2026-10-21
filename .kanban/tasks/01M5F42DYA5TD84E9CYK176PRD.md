---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f8h8svkyyvktx834w07mz5
  text: |-
    ### implement — changed
    - evidence: 5b9423f7 on branch router-3-session-index (pushed, not merged), on top of 29ae4767 (^zmnm17k). swift test passes 1969 tests in 245 suites (9 known issues), 30 in 16 and 19 in 3. ProjectRegistry and SessionIndex now share JSONLines.replaceFile(_:withLinesOf:).
    - next: merge the branch to main once ACPAgent's ACPA-14 (^kxr2mm7 there) is green. ACPAgent's test target still sees the names as ambiguous at TranscriptStoreTests.swift:503, TranscriptRecordingFixtures.swift:138 and TranscriptStoreTests.swift:53.
  timestamp: 2026-10-21T12:56:15.419482+00:00
- actor: claude-code
  id: 01m5g9fpazwmww5cb7d6cdexee
  text: |-
    ### review — clean
    - evidence: review sha e9b50a2e~1..e9b50a2e — 0 findings (confirmed 0, refuted 0; 7 validator runs attempted, 0 failed, 0 skipped; 6 files reviewed, 0 not reviewed); no prior Review Findings sections
    - next: none — task moved to done
  timestamp: 2026-10-21T22:32:06.751955+00:00
- actor: claude-code
  id: 01m5g9g2y9n4308tzdw6qd59dc
  text: |-
    ### finish iteration 1 — clean
    - review (e9b50a2e): clean — 0 findings; implemented and tested earlier, no implement/test/commit needed this iteration
  timestamp: 2026-10-21T22:32:19.657622+00:00
depends_on:
- 01M5F3EMARATMXFR829ZMNM17K
position_column: done
position_ordinal: ffffffffa580
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