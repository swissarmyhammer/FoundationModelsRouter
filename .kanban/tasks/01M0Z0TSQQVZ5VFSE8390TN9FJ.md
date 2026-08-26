---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0z6qqjmn62458yd3xc6qg9j
  text: |-
    Baseline recorded: 812 `public` declarations in Sources, 172 public type declarations (`rg -c '^\s*public '`).

    Method in use: strip `public` from a whole folder with `perl -i -pe 's/^(\s*)public /$1/'`, then rebuild and restore only what a compiler error or a real consumer proves. Four consumer builds gate each folder pass, not two:
    1. `swift build --build-tests` in the Router — this also covers the in-package plain-import targets (`FoundationModelsRouterTestSupport`, `...EvalSupport`, `...RealModelSupport`) and the `Tools/` executables (`RecordCompactionFixture`, `MultiModelGeneration`, `CompactionDemo`). These live in the same package, so `package` access is enough for them; `package` does not count against the public metric.
    2. `swift build --build-tests --package-path IntegrationTests` in the Router — a SEPARATE package, so it sees `public` only.
    3. `swift build --build-tests` in FoundationModelsMultitool.
    4. `swift build --build-tests --package-path IntegrationTests` in FoundationModelsMultitool — also a separate package. This one found the most restorations; do not skip it.

    Recording folder done: 203 -> 31 public declarations. Total 812 -> 634.

    What the compiler and the consumers proved must stay public in Recording:
    - `TranscriptRecorder` (protocol) — `Router.init(recorder:)` names it.
    - `TranscriptEvent` + `Kind` + `Partial`, and the members MT's integration tests read: `sessionId`, `parentId`, `slot`, `kind`, `text`, `entry`, `seq`, `tokensIn`, `tokensOut`, `ms`. `routerId`, `model`, `ts`, `grammar` are now internal.
    - `TranscriptEntryPayload` + `segments` + `init(from:)`; `SegmentPayload` + `init(from:)`/`encode(to:)`.
    - `MergedTranscript.merged(under:)` — `LiveRouterFixture.transcriptEvents()` calls it.
    - `PersistableStructuredSegment` + `init?(schemaName:contentJSON:id:)` + the `schemaName` default — MT's `ShellElevationRunner` rebuilds `OperationEventSegment` through it.
    - `SessionSidecar` + `AgentSpawn` (+ its two properties and its init) — `makeSession(agentSpawn:)` names the type; `init(from:)` follows from `Decodable`.

    Moved to `package` (in-package consumers only, so off the public metric): `DurableRecording`, `SessionSidecarWriter`, `SessionSidecar.ResolvedProfile`, `JSONLRecorder` + its `append`, `TranscriptTree` + `SessionNode` + `load(under:)`, `TranscriptReconstructionView`, `effectiveTranscript(...)`, `RoutedModel.init`.

    Dropped to internal outright: `RoutedModel.recorder`, `.durableRecording`, `.recordingsRoot`, `.sessionSidecarWriter`, and both `RoutedLLM.makeLanguageModel` overloads — no consumer in either repository names them.

    Trap worth knowing: an inaccessible member inside a closure does not always report as "inaccessible". MT's `ShellElevationRunner` reported "value of type '[SegmentPayload]??' has no member 'compactMap'" and `SelectionForkPerCallTests` reported "the compiler is unable to type-check this expression in reasonable time". Both were really an internal member the expression named. Read the whole expression, not the diagnostic.

    Gates after this folder: Router `swift build --build-tests` clean; Router IntegrationTests clean; Multitool + its IntegrationTests clean; `swift test` in the Router 1058 tests in 104 suites passed (2 known issues) plus 83 tests in 10 suites passed.
  timestamp: 2026-08-26T14:14:11.796860+00:00
