---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m11xsp2gnd4kwejdatgd7d69
  text: |-
    Research, before the code.

    Line numbers on the card are stale (four commits landed after it was written). Every site was found by symbol name and read again:

    - `RoutedEmbedder.swift` was already down to the one line `try await container.embed(texts: texts)`, with no `import Foundation` and no recorder or timing code. The wrap keeps that shape: no recorder came back, and no `started`/`ms` timing.
    - `RoutedModel` is in `LanguageModelProfile.swift`; its `package init` ends with `gates:`, so `tracer:` was added after it.
    - `Router.init` carries `recorder:`, `recordingLevel:` and `redact:` together; `tracer:` was put beside them, after `redact:`.
    - `makeRoutedModel` is the one place a `RoutedModel` is built from the pool, so one pass-through covers all three slots.

    Facts read from the checked-out package, not assumed:

    - `InstrumentationSystem.tracer` is `any Tracer`, and `Instrument: Sendable`, so `let tracer: (any Tracer)?` is legal in the `Sendable` `RoutedModel`.
    - `Tracer.withSpan` is callable on the `any Tracer` existential.
    - `SpanAttributes.get(_:)` reads an attribute back, and `Int.toSpanAttribute()` answers `.int64` on this machine, so the tests compare against `.int64`.
    - `InMemoryTracer` is a struct over a locked box, so a copy shares the finished-span list.

    Test scaffolding: the suite drives `UndrivenLanguageModelContainer` from `Helpers/UndrivenLanguageModel.swift` rather than a new stub LLM container, because the suite never generates and that helper already exists.
  timestamp: 2026-08-27T15:35:41.904144+00:00
- actor: claude-code
  id: 01m11xv0z5grd792t6rjmcbsd2
  text: |-
    TDD record, and two facts the next agent will want.

    RED: `EmbedTracingTests.swift` was written first and `swift build --build-tests` refused it three times over — `extra argument 'tracer' in call` at the `RouterTestFixtures.makeRouter` call in the shared helper, at the second `makeRouter` call, and at the `RoutedEmbedder(...)` construction. That is the failure the card predicted, and no other error stood beside it.

    GREEN: after the thread-through and the `withSpan` wrap, the three tests pass.

    Two facts:

    - `swift package resolve` DROPPED a stale `FoundationModelsOperationTool` entry from `Package.resolved` on the way in. `Package.resolved` is untracked in this repository, so nothing of that reaches the diff; the entry belonged to no dependency of `Package.swift`.
    - The build writes one warning on every run: `missing creator for mutated node: (.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS)`. It names an mlx-swift product bundle, and this card adds no target and no resource, so it is not ours.

    The first full `swift test` reported 2 issues in `Generation stall diagnostic` beside the 2 known issues. That suite is the timing-sensitive one the card warns about; the re-run answered 1061 tests in 107 suites passed with the 2 known issues alone, and 83 tests in 10 suites passed.
  timestamp: 2026-08-27T15:36:25.829620+00:00
- actor: claude-code
  id: 01m11xv6pmqtaamd8cqt6sd7tb
  text: |-
    ### implement — changed
    - evidence: 6 files — Package.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Sources/FoundationModelsRouter/RoutedEmbedder.swift, Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift, Tests/FoundationModelsRouterTests/EmbedTracingTests.swift (new). `swift build --build-tests` after touching every Swift source of the package: exit 0, zero warnings of ours. `swift test`: 1061 tests in 107 suites passed with the 2 known issues, and 83 tests in 10 suites passed.
    - next: /review
  timestamp: 2026-08-27T15:36:31.700387+00:00
- actor: claude-code
  id: 01m11xyx7cy8kcpcha0s3dtc9e
  text: |-
    ### test — green
    - evidence: `swift build --build-tests 2>&1` clean, no warnings from this package (only the pre-existing mlx-swift `missing creator for mutated node` warning).
    - evidence: `swift test` run 1 showed a false red: "Test run with 1061 tests in 107 suites failed after 5.851 seconds with 4 issues (including 2 known issues)" — the 2 extra issues were both in `GenerationStallDiagnosticTests.swift:292` / `BoundedWait.swift:114`, the documented timing-sensitive flake.
    - evidence: re-run 2 was clean — `Test run with 1061 tests in 107 suites passed after 5.019 seconds with 2 known issues` (the expected pre-existing known issues at `RealModelHarness.swift:72` and `BoundedWait.swift:114`) and `Test run with 83 tests in 10 suites passed after 0.176 seconds`. Counts match the expected 1061/107 plus 83/10.
    - evidence: new suite "Embed tracing" (`Tests/FoundationModelsRouterTests/EmbedTracingTests.swift`, 3 `@Test` cases) passed — accounts for the 3-test increase from 1058/106.
    - No skipped tests found (word "skipped" only appears inside two unrelated test names, both passing).
    - No new warnings from this package.
  timestamp: 2026-08-27T15:38:33.068950+00:00
