import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Tracing

@testable import FoundationModelsRouter

/// A fixed-answer ``MachineProbe`` stub reporting whatever hardware facts a
/// test constructs it with.
///
/// Shared by every suite that builds a ``Router`` over stubbed hardware
/// (e.g. `AutoCompactionTests`, `RoutedSessionToolContextBindingTests`) so
/// the stub lives in exactly one place.
struct StubProbe: MachineProbe {
    let chip: String
    let totalRAM: Int64
    let recommendedMaxWorkingSetSize: Int64
}

/// A ``MetadataSource`` stub answering every fetch with one canned payload.
struct StubMetadataSource: MetadataSource {
    let raw: RawRepoMetadata
    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
}

/// A ``LoadedEmbeddingContainer`` stub embedding every text as a constant
/// vector of the configured dimension.
struct StubEmbeddingContainer: LoadedEmbeddingContainer {
    let dimension: Int
    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [Float](repeating: 0.5, count: dimension) }
    }
}

/// A ``ModelLoader`` stub vending one caller-supplied LLM container for
/// every generation slot and a ``StubEmbeddingContainer`` for the embedding
/// slot.
struct StubModelLoader: ModelLoader {
    let container: any LoadedLLMContainer
    let dimension: Int

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
        return container
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
        return StubEmbeddingContainer(dimension: dimension)
    }

    func preload(container: any LoadedModelContainer) async throws {}
}