- actor: claude-code
  id: 01m0z8wq7aawtxh6atqqnqek70
  text: |-
    All folders closed. Count 812 -> 390 public declarations (the gate is 406). Public types 172 -> 102.

    Per folder: Recording 203 -> 31, Hosting 189 -> 165, Session 126 -> 54, Compaction 81 -> 34, Resolution 75 -> 29, Sizing 57 -> 11. Core, Guided, Concurrency and the root files (`Router.swift`, `RoutedLLM.swift`, `LanguageModelProfile.swift`, `Tools.swift`, `RoutedEmbedder.swift`) got the same pass.

    Hosting keeps the most, and that is correct: the card's own tool-author list names nearly every type in it (`BackgroundTool`, `ToolMount`, `ToolContext`, `PendingRunEnvelope`, `OperationEvent`/`OperationEventKind`/`OperationOutcome`/`OperationEventSink`, `RunKind`, `BackgroundRun`, `ToolInvocationRecord`, `ForkableTool`, the elicitation types), and the Multitool proves nearly every member of each. `ToolRun`, `ContextBindingTool`, `BackgroundToolRunner`, `RunToCompletionRunner` and most of `SessionMailbox` are now internal; `SessionMailbox` keeps only `init()`, `makeCompletionToken()`, `respond(elicitationId:_:)`, `complete(elicitationId:)` and the two delivery enums, because the Multitool and the public `RoutedSession` requirements name exactly those.

    Two types went internal that no consumer names at all: `SummarizeTool` and `EmbedTool` in `Tools.swift`, plus `GuidedRequestError`. `RoutedLLM.makeLanguageModel()` and `makeLanguageModel(resuming:)` are internal as well.

    The change is access level only, proved mechanically: `git diff` over Sources/Tests/Examples/Tools is 425 insertions and 425 deletions, and every changed line pairs with its partner once the leading access keyword (and one `@testable`) is removed. There is no `public extension` block anywhere in Sources, so no member changed access without its own keyword. A scan for a `public` member left inside a non-public container returns zero.

    Router-side edits outside Sources, both needed and both minimal:
    - `Tests/FoundationModelsRouterTests/RegisteredJournalOpTests.swift`: `import` -> `@testable import`. It was the one test file in a test target that imported the Router plainly.
    - `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`: `public static func makeDurableRecording` -> `package`, because `DurableRecording` is now `package`. Nothing outside the package calls it.

    Nothing was edited in the Multitool checkout.
  timestamp: 2026-08-26T14:51:52.426525+00:00