- actor: claude-code
  id: 01m11y7207qmnsr4a9zkwh3tqt
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit dc902e6) — 0 findings, 0 confirmed, 0 refuted, 7 validator runs attempted, 0 failed. 6 files reviewed; 4 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to done. No open findings.
  timestamp: 2026-08-27T15:43:00.103055+00:00
- actor: claude-code
  id: 01m11y7ngmtrr57p342xycy2hg
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files (Package.swift, Router.swift, LanguageModelProfile.swift, RoutedEmbedder.swift, RouterTestFixtures.swift, EmbedTracingTests.swift new). The new suite was written first and failed to compile with "extra argument 'tracer' in call" at three sites — the red state the card predicted.
    - test: green — swift build --build-tests clean, zero warnings from this package; swift test 1061 tests/107 suites + 83 tests/10 suites pass, 0 failures, 0 skipped, 2 pre-existing known issues (RealModelHarness.swift:72, BoundedWait.swift:114). Count rose from 1058 because the Embed tracing suite adds 3 tests. Run 1 flaked in GenerationStallDiagnosticTests and BoundedWait under contention; the re-run was clean.
    - commit: dc902e6 — 10 files changed, 341 insertions, 23 deletions (local only, no push). Package.resolved is untracked and gitignored in this repo, so the new dependency pins do not reach the diff.
    - review: clean — zero new findings, scope HEAD~1..HEAD, 6 files reviewed, 7 validators, 0 failed
    - next: task is in done. The embed telemetry thread (^p3x0bbb then this card) is complete.
  timestamp: 2026-08-27T15:43:20.084768+00:00
depends_on:
- 01M11KJF2HPVBQYG883P3X0BBB
position_column: done
position_ordinal: ffff8d80
title: Emit an OpenTelemetry span for every embed(texts:) call via swift-distributed-tracing
---
## What

Card ^p3x0bbb removes the `.embedding` transcript event, so `RoutedModel.embed(texts:)` (`Sources/FoundationModelsRouter/RoutedEmbedder.swift`) loses its only timing/provenance signal. Replace it with an OpenTelemetry span.

Owner decision (2026-08-27): embed telemetry is OpenTelemetry, not the transcript.

Library-level design: depend on Apple's `swift-distributed-tracing` (`Tracing` product), NOT on an OTel SDK. `Tracing` is the Swift community tracing abstraction; the host app bootstraps a backend once (`InstrumentationSystem.bootstrap(...)` with `swift-otel`, https://github.com/swift-otel/swift-otel, currently 1.5.0) and every `withSpan` in this library exports through it. Unbootstrapped, the default tracer is a no-op, so the library adds no requirement on apps that do not trace. The repo has no tracing today (`grep -rn "Tracing\|OpenTelemetry\|OSSignposter" Sources Package.swift` is empty).

Verified API (`apple/swift-distributed-tracing` 1.4.1, swift-tools 6.1, products `Instrumentation`, `Tracing`, `InMemoryTracing`; one transitive dependency, `swift-service-context`):

```swift
// Tracer method used by the library
func withSpan<T>(_ operationName: String, context: ..., ofKind kind: SpanKind = .internal, ..., _ operation: (Span) async throws -> T) async rethrows -> T
// Span
var attributes: SpanAttributes { get nonmutating set }   // span.attributes["k"] = 5 / "s" / true
func setStatus(_ status: SpanStatus)
func recordError(_ error: Error, attributes: SpanAttributes, at:)
// Process-wide tracer an app bootstraps; no-op until then
InstrumentationSystem.tracer: any Tracer
// Test tracer (InMemoryTracing product)
InMemoryTracer(idGenerator:recordInjections:recordExtractions:)
InMemoryTracer.finishedSpans: [FinishedInMemorySpan]   // operationName, kind, attributes, status, errors, events, startInstant, endInstant
```

`withSpan` records a thrown error on the span and rethrows; the library does not need its own catch.

Changes:

1. `Package.swift`: add `let tracingPackage = "swift-distributed-tracing"`, `.package(url: "https://github.com/apple/\(tracingPackage).git", from: "1.4.1")`, `.product(name: "Tracing", package: tracingPackage)` on the `packageName` target, and `.product(name: "InMemoryTracing", package: tracingPackage)` on the `"\(packageName)Tests"` target.
2. `Sources/FoundationModelsRouter/Router.swift`: add `tracer: (any Tracer)? = nil` to `public init` (line 171, beside `recorder:` at line 177) and a stored `let tracer: (any Tracer)?` beside `recorder` (line 125). `nil` means "use `InstrumentationSystem.tracer` at call time" — resolved lazily so an app that bootstraps after constructing a `Router` still traces. Pass it into `RoutedModel` from `makeRoutedModel` (line 762).
3. `Sources/FoundationModelsRouter/LanguageModelProfile.swift`: add `tracer: (any Tracer)? = nil` to `RoutedModel.init` (line 94; defaulted, so `HandBuiltProfileFixtures` and `RealModelHarness` compile unchanged) and a stored `let tracer: (any Tracer)?`.
4. `Sources/FoundationModelsRouter/RoutedEmbedder.swift`: wrap the container call:

