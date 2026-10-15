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
- actor: claude-code
  id: 01m50c3v7ettm7x4b4feeqnm0c
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (5409c852); 1 finding confirmed, 2 refuted. Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:1073 (reuse/reuse).
    - hand checks: each path that makes a RunPlane gives the presence. These are the root (RoutedLLM makeSessionToolWiring), the fork (RoutedSessionActorForking reads runPlane.userPresence), and the restore and restored fork (SessionTreeRestoration, restoredUserPresence per node). The sidecar records runPlane.userPresence. The API changes are additive only (defaulted parameters). The new tests use no sleep, time limit or clock deadline. The red-first order cannot be seen in one commit.
    - next: implement the finding (one RouterTestFixtures helper for the sidecar path), then review again.
  timestamp: 2026-10-15T18:10:13.358017+00:00
- actor: claude-code
  id: 01m50cj6pqvc31rma6q1qeks47
  text: |-
    Finding reuse/reuse (SessionTreeRestorationTests rewriteRecordedSidecar) is done. RouterTestFixtures has three new helpers: `sessionDirectory(of: ULID..., routerId:recordingsDir:)`, `sidecarURL(of: ULID..., routerId:recordingsDir:)` and `sidecarURL(inSessionDirectory:)`. The ids are a session path from the root to the session, so a fork is `of: root.id, fork.id`. The file name comes from the production constant `sessionSidecarFileName`. All sites in Tests/ that built a sidecar path by hand now call the helpers: SessionTreeRestorationTests (4 sites), ForkAfterCompactionRestorationTests (private forkSidecarURL removed), TranscriptTreeTests (3), StoredRecoveriesKeyTests (2), SessionSidecarTests (8), MergedAndRedactionTests, RealModelHarnessTests, PerSessionRecordingRootTests (2). Not changed: the "session.json" literals in file-name list assertions (SessionSidecarTests) and RecordingRedactionScanTests data, because they are not path construction. Discovery: many tests also build a session directory by hand to reach transcript.jsonl (SessionSidecarTests, TranscriptNestingTests, SessionTreeRestorationTests, RepetitionStopRestoreTests, MergedTranscriptPublicSurfaceTests). That is outside this finding; `sessionDirectory(of:...)` can serve them later. Note: the files tool `replace_all` made only one replacement each time, so each site was edited one by one.

    ### implement — changed
    - evidence: 9 files under Tests/FoundationModelsRouterTests. `swift build --build-tests`: Build complete, zero Router warnings. Touched suites: "Test run with 101 tests in 8 suites passed after 0.566 seconds with 1 known issue." Full suite `swift test --skip-build`: "Test run with 1735 tests in 210 suites passed after 7.378 seconds with 1 known issue." plus 26 tests in 14 suites and 19 tests in 3 suites passed. `cd IntegrationTests && swift build --build-tests`: Build complete.
    - next: review
  timestamp: 2026-10-15T18:18:03.863583+00:00
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

## Review Findings (2026-10-15 13:02)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:1073` `reuse/reuse` — rewriteRecordedSidecar rebuilds the sidecar path from the router directory and the session id by hand. Other tests already build this same path for recorded sessions, so the path logic is repeated. Move the sidecar path construction (routerDirectory plus session directory plus session.json) into one RouterTestFixtures helper, and call it from rewriteRecordedSidecar and from the sibling tests that already build this path.