- actor: claude-code
  id: 01m0zamdgm8kdcp327w63w0hxb
  text: |-
    Final state and the two decisions a reviewer must know about.

    A FOURTH consumer exists that the card does not name: `FoundationModelsRanker`. The Multitool's nested IntegrationTests package links it, and it reads `RoutedEmbedder.dimension`, `RoutedEmbedder.embed(texts:)` and `RoutedSession.respond(to:)` through a plain import. Those three are public because of it. The Router's OWN nested IntegrationTests package, by contrast, uses `@testable import FoundationModelsRouter` in every one of its 20 files, so it proves nothing about the public surface — it is a test consumer, exactly as the card says. `AsyncSemaphore` is the one exception: `FoundationModelsRouterTestSupport` is a plain `.target` that imports the Router plainly and publishes `GatedRealModelSuiteTrait.init(...:holding:...)` to that other package, so the semaphore must be `public`, not `package`.

    DECISION 1 — a public type must stay usable. Making a type internal is an access change; leaving a public type with no public member is an API removal in all but name. So for a type the card's API list NAMES, the members that make it work stay public: `SessionProjection` (a driver creates one and reads it), `SessionConfiguration` (a host builds one for `makeSession(configuration:)`), `DiscoveryPriming`, `ToolInvocationRecord`, and the whole elicitation vocabulary (a tool author builds an `ElicitationRequest` and its schema payloads, and every `init(from:)`/`encode(to:)` is then forced public by `Codable`).

    DECISION 2 — a type public only because a listed signature names it stays NAMEABLE, not usable. `TranscriptEvent.Partial`, `SessionOutbox.QueueDepth`, `DownloadProgress`, `RawRepoMetadata` and `ResponseFragment` are public types with no public member. An outside module can name each one — which is all the compiler needs to keep `Router.init(recorder:)`, `RoutedSession.promptQueueDepth()`, `ModelLoader` and `LanguageModelSessionBackend` spelled as they are — and no consumer in any of the four builds reads or builds one. This is the card's rule applied strictly: restore only what the compiler or a real consumer proves.

    Also demoted, after checking every consumer: `PromptCancellationResult` and `RoutedSession.cancelPrompt(id:)` (nothing outside calls either), `ModelRef.repo`/`.revision` and its two non-literal initializers (`ModelRef` stays constructible from a string literal and readable through `stringValue`), `OperationOutcome.init(rawValue:)`, `ModelLoaderError`, `SummarizeTool`, `EmbedTool`, `GuidedRequestError`.

    DEAD-CODE CHECK, because `code-hygiene/dead-code-swift` says a `public` declaration is exempt through `--retain-public` and an internal one is not — a demotion can therefore create a dead-code finding. Every symbol this change demoted was checked for a caller in the module or in a test target: `SummarizeTool`/`EmbedTool` (ToolSharedProfileTests), `GuidedRequestError` (four source files), both `makeLanguageModel` overloads (RecordingHandleResumeTests and the nested RecordingHandleIntegrationTests), `cancelPrompt`/`PromptCancellationResult` (11 and 4 hits), `OperationOutcome.init(rawValue:)` (OperationOutcomeTests plus its own `init(from:)`), `ToolInvocationRecord.closed(at:)` (ToolRun, ContextBindingTool, three test files), `ModelRef(repo:revision:)` (CoreTypesTests), `ModelLoaderError`, `ResponseFragment` and `RawRepoMetadata` members. Each has at least one caller, and `--build-tests` puts the test targets in the index, so none of them should report. Periphery itself could not be run here: this workspace builds through the new Swift Build layout (`.build/out`), and periphery looks for `.build/debug/index/store`, which does not exist.

    DEFECT I MADE AND REPAIRED, worth recording so the next agent does not repeat it: a helper script that raised access levels from build diagnostics rebuilt each line with `f"{indent}{level} {rest}"` after a `.*$` match, which drops the trailing newline and JOINS the line with the next one. It damaged 15 lines across 5 files (`Core/JSONValue.swift`, `Core/ModelRef.swift`, `Hosting/OperationOutcome.swift`, `Hosting/ToolMount.swift`, `Resolution/LiveModelLoader.swift`). Swift still compiled, so no build caught it. It was found by comparing each changed file's line count against `HEAD` and repaired by restoring those five files and re-applying the access levels by hand. Two checks now guard the whole change and both pass: every changed file has the same line count as `HEAD`, and every added line pairs with a removed line once the leading access keyword is stripped.
  timestamp: 2026-08-26T15:22:17.492265+00:00
- actor: claude-code
  id: 01m0zamn5pegwsmghhk5hmgbgs
  text: |-
    ### implement — changed
    - evidence: 59 files, 413 insertions / 413 deletions, all in FoundationModelsRouter. `public` declarations 812 -> 402 (gate 406); public types 172 -> 104. Access level only: every changed file has the same line count as HEAD, and every added line pairs with a removed line once the leading access keyword (or one `@testable`) is stripped; a scan for a `public` member inside a non-public container returns 0. Router `swift build --build-tests` after touching every changed file: 0 errors, 0 warnings from our code. Router `swift test`: "Test run with 1058 tests in 104 suites passed ... with 2 known issues" plus "Test run with 83 tests in 10 suites passed" — the same counts and the same 2 known issues as before the change. Router `swift build --build-tests --package-path IntegrationTests`: clean. Multitool `swift build --build-tests`: clean; `swift test`: "Test run with 1023 tests in 73 suites passed"; `swift build --build-tests --package-path IntegrationTests`: clean. No commit in either repository, and no file in the Multitool checkout was edited.
    - next: /review
  timestamp: 2026-08-26T15:22:25.334730+00:00
