---
assignees:
- claude-code
depends_on:
- 01M11KJF2HPVBQYG883P3X0BBB
position_column: todo
position_ordinal: '8380'
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

- [ ] Add the package dependency and the two product links in `Package.swift`; `swift build` resolves and compiles.
- [ ] Write `Tests/FoundationModelsRouterTests/EmbedTracingTests.swift` (see Tests) — fails to compile until `tracer:` exists on `Router.init` and `RouterTestFixtures.makeRouter`.
- [ ] Thread `tracer` through `Router.init` → `makeRoutedModel` → `RoutedModel.init`; add `tracer: (any Tracer)? = nil` to `RouterTestFixtures.makeRouter` (`Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:146`).
- [ ] Wrap `embed(texts:)` in `withSpan` with the four attributes; update its doc comment.
- [ ] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [ ] `Package.resolved` lists `swift-distributed-tracing` and `swift-service-context`; no `swift-otel` package is added to this library.
- [ ] With `Router(tracer: InMemoryTracer())`, one `embed(texts: ["a", "b"])` produces exactly one finished span named `"FoundationModelsRouter.embed"`, kind `.client`, with attributes `router.id == router.id.description`, `model.ref == profile.embedding.chosen.stringValue`, `embedding.input_count == 2`, `embedding.dimension == RouterTestFixtures.stubDimension`, and `errors.isEmpty`.
- [ ] When the embedding container throws, `embed` rethrows the same error and the single finished span has `errors.count == 1`.
- [ ] With `tracer: nil` and no bootstrap, `embed` still returns its vectors (the no-op default tracer) — `ProfileLifecycleTests.embedRecordsNothing` from ^p3x0bbb passes unchanged.
- [ ] The span carries no attribute whose value contains any input text.

## Tests

- [ ] New `Tests/FoundationModelsRouterTests/EmbedTracingTests.swift`, `@Suite("Embed tracing")`, `import InMemoryTracing`, `import Tracing`, `@testable import FoundationModelsRouter`. Build the router as `SharedGenerationGateContentionTests.swift:213-222` does (`RouterTestFixtures.makeTempDir`, `StubModelLoader(container:dimension:)`, `RouterTestFixtures.makeRouter(cacheDir:loader:tracer:)`), resolve with `router.resolve(profile:reporting:)` as `ProfileLifecycleTests.swift:255` does:
  - `embedEmitsOneClientSpanWithAttributes` — assert name, kind, the four attributes, `errors.isEmpty`.
  - `embedFailureIsRecordedOnTheSpan` — define a local `struct ThrowingEmbeddingContainer: LoadedEmbeddingContainer` with the same conformance shape as `StubEmbeddingContainer` (`Helpers/RouterTestFixtures.swift:25-27`) but whose `embed(texts:)` throws. `HandBuiltProfileFixtures.makeProfile` always wraps a `StubEmbeddingContainer`, so do not use it here; construct the handle directly: `RoutedEmbedder(slot: .embedding, chosen:, footprintBytes: 0, resolution: SlotResolution(slot: .embedding, remainingBudgetBytes: 0, chosen:, considered: []), container: ThrowingEmbeddingContainer(), routerId:, recorder: InMemoryRecorder(), gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks), tracer: tracer)` (the same call `HandBuiltProfileFixtures.swift:69-78` makes, plus `tracer:`). Then `await #expect(throws: ThrowingEmbeddingContainer.Failure.self) { try await embedder.embed(texts: ["a"]) }`, `finishedSpans.count == 1`, `finishedSpans[0].errors.count == 1`.
  - `embedAttributesNeverCarryInputText` — embed `["needle-7f3a"]`, assert no attribute's `.string` value contains `"needle-7f3a"`.
- [ ] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [ ] Run `swift test` — expected: all tests pass. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tooling #performance