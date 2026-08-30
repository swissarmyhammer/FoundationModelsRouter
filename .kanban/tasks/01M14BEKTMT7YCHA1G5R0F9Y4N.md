---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m16wsse194zmnme9mbhz0xfv
  text: |-
    Research and measurement, before the change.

    The DocC route from comment 1 of ^hhtc4v7 works as written. The baseline run gives 85 warnings. Five of them come from the two files this card names, and all five come from ToolInvocationRecord.swift:

    ```
    warning: 'RunToCompletionRunner' doesn't exist at '/FoundationModelsRouter/ToolInvocationRecord'
      --> ../Hosting/ToolInvocationRecord.swift:4:8-4:29
    warning: 'BackgroundToolRunner' doesn't exist at '/FoundationModelsRouter/ToolInvocationRecord'
      --> ../Hosting/ToolInvocationRecord.swift:4:37-4:57
    warning: 'ContextBindingTool' doesn't exist at '/FoundationModelsRouter/ToolInvocationRecord'
      --> ../Hosting/ToolInvocationRecord.swift:5:14-5:32
    warning: 'OperationEventSink' doesn't exist at '/FoundationModelsRouter/ToolInvocationRecord'
      --> ../Hosting/ToolInvocationRecord.swift:8:54-8:72
    warning: 'OperationEventSink' doesn't exist at '/FoundationModelsRouter/ToolInvocationRecord'
      --> ../Hosting/ToolInvocationRecord.swift:9:30-9:48
    ```

    Discovery 1: the card expects FOUR warnings for the two runner names, two in each file. Only TWO of them are real. `ToolMounting.swift` gives NO warning, because `enum ToolMounting` (line 4) is itself internal. Its doc comments never enter the public symbol graph, thus DocC never reads them. The links in that file are still wrong for a reader, and the card orders their repair, so this task repairs them. But they were never four warnings, and the count cannot fall by four.

    Discovery 2: acceptance criterion 1 is wider than the "What" section. It says NEITHER FILE has a symbol link to an internal symbol. Beside the two runner types, these targets are internal too:
    - `ContextBindingTool` (Hosting/ContextBindingTool.swift:5) — in both files.
    - `OperationEventSink` (Hosting/OperationEventSink.swift:4) — twice in ToolInvocationRecord.swift.
    - `makeWrapped(tool:sessionID:mailbox:sink:op:configuration:)` — the peer overload inside the internal `ToolMounting`, linked from ToolMounting.swift.

    Each of these is repaired too, because criterion 1 cannot be checked while one of them stays. Every one of these repairs REMOVES a warning; none adds one.

    Access levels checked and confirmed public, thus these links stay as links: `ToolMount`, `ToolMount.Mode.background`, `ToolMount.Mode.runToCompletion` (Hosting/ToolMount.swift:5-12), `BackgroundTool.mount` (Hosting/BackgroundTool.swift:9,12), `ToolContext` (Hosting/ToolContext.swift:10), `SessionMailbox` (Hosting/SessionMailbox.swift:15).
  timestamp: 2026-08-29T13:54:28.929029+00:00
- actor: claude-code
  id: 01m16wt2x636p3gqdn53zkzxpv
  text: |-
    The changes, and why each form was chosen.

    `Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift` — this doc comment IS published, because `ToolInvocationRecord` is public. A reader of the published page cannot look up an internal name, thus each link that has a public equivalent becomes that link:
    - ``RunToCompletionRunner`` becomes ``ToolMount/Mode/runToCompletion``.
    - ``BackgroundToolRunner`` becomes ``ToolMount/Mode/background``.
    - ``ContextBindingTool`` becomes the plain code text `ContextBindingTool`, named as internal. There is no public equivalent.
    - ``OperationEventSink`` and ``OperationEventSink/post(invocation:)`` become one plain code text, `OperationEventSink.post(invocation:)`, named as internal. There is no public equivalent.

    `Sources/FoundationModelsRouter/Hosting/ToolMounting.swift` — this doc comment is NOT published, because `ToolMounting` is internal. Only a reader of the source sees it, and that reader wants the exact decorator type the function returns. Thus each internal name becomes plain code text and keeps its own name:
    - ``BackgroundToolRunner``, ``RunToCompletionRunner`` and ``ContextBindingTool`` become `BackgroundToolRunner`, `RunToCompletionRunner` and `ContextBindingTool`, named as internal.
    - ``makeWrapped(tool:sessionID:mailbox:sink:op:configuration:)`` becomes plain code text with the same name.
    - ``BackgroundTool/mount`` stays a link. `BackgroundTool` is public.

    Both files keep every doc comment. No access modifier changed in any file. The diff holds doc comment lines only.
  timestamp: 2026-08-29T13:54:38.630304+00:00