- actor: claude-code
  id: 01m0zbn724kmmppky0vhtf056j
  text: |-
    ### review — findings
    - evidence: 14 findings (14 confirmed, 17 refuted) over `review sha HEAD~1..HEAD` — Core/ProfileDefinition.swift:27, Recording/RecordingSchemaVersion.swift:12, Recording/SessionTreeRestoration.swift:57,60,80,83,86, Session/GenerationStall.swift:24,27, Session/RoutedSession.swift:384, Session/SessionEvent.swift:100, Session/SessionOutbox.swift:310,317, Tools.swift:55
    - next: correct every item in the `## Review Findings (2026-08-26 10:24)` section. The task stays in `review`.
  timestamp: 2026-08-26T15:40:12.228418+00:00
- actor: claude-code
  id: 01m0zbp7mbapw8sw4m8k7beqkv
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 59 files, 413 insertions / 413 deletions; public declarations 812 -> 402, public types 172 -> 104
    - test: green — Router `swift test` 1058 tests in 104 suites + 83 tests in 10 suites (2 known issues, unchanged); Multitool `swift test` 1023 tests in 73 suites; all four consumer packages build clean
    - commit: fe5ce0e refactor(api): close the public surface to what a host actually calls
    - review: findings — Core/ProfileDefinition.swift:27, Recording/RecordingSchemaVersion.swift:12, Recording/SessionTreeRestoration.swift:57, :60, :80, :83, :86, Session/GenerationStall.swift:24, :27, Session/RoutedSession.swift:384, Session/SessionEvent.swift:100, Session/SessionOutbox.swift:310, :317, Tools.swift:55
  timestamp: 2026-08-26T15:40:45.579648+00:00
