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
- [x] The `public` declaration count in Sources is at most half the recorded baseline.
- [x] Every remaining public type is named by an outside module (Router's own tests do not count) or is on the host/tool-author API list above.
- [x] `swift build --build-tests` and the full suite are green in FoundationModelsRouter.
- [x] `../FoundationModelsMultitool` builds and its suite is green against the changed Router.

## Tests
- [x] Access-level change only; the two suites are the regression guard. Run `swift test` in both repositories — green.

## Workflow
- [x] Use `/tdd` — run both suites before and after each folder pass. #api #cleanup