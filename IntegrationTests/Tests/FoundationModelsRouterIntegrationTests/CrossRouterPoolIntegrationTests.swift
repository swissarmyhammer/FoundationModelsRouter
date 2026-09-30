import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import InMemoryTracing
import MLXLMCommon
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The decoding strategy both routers of this suite generate with.
///
/// Argmax, the pin every other gated suite of this target states. The router
/// carries the mode, not the container (`model-pool.md` §2.5). A container that
/// two routers share decodes with each router's own mode.
private let crossRouterSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The instructions each session of this suite is vended with.
private let crossRouterInstructions = "You are a terse assistant."

/// The one prompt each session of this suite answers.
private let crossRouterPrompt = "Say hello in one short sentence."

// MARK: - One router on the shared pool

/// One router of the pair, with the tracer that counts the spans it opens.
private struct PooledRouter {
    /// The router.
    let router: Router

    /// The tracer this router opens every span through.
    let tracer: InMemoryTracer

    /// Makes a router over its own live loader and its own tracer, on `pool`.
    ///
    /// Each router gets its own ``LiveModelLoader``. The pool runs the loader
    /// of the router that first names a key, so a second router that finds the
    /// key resident never calls its own loader. Each router also gets its own
    /// tracer, so the `load` spans of one router are counted apart from the
    /// spans of the other.
    ///
    /// - Parameters:
    ///   - pool: The pool both routers resolve into.
    ///   - root: The directory the test writes under.
    ///   - name: The subdirectory this router caches and records under.
    /// - Returns: The router and its tracer.
    static func make(pool: ModelPool, root: URL, name: String) -> PooledRouter {
        let tracer = InMemoryTracer()
        let home = root.appendingPathComponent(name, isDirectory: true)
        let router = Router(
            cacheDir: home.appendingPathComponent("cache", isDirectory: true),
            recordingsDir: home.appendingPathComponent("recordings", isDirectory: true),
            tracer: tracer,
            loader: LiveModelLoader(),
            samplingMode: crossRouterSamplingMode,
            pool: pool
        )
        return PooledRouter(router: router, tracer: tracer)
    }

    /// Resolves ``gatedRealProfile`` on this router.
    ///
    /// - Returns: The resolved, resident profile.
    /// - Throws: Whatever the resolve throws.
    func resolve() async throws -> LanguageModelProfile {
        try await router.resolve(profile: gatedRealProfile, reporting: ResolutionProgress())
    }

    /// The `load` spans this router opened so far.
    var loadSpans: [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.load }
    }
}

// MARK: - Two routers on one pool

/// Two routers over one pool, and the directory both write under.
private struct TwoRouterFixture {
    /// The pool both routers resolve into. Never ``ModelPool/shared``, so no
    /// other suite can hold a resident in it.
    let pool: ModelPool

    /// The directory both routers cache and record under.
    let root: URL

    /// The router that resolves first, and so loads.
    let first: PooledRouter

    /// The router that resolves second, and so finds every key resident.
    let second: PooledRouter

    /// Makes the pool, the directory and the two routers.
    ///
    /// - Returns: The fixture.
    static func make() -> TwoRouterFixture {
        let pool = ModelPool()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CrossRouterPoolIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        return TwoRouterFixture(
            pool: pool,
            root: root,
            first: .make(pool: pool, root: root, name: "first"),
            second: .make(pool: pool, root: root, name: "second")
        )
    }