- actor: claude-code
  id: 01m0zchp1x94wxnss67cdjmjv5
  text: |-
    All 14 review findings are corrected. This is how each group was decided.

    GROUP 2 — `code-hygiene/dead-code-swift`. The rule has two different remedies, and the finding text says which one applies.

    Three findings say "is unused". The rule deletes those. Deleted:
    - `RecordingSchemaVersion.v1` and its doc comment. No file in the four packages reads it.
    - `RoutedSession.compact(prompt:)`, the one-argument convenience. The sibling overloads `compact()` and `compact(budget:)` both have callers; this one has none.
    - `EmbedTool.dimension` and its doc comment. `RoutedEmbedder.dimension` has callers; the `EmbedTool` wrapper over it has none. The `- Returns:` line of `embed(texts:)` linked to the deleted symbol, so it now links to ``RoutedEmbedder/dimension``.

    Five findings say "is assignOnlyProperty", and the rule forbids deleting those. Its own section, "`assignOnlyProperty` and the reads periphery cannot see", was measured on THIS repository: "the index ... cannot see the `==` and `hash(into:)` the compiler *synthesizes* for an `Equatable` or `Hashable` type". It states "**Do not delete such a property.**" and prescribes `// periphery:ignore` with the reason on its own line above the marker.

    Both structs are exactly that case, and the reader is proved by file and line:
    - `SessionConfigurationRestorationReport.MissingTool` is `Equatable`. `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:879-882` compares whole values: `restored.configurationReport.missingTools == [SessionConfigurationRestorationReport.MissingTool(session: root.id, toolName: "ambient-emitter")]`. The synthesized `==` reads `session` and `toolName`.
    - `RestoredSessionTree.ContextMismatch` is `Equatable`. `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:1008-1011` compares whole values: `restored.contextMismatches == [RestoredSessionTree.ContextMismatch(session: root.id, recorded: recordedContext, resolved: resolvedContext)]`. The synthesized `==` reads `session`, `recorded` and `resolved`.

    Each of the five properties now carries the marker with the reason the rule's own example uses. This adds 15 lines to `SessionTreeRestoration.swift` deliberately.

    GROUP 1 — `swift/access-control` and `completeness/public-output-contract`. The rule is that a public type must be usable, not only nameable. Each type was decided on the role an outside module can play.

    `ProfileDefinition` — a host authors one and gives it to `Router.resolve(profile:)`. `description`, `standard`, `flash`, `embedding` and `context` are public again. `candidatesBySlot` stays internal: it is a lookup view over three properties that are now public, so an outside caller can build it.

    `GenerationStall` — a host receives one in `SessionEvent.generationStalled(_:)`. The finding named two properties; `visibility` had the same defect on the same type, so all three are public again.

    `TokenUsage` — carried by `SessionEvent.turnEnded(_:)`. The `init` is public again.

    `SessionOutbox.QueueDepth` — `promptQueueDepth()` is a requirement of the public `RoutedSession` protocol, so a protocol requirement makes it public and no access keyword can undo that. The finding named `total` and `init`; `queued` and `dispatched` had the same defect, so all four are public again.

    FOUR MORE TYPES had the same defect and no finding of their own. The earlier comment on this card recorded them as a deliberate decision ("DECISION 2 — a type public only because a listed signature names it stays NAMEABLE, not usable"). That decision is wrong: a public protocol an outside module cannot implement is a broken contract. All four are corrected, and a scan for a public type with no publicly usable member now returns 0:
    - `TranscriptEvent.Partial` — `TranscriptRecorder.append(_:to:)` hands one to a recorder. An outside recorder must read every field to persist the event, so all 12 properties are public. The `init` stays internal, because only the Router builds one.
    - `DownloadProgress` — `ModelLoader.loadLLM(...reporting:)` and `loadEmbedder(...reporting:)` name it, and `Router.init(loader:)` is public, so an outside loader must build one. `init`, both properties and `fraction` are public.
    - `ResponseFragment` — `LanguageModelSessionBackend.streamResponseFragments(to:maxTokens:)` returns a stream of them, so an outside backend must build one. Its own doc says an accumulator reads `restartsResponse`. `init`, `text` and `restartsResponse` are public.
    - `RawRepoMetadata` — `MetadataSource.fetchRawMetadata(repo:revision:)` returns one, and `Router.init(metadataSource:)` is public, so an outside source must build one. `init` and both properties are public.

    COUNTS. Public declarations moved from 402 to 437 of the 812 baseline. Public types stay at 107. The 35 restored members are 13 the findings demanded and 22 from the four types above. 437 is 54% of the baseline, so the "at most half" acceptance criterion no longer holds; that criterion is now unchecked with the figure recorded on it. Nothing was demoted to compensate, because the earlier pass already proved each remaining public symbol against the four consumer packages.

    MECHANICAL GUARDS, both re-run. Every changed file has the same line count as HEAD, except four files whose line count changed on purpose: `RecordingSchemaVersion.swift` -4, `RoutedSession.swift` -10, `Tools.swift` -3 (the three deletions) and `SessionTreeRestoration.swift` +15 (the periphery markers). A scan for a public member inside a non-public container reports one row, `Core/ULID.swift:25` `public static func generate()`; that row is a false positive of the scan, because `ULID` comes from `@_exported import ULID` and is public in that package, so the real count is 0.

    Nothing in `../FoundationModelsMultitool` was edited, and nothing was committed in either repository.
  timestamp: 2026-08-26T15:55:45.085167+00:00
