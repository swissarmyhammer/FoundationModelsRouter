import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import HuggingFace
import InMemoryTracing
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

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
            loader: LiveModelLoader(
                downloader: #hubDownloader(),
                tokenizerLoader: #huggingFaceTokenizerLoader()
            ),
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
        tracer.finishedSpans.filter { $0.operationName == RouterTracing.SpanName.load }
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
            guard case .string(let ref)? = span.attributes.get(RouterTracing.AttributeKey.modelRef)
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
        #expect(await fixture.pool.residentModelCount == gatedRealProfileResidentContainerCount)

        let firstAnswer = try await answer(on: makeSession(from: try #require(firstProfile)))
        #expect(!firstAnswer.isEmpty)
        let secondAnswer = try await answer(on: makeSession(from: try #require(secondProfile)))
        #expect(!secondAnswer.isEmpty)

        // Residency follows ARC: dropping both profiles gives every model back.
        firstProfile = nil
        secondProfile = nil
        #expect(try await residentModelCountOnceDrained(fixture.pool) == 0)
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

        // Residency follows ARC: dropping the first profile gives back its share.
        firstProfile = nil
        // The second profile still holds every key, so the pool evicted nothing.
        #expect(await fixture.pool.residentModelCount == gatedRealProfileResidentContainerCount)

        let reply = try await answer(on: secondSession)
        #expect(!reply.isEmpty)
        #expect(fixture.first.loadSpans.count == firstLoadSpanCount)
        #expect(fixture.second.loadSpans.isEmpty)

        withExtendedLifetime(secondProfile) {}
    }
}

/// The resident model count of `pool` once the drains that dropped profiles
/// started have run, or the count at the end of a bounded wait.
///
/// A dropped profile queues its residency and starts a drain in a task, so
/// the eviction is not done when the drop returns. The wait polls the count
/// and stops at zero.
///
/// - Parameter pool: The pool to read.
/// - Returns: The resident model count.
/// - Throws: `CancellationError` when the test is cancelled.
private func residentModelCountOnceDrained(_ pool: ModelPool) async throws -> Int {
    for _ in 0..<600 {
        let count = await pool.residentModelCount
        if count == 0 { return count }
        try await Task.sleep(for: .milliseconds(50))
    }
    return await pool.residentModelCount
}