/// Shared fixtures for building a stub-backed ``Router`` and resolved
/// profile in tests: the canned repo metadata a ``StubMetadataSource``
/// serves, the standard test ``ProfileDefinition``, and factories for the
/// per-test temp directory and the router itself — so the fixture data
/// lives in exactly one place instead of being repeated per suite.
enum RouterTestFixtures {
    /// The canned `config.json` payload behind ``rawMetadata`` — a tiny,
    /// valid model config the resolver can size. Its window is
    /// `ScriptedSessionContext.tokens`, so a profile that names no context
    /// resolves at the window the tests state.
    static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "max_position_embeddings": \(ScriptedSessionContext.tokens),
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    /// The canned repo file-tree payload behind ``rawMetadata`` — one
    /// plausible weights file the resolver can size.
    static let treeJSON = Data(
        """
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    /// The canned repo metadata a test's ``StubMetadataSource`` serves.
    static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    /// The length of each vector that every stub embedder makes.
    static let stubDimension = 8

    /// The fixed hardware every shared-fixture router probes: ample RAM, so
    /// resolution never fails on the stub metadata's tiny model.
    static let stubProbe = StubProbe(
        chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30)

    /// The standard test profile: one candidate per slot.
    ///
    /// - Parameter context: The profile's working-context override. The
    ///   default is `ScriptedSessionContext.tokens`, the small, known window
    ///   the tests state. Pass `nil` to derive the window from the model.
    /// - Returns: The profile definition.
    static func profile(context: Int? = ScriptedSessionContext.tokens) -> ProfileDefinition {
        ProfileDefinition(
            name: "coding",
            description: "test profile",
            standard: ["org/std-a"],
            flash: ["org/flash-a"],
            embedding: ["org/emb-a"],
            context: context
        )
    }

    /// Creates a fresh per-test temp directory named `<prefix>-<UUID>`.
    ///
    /// - Parameter prefix: The calling suite's name, so a leaked directory
    ///   is attributable.
    /// - Returns: The created directory's URL.
    static func makeTempDir(prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs `body`, and when `body` throws, does `cleanup` and removes
    /// `directory` before it throws the error again.
    ///
    /// This is the one cleanup-on-throw step of the fixture makes (rule T1: a
    /// fixture closes also when the body throws). A make calls it for each
    /// step after it made its temporary directory. When `body` returns, the
    /// directory stays: the end of the fixture removes it.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. `body` and `cleanup` run
    ///     there.
    ///   - directory: The temporary directory of the fixture.
    ///   - cleanup: The other cleanup of the fixture when `body` throws, for
    ///     example the close of a session that an earlier step made. It runs
    ///     before the removal of `directory`. The default does nothing.
    ///   - body: The step that can throw.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws, after the cleanup.
    static func removingDirectoryOnThrow<Value>(
        isolation: isolated (any Actor)? = #isolation,
        _ directory: URL,
        alsoOnThrow cleanup: () async -> Void = {},
        _ body: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await body()
        } catch {
            await cleanup()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Builds a ``Router`` over ``stubProbe`` and ``rawMetadata``,
    /// parameterized by whatever loader and recorder the test scenario
    /// needs.
    ///
    /// - Parameters:
    ///   - id: The router's recording root id. Pass a prior router's `id` to
    ///     simulate a fresh process continuing the same recording root.
    ///     Defaults to a fresh ULID.
    ///   - cacheDir: The router's cache directory (a per-test temp dir).
    ///   - recordingsDir: The durable transcripts root, or `nil` (the
    ///     default) for a router with no durable root.
    ///   - recorder: The transcript recorder. Defaults to a fresh
    ///     ``InMemoryRecorder``.
    ///   - loader: The model loader vending the test's stub containers.
    ///   - tracer: The tracer every vended handle opens its embed span
    ///     through, or `nil` (the default) to read
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - samplingMode: The decoding strategy the router passes to every
    ///     backend it makes, or `nil` (the default) for the provider default.
    ///   - pool: The resident-model pool. Defaults to a fresh pool, so
    ///     parallel suites never share residents.
    /// - Returns: The router.
    static func makeRouter(
        id: ULID = .generate(),
        cacheDir: URL,
        recordingsDir: URL? = nil,
        recorder: any TranscriptRecorder = InMemoryRecorder(),
        loader: any ModelLoader,
        tracer: (any Tracer)? = nil,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            tracer: tracer,
            probe: stubProbe,
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: loader,
            samplingMode: samplingMode,
            pool: pool
        )
    }

    /// Builds a router whose loader vends `container` for each generation
    /// slot, and resolves the standard test profile ``profile(context:)``.
    ///
    /// - Parameters:
    ///   - container: The container every generation slot resolves to.
    ///   - cacheDir: The router's cache directory (a per-test temp dir).
    ///   - runClock: The clock of the run plane of each session of the
    ///     profile (``Router/useRunClock(_:)``), or `nil` (the default) for
    ///     the real time. A test gives a `ManualRunClock`, so each timer of
    ///     its sessions ends only when the test advances that clock.
    ///   - recordingsDir: The durable transcripts root, or `nil` (the
    ///     default) for a router that records only in memory. A router with
    ///     a root writes each session to disk (``JSONLRecorder``), so a test
    ///     can restore the sessions.
    /// - Returns: The router and the profile it resolved. A caller that has
    ///   to keep the router alive for the whole test keeps both.
    /// - Throws: What the resolve throws.
    static func resolveStandardProfile(
        over container: any LoadedLLMContainer, cacheDir: URL, runClock: (any RunClock)? = nil,
        recordingsDir: URL? = nil
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        let router = makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            recorder: recordingsDir.map { JSONLRecorder(directory: $0) } ?? InMemoryRecorder(),
            loader: StubModelLoader(container: container, dimension: stubDimension))
        if let runClock {
            await router.useRunClock(runClock)
        }
        let resolved = try await router.resolve(profile: profile(), reporting: ResolutionProgress())
        return (router, resolved)
    }

    /// A router id's recording root under `recordingsDir` — the directory
    /// ``TranscriptTree/load(under:)`` reads.
    ///
    /// The one shared implementation of this path rule for every suite that
    /// reads a recording root back from disk.
    ///
    /// - Parameters:
    ///   - routerId: The id of the router that owns the recording root.
    ///   - recordingsDir: The durable transcripts root.
    /// - Returns: The recording root directory.
    static func routerDirectory(routerId: ULID, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
    }

    /// The directory of a recorded session under the recording root of a
    /// router.
    ///
    /// A root session has its directory directly under the recording root.
    /// A fork has its directory under the directory of its parent, so a
    /// fork path starts at the root session and ends at the fork.
    ///
    /// - Parameters:
    ///   - sessionPath: The ids from the root session to the session, in
    ///     order. A root session is a path of one id.
    ///   - routerId: The id of the router that owns the recording root.
    ///   - recordingsDir: The durable transcripts root.
    /// - Returns: The session directory.
    static func sessionDirectory(of sessionPath: ULID..., routerId: ULID, recordingsDir: URL) -> URL {
        sessionDirectory(alongPath: sessionPath, routerId: routerId, recordingsDir: recordingsDir)
    }

    /// The sidecar file (`session.json`) of a recorded session under the
    /// recording root of a router.
    ///
    /// The one shared implementation of this path rule for every suite that
    /// reads or rewrites a recorded sidecar.
    ///
    /// - Parameters:
    ///   - sessionPath: The ids from the root session to the session, in
    ///     order. A root session is a path of one id.
    ///   - routerId: The id of the router that owns the recording root.
    ///   - recordingsDir: The durable transcripts root.
    /// - Returns: The sidecar file URL.
    static func sidecarURL(of sessionPath: ULID..., routerId: ULID, recordingsDir: URL) -> URL {
        sidecarURL(
            inSessionDirectory: sessionDirectory(
                alongPath: sessionPath, routerId: routerId, recordingsDir: recordingsDir))
    }

    /// The directory at the end of a session path under the recording root
    /// of a router. The variadic helpers share this one implementation.
    ///
    /// - Parameters:
    ///   - sessionPath: The ids from the root session to the session, in
    ///     order.
    ///   - routerId: The id of the router that owns the recording root.
    ///   - recordingsDir: The durable transcripts root.
    /// - Returns: The session directory.
    private static func sessionDirectory(alongPath sessionPath: [ULID], routerId: ULID, recordingsDir: URL) -> URL {
        sessionPath.reduce(routerDirectory(routerId: routerId, recordingsDir: recordingsDir)) { directory, id in
            directory.appendingPathComponent(id.description, isDirectory: true)
        }
    }

    /// The sidecar file (`session.json`) in a session directory.
    ///
    /// - Parameter sessionDirectory: The directory of the session.
    /// - Returns: The sidecar file URL.
    static func sidecarURL(inSessionDirectory sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(sessionSidecarFileName, isDirectory: false)
    }
}