- actor: claude-code
  id: 01m0zchzcxeaa6xphgbrv8q487
  text: |-
    ### implement — changed
    - evidence: 10 files in FoundationModelsRouter — Core/ProfileDefinition.swift, Recording/RecordingSchemaVersion.swift, Recording/SessionTreeRestoration.swift, Recording/TranscriptEvent.swift, Resolution/ModelLoader.swift, Session/GenerationStall.swift, Session/LanguageModelSessionBackend.swift, Session/RoutedSession.swift, Session/SessionEvent.swift, Session/SessionOutbox.swift, Sizing/RepoMetadata.swift, Tools.swift. All 14 findings of `## Review Findings (2026-08-26 10:24)` are checked. Public declarations 402 -> 437; public types 107, unchanged. Gates: Router `swift build --build-tests` clean; Router `swift test` "1058 tests in 104 suites passed ... with 2 known issues" plus "83 tests in 10 suites passed", the same counts and the same 2 known issues as before; Router `swift build --build-tests --package-path IntegrationTests` clean; Multitool `swift build --build-tests` clean and `swift test` "1023 tests in 73 suites passed"; Multitool `swift build --build-tests --package-path IntegrationTests` clean. Line counts match HEAD except four deliberate files (-4, -10, -3 deletions, +15 periphery markers). Public types with no publicly usable member: 0. Public members stranded in a non-public container: 0.
    - next: /review. The first acceptance criterion is now unchecked, because the count 437 is above the 406 that criterion asks for.
  timestamp: 2026-08-26T15:55:54.653927+00:00
- actor: claude-code
  id: 01m0zcj8kk0h1ycqsddhmzkkgn
  text: 'Correction to the step record above: the file count is 12, not 10. `git diff --stat -- Sources` reports 12 files changed, 51 insertions and 53 deletions. The 12 names in that record are correct; only the number was wrong.'
  timestamp: 2026-08-26T15:56:04.083093+00:00
depends_on:
- 01M0YZ7Y58NKMZFVT7TD1C69AB
position_column: doing
position_ordinal: '80'
title: Close the public surface to what a host actually calls
---
## What
Sources carries 812 `public` declarations across 168 public types. Most are Router implementation details, not the API a host uses. Reduce the public surface to what an outside caller genuinely needs, and make everything else `internal` (or `package`/`fileprivate` where that reads better).

The public API a host and a tool author actually need:
- Vend and drive a session: `Router`, `LanguageModelProfile`, `RoutedLLM`, `RoutedModel.makeSession(...)`, `RoutedSession` and its surfaces (`respond`, `streamResponse`, `streamEvents`, `fork`, `close`, `cancelCurrentTurn`, `respond(elicitationId:...)`, `complete(elicitationId:)`), `SessionEvent`, `TurnOutcome`, `SessionProjection`.
- Write a tool: `BackgroundTool` and `ToolMount`, `ToolContext` (post/progress/elicit/backgroundRuns/wait/cancel), `PendingRunEnvelope`, `OperationEvent`/`OperationEventKind`/`OperationOutcome`/`OperationEventSink`, `RunKind`, `BackgroundRun`, `ToolInvocationRecord`, `ForkableTool`, the elicitation types.
- Configure: `TokenBudget`, `Summarization`, `CompactionResult`, `DiscoveryPriming`, recording/restoration entry points a host calls by name.

Work folder by folder, largest first — `Recording/` (42 public types), `Hosting/` (37), `Session/` (31), `Resolution/` (19), `Compaction/` (15), `Sizing/` (11). For each type ask: does an outside module name it? The compiler answers — drop `public`, build the package, and restore only what breaks. `@testable import` keeps the test target working against `internal`, so tests are not a reason to keep a symbol public. The sibling `../FoundationModelsMultitool` is a real consumer: build it against the local Router after each folder and restore anything it legitimately needs.

- [x] Record the baseline: `rg -c '^\s*public ' Sources | awk -F: '{s+=$2} END {print s}'` (812 today) and the public-type count.
- [x] Close each folder, largest first; keep the doc comment on anything that stays public.
- [x] `RoutedSessionActor` and its extensions, `ToolRun`, `RunEventFunnel`, `SessionOutbox`, `SessionMailbox`'s run-plane members, `BackgroundToolRunner`, `RunToCompletionRunner`, and the Recording sidecar/restoration internals are prime candidates — verify each against the two consumers before deciding.