    /// Removes the directory both routers wrote under.
    func removeDirectories() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Reading the spans and the profile

/// The model references `spans` name, as their `model.ref` attribute spells
/// them.
///
/// - Parameter spans: The finished `load` spans to read.
/// - Returns: The distinct references.
private func modelRefs(of spans: [FinishedInMemorySpan]) -> Set<String> {
    Set(
        spans.compactMap { span -> String? in
            guard case .string(let ref)? = span.attributes.get(RouterTelemetry.AttributeKey.modelRef)
            else { return nil }
            return ref
        })
}

/// The distinct model references a resolved profile holds, in canonical string
/// form.
///
/// - Parameter profile: The resolved profile.
/// - Returns: The distinct references its three handles chose.
private func distinctModelRefs(of profile: LanguageModelProfile) -> Set<String> {
    Set([profile.standard.chosen, profile.flash.chosen, profile.embedding.chosen].map(\.stringValue))
}

/// Vends one session from the `standard` handle of `profile`.
///
/// - Parameter profile: The resolved profile.
/// - Returns: The session.
private func makeSession(from profile: LanguageModelProfile) -> RoutedSession {
    profile.standard.makeSession(instructions: crossRouterInstructions)
}

/// Sends the suite's one prompt to `session`.
///
/// Every answer states ``GatedRealModelBudget/responseTokenCeiling`` as its
/// reply ceiling, so a `<think>` block that does not stop cannot make the
/// answer run without end.
///
/// - Parameter session: The session to answer.
/// - Returns: The answer.
/// - Throws: Whatever the answer throws.
private func answer(on session: RoutedSession) async throws -> String {
    try await session.respond(
        to: crossRouterPrompt,
        maxTokens: GatedRealModelBudget.responseTokenCeiling
    )
}

// MARK: - Suite

/// Gated real-model coverage for `model-pool.md` §3: two routers over one
/// ``ModelPool`` load a real model one time.
///
/// ## What it proves
///
/// The first router resolves ``gatedRealProfile`` on an empty pool and opens one
/// `load` span for each resident container the profile asks for. The second
/// router resolves the same profile on the same pool and opens no `load` span
/// at all: every key is resident, so the pool never calls the second router's
/// loader. A session from each router answers a prompt over the one shared
/// container. A release from the first router keeps the container for the
/// second router, whose session still answers with no new `load` span.
///
/// A router and an Extras `PooledModel` of one name share one resident model
/// in either order. After a resolve, a `PooledModel` session answers over the
/// model of the router, and the loader of the pool loads nothing. After a
/// `PooledModel` session, a resolve takes that model and opens no `load` span
/// for it.
///
/// ## Why the coverage is gated
///
/// `Tests/FoundationModelsRouterTests/CrossRouterResidencyTests.swift` proves
/// the same rules over stub loaders. Only a real ``LiveModelLoader`` proves
/// that a real MLX container survives the first router's release, because the
/// live loader's eviction reaches the MLX layer's own process-global cache
/// (`model-pool.md` §1.4).
///
/// ## Why the pool is explicit
///
/// Both routers get one fresh ``ModelPool``, never ``ModelPool/shared``. A
/// shared pool would let a resident of another suite satisfy a key here, and
/// the span counts would then depend on the order the suites ran in.
///
/// ## The measurement of 2026-09-05
///
/// Two runs on one Apple silicon box with every model in the Hugging Face
/// cache: the suite alone, then the whole nested package.
///
/// | alone | whole package | test |
/// |---|---|---|
/// | 47.2 | 46.3 | the second router's resolve opens no load span, and a session from each router answers |
/// | 25.9 | 26.0 | a release from the first router keeps the second router's session alive |
///
/// The first test pays two resolves and two answers, the second two resolves
/// and one answer. The dearer test ran at 39 percent of the two-minute budget of
/// that time. The suite has no time limit now.
@Suite(
    "Gated real-model coverage: two live routers over one pool load a model one time",
    .serialized,
    .exclusiveRealModel
)
struct CrossRouterPoolIntegrationTests {
    @Test("the second router's resolve opens no load span, and a session from each router answers")
    func secondRouterOpensNoLoadSpans() async throws {
        let fixture = TwoRouterFixture.make()
        defer { fixture.removeDirectories() }

        var firstProfile: LanguageModelProfile? = try await fixture.first.resolve()
        let firstLoadSpans = fixture.first.loadSpans
        #expect(firstLoadSpans.count == gatedRealProfileResidentContainerCount)
        #expect(modelRefs(of: firstLoadSpans) == distinctModelRefs(of: try #require(firstProfile)))

        var secondProfile: LanguageModelProfile? = try await fixture.second.resolve()
        #expect(
            distinctModelRefs(of: try #require(secondProfile))
                == distinctModelRefs(of: try #require(firstProfile)))
        #expect(fixture.second.loadSpans.isEmpty)
        #expect(fixture.first.loadSpans.count == firstLoadSpans.count)
        #expect(fixture.pool.residentModelCount == gatedRealProfileResidentContainerCount)

        let firstAnswer = try await answer(on: makeSession(from: try #require(firstProfile)))
        #expect(!firstAnswer.isEmpty)
        let secondAnswer = try await answer(on: makeSession(from: try #require(secondProfile)))
        #expect(!secondAnswer.isEmpty)

        // Residency follows ARC: dropping both profiles gives every model back.
        firstProfile = nil
        secondProfile = nil
        #expect(try await fixture.pool.admittedResidentModelCount == 0)
    }

    @Test("a release from the first router keeps the second router's session alive")
    func releaseFromTheFirstRouterKeepsTheSecondRouterAlive() async throws {
        let fixture = TwoRouterFixture.make()
        defer { fixture.removeDirectories() }

        var firstProfile: LanguageModelProfile? = try await fixture.first.resolve()
        let secondProfile = try await fixture.second.resolve()
        let secondSession = makeSession(from: secondProfile)
        let firstLoadSpanCount = fixture.first.loadSpans.count
        #expect(firstProfile != nil)

        // Residency follows ARC: the drop of the first profile releases its holds.
        firstProfile = nil
        // The second profile still holds every key, so the pool evicts nothing.
        #expect(fixture.pool.residentModelCount == gatedRealProfileResidentContainerCount)

        let reply = try await answer(on: secondSession)
        #expect(!reply.isEmpty)
        #expect(fixture.first.loadSpans.count == firstLoadSpanCount)
        #expect(fixture.second.loadSpans.isEmpty)

        withExtendedLifetime(secondProfile) {}
    }

    // MARK: - A router and a PooledModel on one pool

    @Test("a PooledModel of the flash model of a resolve answers over the model of the router, and loads nothing")
    func pooledModelAfterResolveSharesTheResidentModel() async throws {
        let fixture = PooledModelFixture.make()
        defer { fixture.removeDirectories() }

        var profile: LanguageModelProfile? = try await fixture.router.resolve()
        let flashRef = try #require(profile).flash.chosen
        let residentAfterResolve = fixture.pool.residentModelCount
        var session: PooledSession? = try await PooledModel(ref: flashRef, pool: fixture.pool)
            .session(instructions: crossRouterInstructions)
        let reply = try await #require(session).respond(to: crossRouterPrompt)

        // The pool loader loaded nothing: the session took a hold of the
        // flash model that the router loaded.
        #expect(!reply.isEmpty)
        #expect(fixture.poolLoader.loadCount == 0)
        #expect(fixture.pool.residentModelCount == residentAfterResolve)

        session = nil
        profile = nil
        #expect(try await fixture.pool.admittedResidentModelCount == 0)
    }

    @Test("a resolve after a PooledModel of its flash model answers over that model, and the router loads no flash model")
    func resolveAfterPooledModelSharesTheResidentModel() async throws {
        let fixture = PooledModelFixture.make()
        defer { fixture.removeDirectories() }

        var session: PooledSession? = try await PooledModel(ref: RealModels.flash, pool: fixture.pool)
            .session(instructions: crossRouterInstructions)
        var profile: LanguageModelProfile? = try await fixture.router.resolve()
        // The session of the router is a temporary value: a live session keeps
        // the holds of its profile, and the end of the test drops them all.
        let reply = try await answer(
            on: try #require(profile).flash.makeSession(instructions: crossRouterInstructions))

        // The pool loader loaded the flash model one time, and the router
        // loaded only the other models of the profile.
        #expect(!reply.isEmpty)
        #expect(try #require(profile).flash.chosen == RealModels.flash)
        #expect(fixture.poolLoader.loadCount == 1)
        #expect(!modelRefs(of: fixture.router.loadSpans).contains(RealModels.flash.stringValue))
        #expect(fixture.router.loadSpans.count == gatedRealProfileResidentContainerCount - 1)
        #expect(fixture.pool.residentModelCount == gatedRealProfileResidentContainerCount)

        withExtendedLifetime(session) {}
        session = nil
        profile = nil
        #expect(try await fixture.pool.admittedResidentModelCount == 0)
    }
}

// MARK: - A router and a PooledModel on one pool

/// The loader of the pool of ``PooledModelFixture``: the Extras
/// `MLXModelLoader`, with a count of the loads that it runs. A `PooledModel`
/// loads through it; the router loads through its own ``LiveModelLoader``.
private final class CountingPoolLoader: PooledModelLoader {
    /// The loader that loads each model.
    private let wrapped = MLXModelLoader()

    /// The count of the loads of this loader.
    private let loads = Atomic<Int>(0)

    /// The count of the loads of this loader so far.
    var loadCount: Int { loads.load(ordering: .sequentiallyConsistent) }

    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        try await load(key: key) { _ in }
    }

    func load(
        key: ModelPoolKey, progressHandler: @escaping @Sendable (ModelLoadProgress) -> Void
    ) async throws -> any Sendable {
        loads.add(1, ordering: .sequentiallyConsistent)
        return try await wrapped.load(key: key, progressHandler: progressHandler)
    }

    func evict(_ container: any Sendable) async {
        await wrapped.evict(container)
    }

    func footprintBytes(of key: ModelPoolKey) async throws -> Int64 {
        try await wrapped.footprintBytes(of: key)
    }
}

/// One router and one pool whose own loader is a ``CountingPoolLoader``, and
/// the directory the router writes under.
private struct PooledModelFixture {
    /// The loader of ``pool``: it loads each model that a `PooledModel`
    /// acquires first.
    let poolLoader: CountingPoolLoader

    /// The pool of the router and of each `PooledModel` of the test. Never
    /// ``ModelPool/shared``, so no other suite can hold a resident in it.
    let pool: ModelPool

    /// The directory the router caches and records under.
    let root: URL

    /// The router, over its own ``LiveModelLoader``.
    let router: PooledRouter

    /// Makes the loader, the pool, the directory and the router.
    ///
    /// - Returns: The fixture.
    static func make() -> PooledModelFixture {
        let poolLoader = CountingPoolLoader()
        let pool = ModelPool(loader: poolLoader)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CrossRouterPoolIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        return PooledModelFixture(
            poolLoader: poolLoader, pool: pool, root: root, router: .make(pool: pool, root: root, name: "router"))
    }

    /// Removes the directory the router wrote under.
    func removeDirectories() {
        try? FileManager.default.removeItem(at: root)
    }
}
