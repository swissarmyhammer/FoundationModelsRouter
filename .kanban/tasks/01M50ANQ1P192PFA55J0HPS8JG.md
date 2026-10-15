---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50b0m5g067mrsgw2gjrxp60
  text: 'Research done. Extras moved to dbd91de in the root and in IntegrationTests (stopped only the Router sourcekit-lsp, pid 66006). UserPresence is `Sendable, Equatable` with no raw value, so the sidecar slice maps it by hand ("interactive"/"headless"). RunPlane.userPresence is a nonisolated let, so the actor reads the presence from its run plane for the sidecar, and the fork gets it through `RunPlane(clock:userPresence:)` on childRunPlane. I do not add a second stored copy on the actor: two copies could disagree. makeSessionToolWiring gets a `userPresence:` parameter; the root and the restore sites pass it.'
  timestamp: 2026-10-15T17:50:59.248889+00:00
- actor: claude-code
  id: 01m50bky5cr38307qwnjkzhn60
  text: 'Implementation landed (not committed). API: `SessionConfiguration.userPresence: UserPresence` (init parameter `userPresence: UserPresence = .interactive`), the same defaulted parameter on the internal flat `makeSession(grammar:...)`, and `@_exported import enum FoundationModelsExtras.UserPresence` in Hosting/OperationVocabulary.swift. Wiring: `makeSessionToolWiring(...userPresence:)` makes `RunPlane(clock:userPresence:)` for the root and the restore; the fork makes `RunPlane(clock: runPlane.clock, userPresence: runPlane.userPresence)`; the sidecar records `self.runPlane.userPresence`. Design note: the actor keeps no second stored copy of the presence; the run plane holds the one copy, so the fork child init and the sidecar read it from there (two copies could disagree). Sidecar slice: `userPresence: String?` with `Persistable.UserPresenceName` (raw "interactive"/"headless", exhaustive switches) and `restoredUserPresence`; nil and an unknown name read as `.interactive`, and an unknown name writes a warning log under the new `LogMetadataKey.userPresence`. No schema version change. Red first (assert, no hang): 8 issues in the new tests before the wiring (headless answer, question events, runSettled position, run plane presence, fork, restore root, restore fork). Green after: touched suites `Test run with 50 tests in 4 suites passed` + `Test run with 1 test in 1 suite passed`; full suite `Test run with 1735 tests in 210 suites passed after 6.814 seconds with 1 known issue` (the known issue is the existing withKnownIssue in RealModelHarnessTests), `26 tests in 14 suites passed`, `19 tests in 3 suites passed`; IntegrationTests `swift build --build-tests` Build complete, zero Router warnings.'
  timestamp: 2026-10-15T18:01:32.076011+00:00
- actor: claude-code
  id: 01m50bm2vnrbpp7zrscrr8hewc
  text: |-
    ### implement — changed
    - evidence: 15 files — Sources/FoundationModelsRouter/Session/SessionConfiguration.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift, Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift (doc link), Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md, Tests/FoundationModelsRouterTests/SessionUserPresenceTests.swift (new), Tests/FoundationModelsRouterPublicSurfaceTests/UserPresencePublicSurfaceTests.swift (new), Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift, Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift, Tests/FoundationModelsRouterTests/SessionWorkEventTests.swift, Tests/FoundationModelsRouterTests/Helpers/BackgroundingSessionFixture.swift. Full suite: 1735 tests in 210 suites passed (1 existing known issue), 26/14 and 19/3 passed. IntegrationTests build complete.
    - next: /review
  timestamp: 2026-10-15T18:01:36.885990+00:00
position_column: doing
position_ordinal: '80'
title: Set the user presence of a session (interactive or headless) on its run plane
---
Elicitation phase 2, the Router part. Needs Extras task 18 (Extras main dbd91de): `UserPresence { interactive, headless }`, `RunPlane.init(clock:userPresence: = .interactive)`, `RunPlane.userPresence`, `RunPlane.noUserPresentReason`. A headless RunPlane answers each question at once with `.cancel(reason: noUserPresentReason)`, posts no event and stores no question.

- [ ] A public Router value sets the user presence of a session. The session passes it to its `RunPlane(clock:userPresence:)`. The default is `.interactive`, so no current caller changes. Additive API only.
- [ ] A fork and a restored session keep the presence of their source.
- [ ] A headless session sends `workEnded` normally.
- [ ] Fixed-order tests. One full run. Push when the reviewer accepts the design and the run is green.

Send the design to the reviewer before code. #elicitation-phase-2