## Acceptance Criteria
- [ ] The `public` declaration count in Sources is at most half the recorded baseline.
  - Measured after the review findings were corrected: 437 declarations of the 812 baseline. That is 54%, above the 406 the criterion asks for. The findings made 13 members public again. The same defect in four more types made 22 more members public. A person must decide if 437 is acceptable, or if a type must leave the public surface completely. See the comment of 2026-08-26.
- [x] Every remaining public type is named by an outside module (Router's own tests do not count) or is on the host/tool-author API list above.
- [x] `swift build --build-tests` and the full suite are green in FoundationModelsRouter.
- [x] `../FoundationModelsMultitool` builds and its suite is green against the changed Router.

## Tests
- [x] Access-level change only; the two suites are the regression guard. Run `swift test` in both repositories — green.

## Workflow
- [x] Use `/tdd` — run both suites before and after each folder pass. #api #cleanup

## Review Findings (2026-08-26 10:24)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 59 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Sources/FoundationModelsRouter/Core/ProfileDefinition.swift:27` `completeness/public-output-contract` — Public struct ProfileDefinition has multiple properties (lines 27, 30, 33, 36, 44) changed from public to package-level, making these essential configuration properties inaccessible to external code. External consumers of this public type cannot read its profile configuration. Either (1) restore `public` to the properties on lines 27, 30, 33, 36, and 44 to maintain API access, or (2) make ProfileDefinition package-level to match the visibility of its members.
- [x] `Sources/FoundationModelsRouter/Recording/RecordingSchemaVersion.swift:12` `code-hygiene/dead-code-swift` — var.static `v1` is unused.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:57` `code-hygiene/dead-code-swift` — var.instance `session` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:60` `code-hygiene/dead-code-swift` — var.instance `toolName` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:80` `code-hygiene/dead-code-swift` — var.instance `session` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:83` `code-hygiene/dead-code-swift` — var.instance `recorded` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:86` `code-hygiene/dead-code-swift` — var.instance `resolved` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Session/GenerationStall.swift:24` `swift/access-control` — Public struct `GenerationStall` has a property that lost the `public` keyword, making it internal. Clients cannot access properties of a public struct with internal visibility, breaking the public API. Restore `public` to the property: `public let timeWithoutProgress: Duration`.
- [x] `Sources/FoundationModelsRouter/Session/GenerationStall.swift:27` `swift/access-control` — Public struct `GenerationStall` has a property that lost the `public` keyword, making it internal. Clients cannot access properties of a public struct with internal visibility, breaking the public API. Restore `public` to the property: `public let timeInFlight: Duration`.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:384` `code-hygiene/dead-code-swift` — function.method.instance `compact(prompt:)` is unused.
- [x] `Sources/FoundationModelsRouter/Session/SessionEvent.swift:100` `swift/access-control` — Public struct `TokenUsage` has an initializer that lost the `public` keyword, making it internal. Clients cannot construct instances of a public struct with an internal initializer, breaking the public API. Restore `public` to the `init` at line 100: `public init(tokensIn: Int, tokensOut: Int, contextFill: Double) {`.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:310` `swift/access-control` — Public struct `QueueDepth` has a computed property that lost the `public` keyword, making it internal. Clients cannot access properties of a public struct with internal visibility, breaking the public API. Restore `public` to the property: `public var total: Int { queued + (dispatched == nil ? 0 : 1) }`.
- [x] `Sources/FoundationModelsRouter/Session/SessionOutbox.swift:317` `swift/access-control` — Public struct `QueueDepth` has an initializer that lost the `public` keyword, making it internal. Clients cannot construct instances of a public struct with an internal initializer, breaking the public API. Restore `public` to the initializer: `public init(queued: Int, dispatched: ItemID?) {`.
- [x] `Sources/FoundationModelsRouter/Tools.swift:55` `code-hygiene/dead-code-swift` — var.instance `dimension` is unused.