- actor: claude-code
  id: 01m16wtbdx9nx2aqf54r8ar4mt
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift, Sources/FoundationModelsRouter/Hosting/ToolMounting.swift. DocC through `xcrun docc convert` with a symbol graph: 85 warnings before, 80 after. The set difference names 5 removed and 0 added — the two runner links (`RunToCompletionRunner`, `BackgroundToolRunner`), `ContextBindingTool`, and `OperationEventSink` twice, all at ToolInvocationRecord.swift. `swift build`: Build complete, exit 0. `swift test`: 1103 tests in 116 suites passed with 2 known issues, plus 83 tests in 10 suites passed; exit 0 over two runs.
    - note: the card expects four warnings for the two runner names. Only two exist. `ToolMounting.swift` gives no warning at all, because `enum ToolMounting` is internal and never enters the public symbol graph. Its links are still repaired, as the card orders. The first `swift test` after the build printed "Some test targets reported failures" with no `✘` line and exit 1; two later runs are clean, exit 0, so the first run does not repeat. The change touches doc comment text only and can reach no test.
    - next: `/review`.
  timestamp: 2026-08-29T13:54:47.357270+00:00
- actor: claude-code
  id: 01m16xajdkz32dy7t32z7wk7xp
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` — Build complete, 0 errors, 0 warnings in Sources/ and Tests/ (the one build-log warning is from the mlx-swift resource plugin bundle, not project code). `swift test` — two test-run reports, both pass: 1103 tests in 116 suites passed with 2 known issues (pre-existing, intentional `withKnownIssue` checks in RealModelHarness.swift and BoundedWait.swift, unrelated to this task's scope); 83 tests in 10 suites passed. 0 failures, 0 skipped tests across both runs.
    - next: none. The working tree still holds the doc-comment-only change to `Sources/FoundationModelsRouter/Hosting/ToolMounting.swift` for this task. No test was changed or weakened.
  timestamp: 2026-08-29T14:03:38.803731+00:00
- actor: claude-code
  id: 01m16xdezfra1ekxya2pexg6zw
  text: |-
    ### commit — changed
    - evidence: 5379087 fix(hosting): repair DocC links to internal runners in doc comments, 5 files changed
    - next: none
  timestamp: 2026-08-29T14:05:13.583154+00:00
- actor: claude-code
  id: 01m16xjj0bwptx79va1cv6fyy7
  text: |-
    ### review — clean
    - evidence: `review sha 5379087~1..5379087` — 0 findings, 0 confirmed, 0 refuted, 7 validator runs attempted, 0 failed. 1 source file reviewed: Sources/FoundationModelsRouter/Hosting/ToolMounting.swift. The 4 `.kanban/` files in the commit are excluded by `.reviewignore`. No prior `## Review Findings` section is on the card, and each acceptance and test item is checked.
    - note: the card names two files. Commit b26ee0f, from a different session, deleted `Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift` while this task ran. Its replacement, `Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift`, uses plain code text and holds no link to an internal symbol. Thus that half of the defect is gone, not open.
    - next: none. The card moves to `done`.
  timestamp: 2026-08-29T14:08:00.523917+00:00
- actor: claude-code
  id: 01m16xk16zq1k8gg99svct83ze
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 2 files; DocC warnings 85 before, 80 after, 0 added
    - test: green — swift test, 1103 tests in 116 suites plus 83 in 10 suites, 0 failures, 0 skipped
    - commit: 5379087 — 5 files, staged by path only because another session was committing to the same tree
    - review: clean — zero findings; task moved to done
  timestamp: 2026-08-29T14:08:16.095802+00:00
position_column: done
position_ordinal: ffff9d80
title: Repair the DocC links to internal runners in the Hosting doc comments
---
## What

Two source doc comments link the internal types `BackgroundToolRunner` and `RunToCompletionRunner`. DocC cannot resolve either name, because the symbol graph holds public symbols only. Task ^hhtc4v7 repaired the same two names in `RoutedSession.md`; these two files stayed outside its scope.

- `Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift`, the type doc comment: ``RunToCompletionRunner`` and ``BackgroundToolRunner``.
- `Sources/FoundationModelsRouter/Hosting/ToolMounting.swift`, the doc comment of `makeWrapped(tool:sessionID:mailbox:sink:op:configuration:)`: ``BackgroundToolRunner`` and ``RunToCompletionRunner``.

Rewrite each as plain code text, or link the public equivalent. ``ToolMount/Mode/background`` and ``ToolMount/Mode/runToCompletion`` carry the same meaning; `RoutedSession.md` now uses them. Do not widen the access level of the two runner types. They are correctly internal.

## Acceptance Criteria
- [x] Neither file has a symbol link to an internal symbol.
- [x] No source file changed its access level.

## Tests
- [x] Build the documentation and confirm the four warnings for these two names are gone. The package has no DocC plugin, so use `xcrun docc convert` over the catalog with a symbol graph. Comment 1 of ^hhtc4v7 gives the three commands.
- [x] Run `swift build`. It succeeds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #docs