---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7wqgb3mj0avnwncrzt8s651
  text: 'Research: the folder target has uses in SessionAddressResolution.swift (the `.folder` branch, `reaching(folder:among:)`, `newestRoot(among:in:)`, `noRootSessionInTheFolderReason`, and the doc lines), SessionAddressResolutionTests.swift (the folderRows, an unknown-sender row to a folder, the link and trailing-slash test with its `LinkedFolder` helper), and RouterSessionDirectoryMessageTests.swift (two folder send tests). IntegrationTests, docs and README have no use. `RouterSessionDirectory.comparablePath(of:)` stays: other code uses it. No sourcekit-lsp process had its cwd in this repo.'
  timestamp: 2026-11-20T14:59:24.916232+00:00
- actor: claude-code
  id: 01m7wrez8gppdn9wggv598pp0e
  text: |-
    ### implement — changed
    - evidence: Extras pin is 41c13c93 in root and IntegrationTests (Package.resolved is gitignored). 3 files: Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift, Tests/FoundationModelsRouterTests/SessionAddressResolutionTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryMessageTests.swift. `swift build --build-tests` in IntegrationTests: exit 0. One full `swift test`: exit 0, 3250 tests in 364 suites passed, plus 54 and 19 in the other test products; 0 failures, no warning from repo files.
    - next: /review. The `.agent(id:folder:)` rows and tests stay. The fixtures `other`, `nested` and the helper sessions stay in the live set as sessions that the tag and agent rules must ignore.
  timestamp: 2026-11-20T15:16:08.592984+00:00
position_column: doing
position_ordinal: '80'
title: Remove the folder target from the address resolution (D199 (e) change)
---
User decision 2026-11-20 (D199 (e) changed, brief from testudoapp-9a): a mention target is only an id, a short id or a slug. `#tag` still names a group. `@<agent name>` still starts the agent. The old forms `@agent:/path` and a folder path alone go, with no compatibility.

The Router reads these forms as typed `SessionAddress` cases from Extras. The parsing of `@agent:/path` text is in Multitool (^1t8r5re). The Router part is the `.folder` case: the newest live root session in a folder. Extras must remove `case folder(URL)` first (brief sent to foundationmodelsextras-9e). `case agent(id:folder:)` stays. Its folder is the folder in which the new session starts.

- [x] Move the Extras pin to the commit that removes `SessionAddress.folder` (root and IntegrationTests).
- [x] In `Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift`, remove the `.folder` branch, `reaching(folder:among:)`, `newestRoot(among:in:)`, `noRootSessionInTheFolderReason` and the doc lines about a folder address and `@agent:/path`.
- [x] Remove other uses of `.folder` and of the reason text in Sources (grep `noRootSessionInTheFolderReason`, `.folder(`, `@agent:/path`).
- [x] Remove the folder tests in `Tests/FoundationModelsRouterTests/SessionAddressResolutionTests.swift` and other tests that send to a folder. Keep the tests of `.agent` with a folder as the start folder.
- [x] `swift test` passes (one full run).

Send the sha to testudoapp-9a after the push.