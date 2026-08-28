import Foundation
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^x45a4rf: every ``Router/resolve(profile:reporting:)`` call
/// opens one span, and every model that resolve loads through the
/// ``ModelLoader`` opens one child span under it.
///
/// Resolution is the slowest operation the library performs, so a trace of it
/// must say where the time went. The resolve span alone gives one figure; the
/// load spans under it divide that figure between the models the resolve had
/// to fetch. A slot the resident pool already held opens no load span, which
/// is what makes the difference between a first resolve and a later one
/// readable in a trace.
///
/// The router is built over stubs — a stub ``MachineProbe``, a stub
/// ``MetadataSource``, a stub ``ModelLoader`` and an `InMemoryTracer` — so the
/// suite needs no network, no GPU and no bootstrapped tracing backend.
@Suite("Resolve tracing")
struct ResolveTracingTests {
    /// The span name every resolve opens.
    private static let resolveSpanName = "FoundationModelsRouter.resolve"

    /// The span name every fresh model load opens.
    private static let loadSpanName = "FoundationModelsRouter.load"

    /// How many slots one profile resolves — `standard`, `flash` and
    /// `embedding` — and therefore how many models a fresh router loads.
    private static let slotCount = 3

    /// A GPU working set far too small for any candidate of the shared test
    /// profile, so the joint fit throws ``ResolutionFailure`` before the
    /// router reaches the loader.
    private static let budgetTooSmallForAnyCandidate: Int64 = 1_000

    /// The budget a router over ``RouterTestFixtures/stubProbe`` prices its
    /// first resolve against: nothing is resident yet, so the effective
    /// budget is the whole machine budget.
    private static var freshRouterBudgetBytes: Int64 {
        HostProfile(probe: RouterTestFixtures.stubProbe)
            .budget(headroomReserve: defaultHeadroomReserveBytes)
    }

    /// The loader every passing test resolves through: it vends stub
    /// containers and never fails.
    private static var succeedingLoader: StubModelLoader {
        StubModelLoader(
            container: UndrivenLanguageModelContainer(),
            dimension: RouterTestFixtures.stubDimension
        )
    }