```swift
import Tracing

public func embed(texts: [String]) async throws -> [[Float]] {
    try await (tracer ?? InstrumentationSystem.tracer).withSpan("FoundationModelsRouter.embed", ofKind: .client) { span in
        span.attributes["router.id"] = routerId.description
        span.attributes["model.ref"] = chosen.stringValue
        span.attributes["embedding.input_count"] = texts.count
        span.attributes["embedding.dimension"] = dimension
        return try await container.embed(texts: texts)
    }
}
```

Attribute names are stable API: document them in the `embed` doc comment. Never put the input texts or the vectors on the span.

Subtasks:

- [x] Add the package dependency and the two product links in `Package.swift`; `swift build` resolves and compiles.
- [x] Write `Tests/FoundationModelsRouterTests/EmbedTracingTests.swift` (see Tests) — fails to compile until `tracer:` exists on `Router.init` and `RouterTestFixtures.makeRouter`.
- [x] Thread `tracer` through `Router.init` → `makeRoutedModel` → `RoutedModel.init`; add `tracer: (any Tracer)? = nil` to `RouterTestFixtures.makeRouter` (`Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:146`).
- [x] Wrap `embed(texts:)` in `withSpan` with the four attributes; update its doc comment.
- [x] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [x] `Package.resolved` lists `swift-distributed-tracing` and `swift-service-context`; no `swift-otel` package is added to this library.
- [x] With `Router(tracer: InMemoryTracer())`, one `embed(texts: ["a", "b"])` produces exactly one finished span named `"FoundationModelsRouter.embed"`, kind `.client`, with attributes `router.id == router.id.description`, `model.ref == profile.embedding.chosen.stringValue`, `embedding.input_count == 2`, `embedding.dimension == RouterTestFixtures.stubDimension`, and `errors.isEmpty`.
- [x] When the embedding container throws, `embed` rethrows the same error and the single finished span has `errors.count == 1`.
- [x] With `tracer: nil` and no bootstrap, `embed` still returns its vectors (the no-op default tracer) — `ProfileLifecycleTests.embedRecordsNothing` from ^p3x0bbb passes unchanged.
- [x] The span carries no attribute whose value contains any input text.

## Tests

- [x] New `Tests/FoundationModelsRouterTests/EmbedTracingTests.swift`, `@Suite("Embed tracing")`, `import InMemoryTracing`, `import Tracing`, `@testable import FoundationModelsRouter`. Build the router as `SharedGenerationGateContentionTests.swift:213-222` does (`RouterTestFixtures.makeTempDir`, `StubModelLoader(container:dimension:)`, `RouterTestFixtures.makeRouter(cacheDir:loader:tracer:)`), resolve with `router.resolve(profile:reporting:)` as `ProfileLifecycleTests.swift:255` does:
  - `embedEmitsOneClientSpanWithAttributes` — assert name, kind, the four attributes, `errors.isEmpty`.
  - `embedFailureIsRecordedOnTheSpan` — define a local `struct ThrowingEmbeddingContainer: LoadedEmbeddingContainer` with the same conformance shape as `StubEmbeddingContainer` (`Helpers/RouterTestFixtures.swift:25-27`) but whose `embed(texts:)` throws. `HandBuiltProfileFixtures.makeProfile` always wraps a `StubEmbeddingContainer`, so do not use it here; construct the handle directly: `RoutedEmbedder(slot: .embedding, chosen:, footprintBytes: 0, resolution: SlotResolution(slot: .embedding, remainingBudgetBytes: 0, chosen:, considered: []), container: ThrowingEmbeddingContainer(), routerId:, recorder: InMemoryRecorder(), gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks), tracer: tracer)` (the same call `HandBuiltProfileFixtures.swift:69-78` makes, plus `tracer:`). Then `await #expect(throws: ThrowingEmbeddingContainer.Failure.self) { try await embedder.embed(texts: ["a"]) }`, `finishedSpans.count == 1`, `finishedSpans[0].errors.count == 1`.
  - `embedAttributesNeverCarryInputText` — embed `["needle-7f3a"]`, assert no attribute's `.string` value contains `"needle-7f3a"`.
- [x] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [x] Run `swift test` — expected: all tests pass. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tooling #performance