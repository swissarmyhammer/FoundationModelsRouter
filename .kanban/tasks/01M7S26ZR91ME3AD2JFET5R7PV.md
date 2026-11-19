---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s32z60hp2k08w5km6g610a
  text: 'Research. (1) A new session holds its added folders in `SessionRecord.additionalDirectories` (index.md); `SessionStartRequest` has no such field, and a host sets them with `setAdditionalDirectories(to:for:)`. The fork record comes from `SessionRecordSource.new(facts)` in `RoutedLLM.makeFork(of:id:seed:tools:)` (RoutedLLMForking.swift), so the plan is: give `.new` an `additionalDirectories` value (default none), and the first index.md of the fork holds the folders. The default `makeFork()` takes `source.record.additionalDirectories`. The builder of `ForkBuild` gets a surface value (tools and folders), `nil` for the surface of the source; the closed-state rules of `ForkBuild` do not change. (2) The path `RouterSessionDirectory.fork(_:)` -> `forkSource` -> `prepareFork` -> `launchFork(_:)` -> `launcher.forkSession(_:)` has no `Task {}` and no `Task.detached`: each step is an `await` in the task of the caller (actor hops keep the task and its task-locals). So part 2 is the docs and a test; the RED of the test is shown with a temporary `Task.detached` in `launchFork(_:)`.'
  timestamp: 2026-11-19T05:04:51.904138+00:00
- actor: claude-code
  id: 01m7s3f8g7tb0kcyfj92qa99z0
  text: 'Implementation landed. New public API: `SessionLaunchForkRequest.makeFork(tools: [any Tool], additionalDirectories: [URL]) async throws -> any RoutedSession`; `makeFork(tools:)` calls it with no folders; `makeFork()` takes the folders of the source record. Internal: `ForkSurface` (tools + folders) replaces the `[any Tool]?` of the `ForkBuild` builder, `RoutedSessionActor.makeFork(id:seed:surface:)`, `RoutedLLM.makeFork(of:id:seed:surface:)`, and `SessionRecordSource.new(_:additionalDirectories:)` (default none), so the FIRST index.md of the fork holds the folders (same field as a new session). `ForkBuild` close rules did not change. The fork path has no `Task {}` / `Task.detached`; the guarantee is now in the docs of `SessionLauncher.forkSession(_:)`, `RouterSessionDirectory.fork(_:)` and `launchFork(_:)`. RED evidence: (a) the build failed with "extra argument ''additionalDirectories'' in call" before the API; (b) with the API but folders `?? []`, `aForkWithTheSurfaceOfTheSourceHasTheFoldersOfTheSource` failed (`[]` != folders); (c) with a temporary `Task.detached` around `launcher.forkSession(request)` in `launchFork(_:)`, `theLauncherCallSeesTheTaskLocalsOfTheForkCallerOnly` failed (the first call saw `nil`); the temporary change was removed. `aForkWithOnlyToolsHasNoFoldersOfTheSource` guards the old behavior of `makeFork(tools:)` and passed from the start.'
  timestamp: 2026-11-19T05:11:34.663132+00:00
- actor: claude-code
  id: 01m7s3g7c1pg6k7d3nprkg5k7a
  text: |-
    ### implement — changed
    - evidence: new `public func makeFork(tools: [any Tool], additionalDirectories: [URL]) async throws -> any RoutedSession` on `SessionLaunchForkRequest`. Files: Sources/FoundationModelsRouter/Directory/SessionLaunchForkRequest.swift, Directory/SessionLauncher.swift (docs), Directory/RouterSessionDirectory.swift (docs), Recording/SessionIndexWriter.swift, RoutedLLMForking.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorForking.swift, Session/RoutedSessionActorPromptCache.swift (doc link); Tests ForkBuildTests.swift, ForkPromptCacheCopyTests.swift, Helpers/ForkLauncherFixtures.swift (ForkLaunchingLauncher additionalDirectories, CallerMarkLauncher, ForkCallerMark), RouterSessionDirectoryForkLauncherTests.swift (5 new tests). Suites: 38 tests in 3 suites passed. Full `swift test` once: 3099 tests in 352 suites passed; 50 in 26 and 19 in 3 passed; no compiler warnings. Output: scratchpad/full.txt.
    - next: /review. Push and the message to foundationmodelsacpagent-9e come after commit.
  timestamp: 2026-11-19T05:12:06.273286+00:00