    /// Builds a router over the shared stub fixtures that reports to `tracer`.
    ///
    /// - Parameters:
    ///   - cacheDir: The router's per-test cache directory.
    ///   - loader: The model loader the resolve loads through.
    ///   - tracer: The tracer the resolve opens its spans through.
    /// - Returns: The router.
    private static func makeRouter(
        cacheDir: URL,
        loader: any ModelLoader,
        tracer: any Tracer
    ) -> Router {
        RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: loader, tracer: tracer)
    }

    /// Resolves the shared test profile on `router`.
    ///
    /// - Parameter router: The router to resolve against.
    /// - Returns: The resolved, resident profile.
    /// - Throws: Whatever the resolve throws.
    private static func resolve(on router: Router) async throws -> LanguageModelProfile {
        try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// The finished spans of one operation name, in the order they ended.
    ///
    /// - Parameters:
    ///   - name: The operation name to keep.
    ///   - tracer: The tracer the resolve reported to.
    /// - Returns: The matching finished spans.
    private static func spans(
        named name: String,
        in tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == name }
    }

    @Test("one resolve opens one client span with one load span for each slot it loaded")
    func resolveOpensOneSpanWithAChildForEachLoad() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let router = Self.makeRouter(cacheDir: dir, loader: Self.succeedingLoader, tracer: tracer)
        _ = try await Self.resolve(on: router)

        let resolveSpans = Self.spans(named: Self.resolveSpanName, in: tracer)
        try #require(resolveSpans.count == 1)
        let resolveSpan = try #require(resolveSpans.first)
        #expect(resolveSpan.kind == .client)
        #expect(resolveSpan.parentSpanID == nil)

        // Nothing was resident yet, so every slot was loaded.
        let loadSpans = Self.spans(named: Self.loadSpanName, in: tracer)
        #expect(loadSpans.count == Self.slotCount)
        #expect(loadSpans.allSatisfy { $0.parentSpanID == resolveSpan.spanID })
        // The resolve span and its load spans are the whole trace: no other
        // span, and no load span that lost its parent.
        #expect(tracer.finishedSpans.count == Self.slotCount + resolveSpans.count)
    }

    @Test("the resolve span carries the router, the profile, the budget and each slot's winner")
    func resolveSpanCarriesTheDocumentedAttributes() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let router = Self.makeRouter(cacheDir: dir, loader: Self.succeedingLoader, tracer: tracer)
        let profile = try await Self.resolve(on: router)

        let span = try #require(Self.spans(named: Self.resolveSpanName, in: tracer).first)
        #expect(span.attributes.get("router.id") == .string(router.id.description))
        #expect(span.attributes.get("profile.definition_name") == .string(profile.definitionName))
        #expect(span.attributes.get("budget.bytes") == .int64(Self.freshRouterBudgetBytes))
        #expect(
            span.attributes.get("model.ref.standard") == .string(profile.standard.chosen.stringValue))
        #expect(span.attributes.get("model.ref.flash") == .string(profile.flash.chosen.stringValue))
        #expect(
            span.attributes.get("model.ref.embedding")
                == .string(profile.embedding.chosen.stringValue))
        #expect(span.errors.isEmpty)
    }

    @Test("each load span names the slot it filled, the model it loaded and that model's footprint")
    func loadSpansCarryTheDocumentedAttributes() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let router = Self.makeRouter(cacheDir: dir, loader: Self.succeedingLoader, tracer: tracer)
        let profile = try await Self.resolve(on: router)

        let loadSpans = Self.spans(named: Self.loadSpanName, in: tracer)
        try #require(loadSpans.count == Self.slotCount)
        #expect(loadSpans.allSatisfy { $0.kind == .client })

        // The three handles have three different container types, so the
        // facts each load span must repeat are read off them into one list.
        let expected: [(slot: ModelSlot, chosen: ModelRef, footprintBytes: Int64)] = [
            (profile.standard.slot, profile.standard.chosen, profile.standard.footprintBytes),
            (profile.flash.slot, profile.flash.chosen, profile.flash.footprintBytes),
            (profile.embedding.slot, profile.embedding.chosen, profile.embedding.footprintBytes),
        ]
        for handle in expected {
            let span = try #require(
                loadSpans.first { $0.attributes.get("slot") == .string(handle.slot.rawValue) })
            #expect(span.attributes.get("model.ref") == .string(handle.chosen.stringValue))
            #expect(span.attributes.get("footprint.bytes") == .int64(handle.footprintBytes))
            #expect(span.errors.isEmpty)
        }
    }

    @Test("a second resolve that reuses the resident models opens no load span")
    func aReusedSlotOpensNoLoadSpan() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let router = Self.makeRouter(cacheDir: dir, loader: Self.succeedingLoader, tracer: tracer)

        let first = try await Self.resolve(on: router)
        let resolveSpansAfterFirst = Self.spans(named: Self.resolveSpanName, in: tracer).count
        let loadSpansAfterFirst = Self.spans(named: Self.loadSpanName, in: tracer).count
        #expect(loadSpansAfterFirst == Self.slotCount)

        let second = try await Self.resolve(on: router)

        // `first` is read after the second resolve on purpose: its `deinit`
        // gives the residency back, so a profile released too early would let
        // the second resolve load every slot again.
        #expect(second.standard.chosen == first.standard.chosen)

        // The second resolve added its own span, and no load span at all:
        // every slot came from the resident pool.
        #expect(
            Self.spans(named: Self.resolveSpanName, in: tracer).count
                == resolveSpansAfterFirst + 1)
        #expect(Self.spans(named: Self.loadSpanName, in: tracer).count == loadSpansAfterFirst)
    }

    @Test("a resolve that fits nothing records the failure on its span and opens no load span")
    func aResolutionFailureIsRecordedOnTheResolveSpan() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        let router = Router(
            headroomReserve: 0,
            cacheDir: dir,
            tracer: tracer,
            probe: StubProbe(
                chip: "Apple Tiny",
                totalRAM: RouterTestFixtures.stubProbe.totalRAM,
                recommendedMaxWorkingSetSize: Self.budgetTooSmallForAnyCandidate
            ),
            metadataSource: StubMetadataSource(raw: RouterTestFixtures.rawMetadata),
            loader: Self.succeedingLoader
        )

        await #expect(throws: ResolutionFailure.self) {
            _ = try await Self.resolve(on: router)
        }

        let span = try #require(Self.spans(named: Self.resolveSpanName, in: tracer).first)
        try #require(span.errors.count == 1)
        #expect(span.errors.first?.error is ResolutionFailure)
        #expect(Self.spans(named: Self.loadSpanName, in: tracer).isEmpty)
    }

    @Test("a loader failure is recorded on the load span that raised it and on the resolve span")
    func aLoaderFailureIsRecordedOnBothSpans() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ResolveTracingTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tracer = InMemoryTracer()
        // `UnconfiguredModelLoader` throws at load time, so sizing and the
        // joint fit succeed and the first download is what fails.
        let router = Self.makeRouter(
            cacheDir: dir, loader: UnconfiguredModelLoader(), tracer: tracer)

        await #expect(throws: ModelLoaderError.self) {
            _ = try await Self.resolve(on: router)
        }

        let resolveSpan = try #require(Self.spans(named: Self.resolveSpanName, in: tracer).first)
        #expect(resolveSpan.errors.count == 1)

        // The resolve stops at the first failing slot, so exactly one load
        // span was opened and it carries the loader's own error.
        let loadSpans = Self.spans(named: Self.loadSpanName, in: tracer)
        try #require(loadSpans.count == 1)
        #expect(loadSpans[0].errors.count == 1)
        #expect(loadSpans[0].attributes.get("slot") == .string(ModelSlot.standard.rawValue))
    }
}