- actor: claude-code
  id: 01m7s3pw1f1g9fk5rmzx8ksawp
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (f446bafe): 0 findings, 0 confirmed, 0 refuted, 12 files reviewed (2 .kanban files ignored). swift test --filter 'RouterSessionDirectoryForkLauncherTests|ForkBuildTests|ForkPromptCacheCopyTests': 38 tests in 3 suites passed.
    - added checks: fork(_:) -> launchFork(_:) -> forkSession(_:) has only awaits and no new task. The same-task test fails if the launcher call goes into Task.detached. The two forks are held in a fixed order by firstCallEntered and releaseFirstCall, with no sleep, and a defer releases the gate if the second fork throws. The restart test reads the directories from the restored record. makeFork(tools:additionalDirectories:) goes through ForkBuild.make(surface:), so forkAlreadyMade and requestClosed still apply. The docs of forkSession(_:), fork(_:) and launchFork(_:) agree with the code. SessionForkRequest in Extras has no change.
    - next: push, and send the API names and the sha to foundationmodelsacpagent-9e.
  timestamp: 2026-11-19T05:15:44.047092+00:00
- actor: claude-code
  id: 01m7s3qjnw8knxkj1zam87tee1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — SessionLaunchForkRequest.swift, SessionLauncher.swift, RouterSessionDirectory.swift, SessionIndexWriter.swift, RoutedLLMForking.swift, 3 session actor files; RouterSessionDirectoryForkLauncherTests (+5), ForkLauncherFixtures, ForkBuildTests, ForkPromptCacheCopyTests
    - test: green — one full swift test run, 3099 tests in 352 suites (+50, +19), 0 failures
    - commit: f446bafe
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-19T05:16:07.228429+00:00
depends_on:
- 01M7S15T37N1RG9ECXB2QM6EAS
position_column: done
position_ordinal: ffffffffffbb80
title: A host fork can give additional directories to the fork record, and the launcher call runs in the task of the fork caller (D205)
---
## Goal

Two API asks from foundationmodelsacpagent-9e, for the fork launcher of ^vhy7017.

1. **Additional directories.** The agent gives the tool fork the additional directories of its source in the tools, but it cannot put them in the fork's `index.md` record. A new session has them in its record.
2. **Correlation.** The agent must find its own waiting `session/fork` request (the tools and the copied history) when the launcher call comes. Today it keys it by (source id, requestedByClient). A fork from the `sessions` endpoint with the same client and source at the same time can take the wrong one.

## Decision (orchestrator)

1. Add `SessionLaunchForkRequest.makeFork(tools:additionalDirectories:)` (keep `makeFork(tools:)` as a call with no directories). The Router writes the directories to the fork record in the same way as for a new session (find how `SessionStartRequest` and the facts of a new session hold them). The default `makeFork()` gives the source's own additional directories, if the source record has them.
2. No new field in the Extras `SessionForkRequest`. The Router GUARANTEES that `SessionLauncher.forkSession(_:)` runs in the task of the caller of `RouterSessionDirectory.fork(_:)`: no `Task {}`, no `Task.detached` and no other task between them. Thus a `@TaskLocal` value that the host sets around its own `fork(_:)` call is visible in its launcher, and a fork from another caller does not have it. Write this guarantee in the doc of `forkSession(_:)` and of `fork(_:)`.

## Tests

- [x] `makeFork(tools:additionalDirectories:)`: the fork record has the directories after the fork and after a restart.
- [x] `makeFork()`: the fork record has the additional directories of the source.
- [x] A `@TaskLocal` set by the test around `fork(_:)` is visible in `forkSession(_:)` of a test launcher; a second `fork(_:)` with no such value does not see it. Run the two forks at the same time on the same source and client, in a fixed order with gates.

## After

Push when green. Send the names and the sha to foundationmodelsacpagent-9e. #d205