import Foundation

/// The default in-flight fork-session ceiling per resolved profile.
///
/// Shared between ``Router/init(id:headroomReserve:maxConcurrentForks:cacheDir:recordingsDir:recorder:recordingLevel:redact:probe:metadataSource:loader:)``
/// and ``RoutedModel/init(slot:chosen:footprintBytes:resolution:container:routerId:recorder:durableRecording:maxConcurrentForks:generationGate:forkAdmissionGate:)``'s
/// own default, so a ``RoutedModel`` constructed directly (outside a
/// ``Router``, e.g. in tests) admits the same ceiling a router-vended one
/// would.
///
/// `public` (not `internal`) because both initializers that default to it are
/// `public`: a default argument expression must be at least as visible as the
/// declaration it defaults on, since it is evaluated at every call site.
public let defaultMaxConcurrentForks = 4

/// The default headroom reserved out of the machine budget for OS/app use.
///
/// `public` for the same reason as ``defaultMaxConcurrentForks``: it is the
/// default argument for ``Router/init(id:headroomReserve:maxConcurrentForks:cacheDir:recordingsDir:recorder:recordingLevel:redact:probe:metadataSource:loader:)``,
/// a `public` initializer, and a default argument expression must be at
/// least as visible as the declaration it defaults on.
public let defaultHeadroomReserveBytes: Int64 = 4 << 30

/// How much of a session's activity is recorded.
///
/// The level (and the ``Router``'s `redact` hook) are enforced by a
/// ``GatingRecorder`` the router wraps its sink in, so every event source — the
/// session ``generate`` chokepoint and ``RoutedEmbedder/embed(_:)`` alike —
/// honors them at record time.
public enum RecordingLevel: String, Sendable, Codable, Equatable {
    /// Record nothing.
    case off
    /// Record event metadata (slots, models, metering) but not prompt/response text.
    case metadataOnly
    /// Record everything, including prompt and response text.
    case full
}

/// The exact identity of a resident model artifact: what determines whether
/// two candidate resolutions can share one loaded instance.
///
/// Two candidates share a pool entry only when both the ``ModelRef`` (which
/// already carries the pinned revision, if any — see ``ModelRef``) *and* the
/// ``Role`` match. A ref used as a generation model at two different working
/// contexts is **not** interchangeable — the KV cache is sized into the
/// loaded container at load time — so ``Role/llm(context:)`` carries the
/// context; a ref used as an embedder has no such axis (``Footprint/embedder(weightBytes:)``
/// carries no KV term), so ``Role/embedding`` carries none either. A ref
/// loaded as an embedder is never interchangeable with the same ref loaded as
/// a generation model, since the two produce structurally different
/// container types (``LoadedEmbeddingContainer`` vs. ``LoadedLLMContainer``).
private struct ResidencyKey: Hashable, Sendable {
    /// The role a resident model was loaded under, and the load-time
    /// parameter (if any) that changes its resident bytes.
    enum Role: Hashable, Sendable {
        /// Loaded as a generation model at this working context.
        case llm(context: Int)
        /// Loaded as an embedder — context-independent (weights only).
        case embedding
    }

    /// The model reference (repo + optional pinned revision).
    let ref: ModelRef

    /// The role this instance was loaded under.
    let role: Role
}

/// A pool entry's loaded container, distinguishing the two container
/// protocols so a reused entry can be handed back to whichever concrete
/// handle (``RoutedLLM`` / ``RoutedEmbedder``) needs it without a runtime
/// cast from the common ``LoadedModelContainer`` base.
private enum PooledContainer: Sendable {
    case llm(any LoadedLLMContainer)
    case embedding(any LoadedEmbeddingContainer)

    /// The container upcast to the common base, for ``ModelLoader/evict(container:)``.
    var erased: any LoadedModelContainer {
        switch self {
        case .llm(let container): return container
        case .embedding(let container): return container
        }
    }
}

/// One resident model in the router's pool: reference-counted across every
/// profile currently referencing it, evicted only once that count reaches
/// zero.
///
/// `generationGate`/`forkAdmissionGate` are minted once, at first load, and
/// handed to every ``RoutedModel`` built over this entry from then on — a
/// second profile that reuses this entry gets the *same* gate instances, so
/// generation across both profiles' handles still serializes against the one
/// underlying model (see ``RoutedModel/generationGate``).
private struct PoolEntry: Sendable {
    /// How many profiles currently reference this model.
    var refcount: Int

    /// This model's own `× 1.2` margined footprint, as first computed when it
    /// was loaded — the real, steady-state cost charged against the shared
    /// budget for as long as this entry exists, independent of whatever
    /// marginal (possibly zero) cost a later resolve computed when reusing it.
    let footprintBytes: Int64

    /// The loaded container.
    let container: PooledContainer

    /// The shared generation gate every handle built over this entry reuses.
    let generationGate: AsyncSemaphore

    /// The shared fork-admission gate every handle built over this entry reuses.
    let forkAdmissionGate: AsyncSemaphore
}

/// The shared entry point: built once at app start, it resolves authored
/// ``ProfileDefinition``s into resident ``LanguageModelProfile``s for *this*
/// machine, reporting UI-bindable progress.
///
/// The router holds the disposable host-profile and repo-metadata caches and the
/// injected seams that keep resolution unit-testable: a ``MachineProbe`` for the
/// budget, a ``MetadataSource`` for sizing, and a ``ModelLoader`` for the
/// download+load. Its ``id`` is the recording root every session and transcript
/// hangs off of, sortable by construction time.
///
/// ## Pooled residency
///
/// A router admits several concurrently resident profiles, not one at a
/// time: the memory budget still has exactly one authority (this actor), but
/// that authority now prices the *union* of every currently resident model
/// against the one shared budget, rather than one profile's trio against the
/// whole budget. Residency is reference-counted per ``ResidencyKey`` (a
/// model's ref, revision, and load-time role/context — see that type) across
/// every profile that references it: two profiles naming the same model
/// share one loaded instance and its generation gate, and a model stays
/// loaded only while at least one profile still references it (see
/// ``resolve(_:reporting:)`` and ``release(token:)``).
///
/// `resolve(_:reporting:)` itself is single-flight — serialized by
/// `poolLock` — so the budget decision for a new resolve is never
/// made against a stale snapshot of the pool while another resolve is
/// concurrently downloading. This does not limit concurrency where it
/// matters: once resident, every profile's sessions generate fully
/// concurrently against their own (possibly shared) models.
public actor Router {
    /// The recording root id; sortable by construction time.
    ///
    /// `nonisolated` because it is immutable and is read synchronously from
    /// outside the actor (vended handles, recorded events, tests).
    public nonisolated let id: ULID

    /// Bytes held out of the budget for OS/app headroom.
    let headroomReserve: Int64

    /// The in-flight fork-session ceiling per resolved profile (consumed for
    /// fork admission in milestone 9, "Session fork + per-model concurrency
    /// gates").
    let maxConcurrentForks: Int

    /// The disposable cache directory for host profiles and repo metadata.
    let cacheDir: URL

    /// The durable transcripts root, or `nil` when recording to memory/none.
    let recordingsDir: URL?

    /// The recorder every vended session and embed call is born holding — the
    /// base sink wrapped in a ``GatingRecorder`` when the level or `redact` hook
    /// would trim or transform what is recorded.
    let recorder: any TranscriptRecorder

    /// How much of a session's activity is recorded, enforced through ``recorder``.
    let recordingLevel: RecordingLevel

    /// An optional redaction hook applied to recorded text, enforced through ``recorder``.
    let redact: (@Sendable (String) -> String)?

    /// The machine probe behind the budget.
    private let probe: any MachineProbe

    /// The disposable host-profile cache.
    private let hostProfileCache: HostProfileCache

    /// The repo-metadata reader (fetch + parse + cache) behind sizing.
    private let metadataReader: RepoMetadataReader

    /// The download+load step behind resolution.
    private let loader: any ModelLoader

    /// Serializes every entry point that mutates ``pool`` — ``resolve(_:reporting:)``
    /// end to end *and* ``release(token:)`` — so the budget decision (effective-
    /// budget computation → joint fit → pool acquisition) a resolve makes is
    /// never invalidated by a concurrent mutation. This is the single
    /// authority the correctness requirement calls for: two concurrent
    /// resolves must never each independently price a candidate against the
    /// same "what's left" snapshot of the pool, and a release must never
    /// evict a key a resolve's already-committed pricing decision assumed
    /// was still free to reuse.
    ///
    /// The `release(token:)`-vs-`resolve(_:reporting:)` half of that is not
    /// optional: `resolve(_:reporting:)` prices an already-pooled candidate
    /// at zero marginal cost up front, then only actually re-acquires
    /// (refcount-bumps) it several `await`s later in its acquisition loop.
    /// Without this lock also guarding `release(token:)`, a concurrent
    /// release could evict that exact key in between — the later acquisition
    /// step would then find it gone, silently reload it, and permanently
    /// record it in the pool at the stale zero footprint the pricing
    /// decision had already committed to, eroding every future budget
    /// computation toward an eventual OOM.
    ///
    /// A deliberate simplification: mutation is single-flight even though
    /// resident profiles run fully concurrently once resolved (their
    /// sessions never touch this lock). A finer-grained scheme — reserving
    /// just-decided keys before releasing the lock so independent downloads
    /// could overlap — is not needed by anything this router promises today.
    private let poolLock = AsyncSemaphore(value: 1)

    /// The resident-model pool, keyed by exact artifact identity and
    /// reference-counted across every profile that references it. The
    /// authority ``resolve(_:reporting:)`` and ``release(token:)`` operate on.
    private var pool: [ResidencyKey: PoolEntry] = [:]

    /// Which pool keys each currently resident profile (by its residency
    /// token) holds a reference on — exactly three entries per profile
    /// (standard, flash, embedding), which may repeat if a profile's own
    /// slots share a key. ``release(token:)`` decrements exactly these on
    /// release, then forgets the token, making a double release or a stale
    /// `deinit` a safe no-op.
    private var residentProfiles: [ULID: [ResidencyKey]] = [:]

    /// Creates a router.
    ///
    /// - Parameters:
    ///   - id: The recording root id; pass one in to continue a prior recording
    ///     root. Defaults to a fresh ULID.
    ///   - headroomReserve: Bytes held out of the budget. Defaults to
    ///     ``defaultHeadroomReserveBytes`` (4 GB).
    ///   - maxConcurrentForks: In-flight fork sessions per profile. Defaults to
    ///     ``defaultMaxConcurrentForks``.
    ///   - cacheDir: The disposable cache directory. Defaults to the user caches
    ///     directory under `FoundationModelsRouter`.
    ///   - recordingsDir: The durable transcripts root, or `nil`.
    ///   - recorder: The recorder vended sessions are born holding. When `nil`,
    ///     a JSONL recorder under `recordingsDir` is used if one is set,
    ///     otherwise the no-op ``NoneRecorder``.
    ///   - recordingLevel: How much to record. Defaults to ``RecordingLevel/full``.
    ///   - redact: An optional redaction hook applied to recorded text.
    ///   - probe: The machine probe behind the budget. Defaults to ``SystemMachineProbe``.
    ///   - metadataSource: The metadata fetch behind sizing. Defaults to
    ///     ``HuggingFaceMetadataSource``.
    ///   - loader: The download+load step. Defaults to
    ///     ``UnconfiguredModelLoader`` — pass a configured ``LiveModelLoader``
    ///     (or, in tests, a stub) for real loading, since the live download path
    ///     requires an injected `Downloader`/`TokenizerLoader`.
    public init(
        id: ULID = .generate(),
        headroomReserve: Int64 = defaultHeadroomReserveBytes,
        maxConcurrentForks: Int = defaultMaxConcurrentForks,
        cacheDir: URL? = nil,
        recordingsDir: URL? = nil,
        recorder: (any TranscriptRecorder)? = nil,
        recordingLevel: RecordingLevel = .full,
        redact: (@Sendable (String) -> String)? = nil,
        probe: any MachineProbe = SystemMachineProbe(),
        metadataSource: any MetadataSource = HuggingFaceMetadataSource(),
        loader: any ModelLoader = UnconfiguredModelLoader()
    ) {
        self.id = id
        self.headroomReserve = headroomReserve
        self.maxConcurrentForks = maxConcurrentForks
        let resolvedCacheDir = cacheDir ?? Self.defaultCacheDir()
        self.cacheDir = resolvedCacheDir
        self.recordingsDir = recordingsDir
        let baseRecorder = recorder ?? Self.defaultRecorder(recordingsDir: recordingsDir)
        // Verbatim recording — `.full` with no `redact` hook — needs no gate, so
        // the base sink is threaded down directly; this keeps a session and embed
        // call *born holding the router's recorder itself* in the common case. Any
        // trimming (`.metadataOnly`, `.off`) or redaction wraps the base sink so
        // every event source honors it.
        if recordingLevel == .full, redact == nil {
            self.recorder = baseRecorder
        } else {
            self.recorder = GatingRecorder(level: recordingLevel, redact: redact, wrapping: baseRecorder)
        }
        self.recordingLevel = recordingLevel
        self.redact = redact
        self.probe = probe
        self.hostProfileCache = HostProfileCache(cacheDir: resolvedCacheDir)
        self.metadataReader = RepoMetadataReader(source: metadataSource, cacheDir: resolvedCacheDir)
        self.loader = loader
    }

    /// Resolves an authored profile into a resident ``LanguageModelProfile`` for
    /// this machine, reporting progress through `sizing → downloading → loading →
    /// ready` (or `failed`).
    ///
    /// Computes the *effective* budget — the machine budget less every
    /// currently pooled model's own footprint — sizes every candidate via repo
    /// metadata (candidates already pool-resident cost nothing marginal, see
    /// ``footprintBytes(for:context:metadataByRef:membership:residentKeys:)``),
    /// runs joint fit to pick the trio, then acquires each slot: reusing a
    /// pooled model when one already matches, or downloading, loading, and
    /// preloading a genuinely new one. On an unsatisfiable profile it sets the
    /// progress phase to ``ResolutionProgress/Phase/failed(_:)`` and throws
    /// ``ResolutionFailure`` carrying the per-slot diagnostics — including the
    /// case where the profile's union with what's already resident would
    /// exceed the budget and nothing resident is evictable (every currently
    /// pooled model is still referenced by a live profile).
    ///
    /// Single-flight: the whole pipeline (through the final pool acquisition)
    /// is serialized against any other in-flight ``resolve(_:reporting:)`` on
    /// this router, so the budget decision is always made against a
    /// consistent snapshot of the pool.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive (mutated on the main actor).
    /// - Returns: The resolved, resident profile.
    /// - Throws: ``ResolutionFailure`` when no trio co-fits the effective
    ///   budget, or any download/load error from the ``ModelLoader``.
    public func resolve(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress
    ) async throws -> LanguageModelProfile {
        await poolLock.wait()
        defer { poolLock.signal() }

        await beginSizing(progress: progress)
        let totalBudget = hostBudget()
        let residentFootprint = pool.values.reduce(Int64(0)) { $0 + $1.footprintBytes }
        let effectiveBudget = totalBudget - residentFootprint
        let metadataByRef = await sizeCandidates(profile: def)
        let residentKeys = Set(pool.keys)

        let resolution = try await runJointFit(
            profile: def,
            budget: effectiveBudget,
            metadataByRef: metadataByRef,
            residentKeys: residentKeys,
            progress: progress
        )
        await markChosen(resolution: resolution, progress: progress)

        // Populated incrementally as each slot is acquired, so a mid-pipeline
        // failure's `catch` below can see exactly what this attempt already
        // holds and roll it back — whether that slot was freshly loaded or
        // reused (bumped) an already-resident entry.
        var slotKeys: [ModelSlot: ResidencyKey] = [:]
        var newKeys: Set<ResidencyKey> = []
        do {
            await setPhase(.downloading, progress: progress)
            // Both generation slots acquire identically — only the chosen ref,
            // slot, and context differ — so they run through one loop over the
            // (ref, slot) pairs in standard-before-flash order. The embedding
            // slot uses a different loader call (no `context`) and stays
            // separate.
            for (chosen, slot) in [
                (resolution.standard, ModelSlot.standard), (resolution.flash, ModelSlot.flash),
            ] {
                let slotRes = Self.slotResolution(for: resolution, slot: slot)
                let key = try await acquireLLM(
                    key: ResidencyKey(ref: chosen, role: .llm(context: slotRes.contextTokens)),
                    chosen: chosen,
                    slot: slot,
                    context: slotRes.contextTokens,
                    footprintBytes: Self.chosenFootprint(for: slotRes),
                    newKeys: &newKeys,
                    progress: progress
                )
                slotKeys[slot] = key
            }

            let embeddingRes = Self.slotResolution(for: resolution, slot: .embedding)
            let embeddingKey = try await acquireEmbedder(
                key: ResidencyKey(ref: resolution.embedding, role: .embedding),
                chosen: resolution.embedding,
                footprintBytes: Self.chosenFootprint(for: embeddingRes),
                newKeys: &newKeys,
                progress: progress
            )
            slotKeys[.embedding] = embeddingKey

            await setPhase(.loading, progress: progress)
            // Only the freshly-acquired keys need preloading — a reused key
            // was already preloaded the resolve that first loaded it — and
            // each distinct key is preloaded at most once even if two slots
            // in this same resolve share it (e.g. `standard` and `flash`
            // both winning the identical ref+context).
            var preloadedKeys: Set<ResidencyKey> = []
            for slot in [ModelSlot.standard, .flash, .embedding] {
                guard let key = slotKeys[slot], newKeys.contains(key) else { continue }
                guard let entry = pool[key] else {
                    preconditionFailure("a freshly-acquired key must still be in the pool")
                }
                if preloadedKeys.contains(key) {
                    await setSlotState(slot, to: .ready, progress: progress)
                    continue
                }
                try await finalize(slot: slot, container: entry.container.erased, progress: progress)
                preloadedKeys.insert(key)
            }

            await complete(progress: progress)
            guard let standardKey = slotKeys[.standard], let flashKey = slotKeys[.flash],
                  let embeddingKey = slotKeys[.embedding]
            else {
                preconditionFailure("the acquisition loop above populates all three slot keys")
            }
            let residencyToken = ULID.generate()
            let profile = buildProfile(
                definition: def,
                resolution: resolution,
                standardKey: standardKey,
                flashKey: flashKey,
                embeddingKey: embeddingKey,
                residencyToken: residencyToken
            )
            residentProfiles[residencyToken] = Array(slotKeys.values)
            return profile
        } catch {
            // Give back everything this attempt already acquired — a fresh
            // load is fully evicted, a reused entry's refcount bump is
            // undone — so a partial failure never leaks a phantom-resident
            // pool entry with no owning profile.
            for key in slotKeys.values {
                await releaseKey(key: key)
            }
            // A download/load/preload failure must move the bound progress to
            // `.failed` so a UI does not hang mid-pipeline, then rethrow.
            await recordLoadFailure(error: error, progress: progress)
            throw error
        }
    }

    // MARK: - Residency

    /// Acquires the pooled model identified by `key`: reuses an
    /// already-pooled entry (bumping its refcount) or downloads through
    /// `load` and inserts a fresh pool entry with newly-minted gates when
    /// none exists yet.
    ///
    /// Shared by ``acquireLLM(key:chosen:slot:context:footprintBytes:newKeys:progress:)``
    /// and ``acquireEmbedder(key:chosen:footprintBytes:newKeys:progress:)``:
    /// the generation and embedding slots acquire identically except for the
    /// loader call and the concrete container type, which `load` and `wrap`
    /// supply.
    ///
    /// - Parameters:
    ///   - key: This candidate's exact residency identity.
    ///   - chosen: The chosen model reference.
    ///   - slot: The slot being acquired.
    ///   - footprintBytes: This slot's `× 1.2` footprint, recorded on a fresh
    ///     pool entry as its steady-state cost.
    ///   - newKeys: Accumulates `key` when this call inserted a fresh entry,
    ///     so the caller knows which acquired keys still need preloading.
    ///   - progress: The progress to drive through acquisition.
    ///   - load: The loader call producing a fresh resident container.
    ///   - wrap: Wraps a freshly-loaded container into the type-erased
    ///     ``PooledContainer`` stored on the pool entry.
    /// - Returns: `key`, for the caller's own bookkeeping.
    /// - Throws: Any error the loader raises downloading a fresh container.
    private func acquireModel<Loaded>(
        key: ResidencyKey,
        chosen: ModelRef,
        slot: ModelSlot,
        footprintBytes: Int64,
        newKeys: inout Set<ResidencyKey>,
        progress: ResolutionProgress,
        load: (ModelRef, ModelSlot, @escaping @Sendable (DownloadProgress) -> Void) async throws ->
            Loaded,
        wrap: (Loaded) -> PooledContainer
    ) async throws -> ResidencyKey {
        if var entry = pool[key] {
            entry.refcount += 1
            pool[key] = entry
            await setSlotState(slot, to: .ready, progress: progress)
            return key
        }
        let container = try await download(ref: chosen, slot: slot, progress: progress, load: load)
        pool[key] = PoolEntry(
            refcount: 1,
            footprintBytes: footprintBytes,
            container: wrap(container),
            generationGate: AsyncSemaphore(value: 1),
            forkAdmissionGate: AsyncSemaphore(value: maxConcurrentForks)
        )
        newKeys.insert(key)
        return key
    }

    /// Acquires the generation slot for `key` from its pooled entry.
    ///
    /// The `.standard` and `.flash` slots acquire identically, differing
    /// only by slot and context, so both go through
    /// ``acquireModel(key:chosen:slot:footprintBytes:newKeys:progress:load:wrap:)``.
    ///
    /// - Parameters:
    ///   - key: This candidate's exact residency identity.
    ///   - chosen: The chosen model reference.
    ///   - slot: The slot being acquired (`.standard`/`.flash`).
    ///   - context: The working context to load a fresh container at.
    ///   - footprintBytes: This slot's `× 1.2` footprint, recorded on a fresh
    ///     pool entry as its steady-state cost.
    ///   - newKeys: Accumulates `key` when this call inserted a fresh entry,
    ///     so the caller knows which acquired keys still need preloading.
    ///   - progress: The progress to drive through acquisition.
    /// - Returns: `key`, for the caller's own bookkeeping.
    /// - Throws: Any error the loader raises downloading a fresh container.
    private func acquireLLM(
        key: ResidencyKey,
        chosen: ModelRef,
        slot: ModelSlot,
        context: Int,
        footprintBytes: Int64,
        newKeys: inout Set<ResidencyKey>,
        progress: ResolutionProgress
    ) async throws -> ResidencyKey {
        try await acquireModel(
            key: key, chosen: chosen, slot: slot, footprintBytes: footprintBytes,
            newKeys: &newKeys, progress: progress,
            load: { try await loader.loadLLM(ref: $0, slot: $1, context: context, reporting: $2) },
            wrap: { .llm($0) }
        )
    }

    /// Acquires the embedding slot for `key` from its pooled entry — the
    /// ``acquireLLM(key:chosen:slot:context:footprintBytes:newKeys:progress:)``
    /// counterpart for the embedding role, which has no context axis and a
    /// different loader call.
    private func acquireEmbedder(
        key: ResidencyKey,
        chosen: ModelRef,
        footprintBytes: Int64,
        newKeys: inout Set<ResidencyKey>,
        progress: ResolutionProgress
    ) async throws -> ResidencyKey {
        try await acquireModel(
            key: key, chosen: chosen, slot: .embedding, footprintBytes: footprintBytes,
            newKeys: &newKeys, progress: progress,
            load: { try await loader.loadEmbedder(ref: $0, slot: $1, reporting: $2) },
            wrap: { .embedding($0) }
        )
    }

    /// Decrements the resident-model references a profile identified by
    /// `token` was granted at resolve time, evicting through the loader only
    /// whichever pooled models drop to zero references as a result — a model
    /// another still-live profile also references stays resident.
    ///
    /// Called by ``LanguageModelProfile/release()`` (and its `deinit`), and
    /// by ``resolve(_:reporting:)`` itself to roll back a failed attempt.
    /// Idempotent and safe against staleness: `token` is looked up (and
    /// removed) from ``residentProfiles``, so a double release — or a
    /// `deinit` firing after an explicit release — finds nothing and is a
    /// no-op, and can never clobber a different, still-live profile's
    /// references. Because the token is never reused (unlike an
    /// address-derived `ObjectIdentifier`), a freed profile's `deinit` can
    /// never collide with a later profile's token.
    ///
    /// Also serialized by ``poolLock`` against any in-flight
    /// ``resolve(_:reporting:)`` — see that property's doc comment for why
    /// this is not optional: without it, this could evict a key a
    /// concurrent resolve's already-committed pricing decision assumed was
    /// still free to reuse.
    ///
    /// - Parameter token: The residency token of the profile asking to be released.
    func release(token: ULID) async {
        await poolLock.wait()
        defer { poolLock.signal() }
        guard let keys = residentProfiles.removeValue(forKey: token) else { return }
        for key in keys {
            await releaseKey(key: key)
        }
    }

    /// Decrements one pooled model's refcount by one, evicting it through the
    /// loader once it reaches zero. A no-op if `key` is not currently pooled.
    private func releaseKey(key: ResidencyKey) async {
        guard var entry = pool[key] else { return }
        entry.refcount -= 1
        if entry.refcount <= 0 {
            pool.removeValue(forKey: key)
            await loader.evict(container: entry.container.erased)
        } else {
            pool[key] = entry
        }
    }

    // MARK: - Budget

    /// The RAM budget for this machine, measuring and caching the host profile.
    private func hostBudget() -> Int64 {
        let chip = probe.chip
        let ram = probe.totalRAM
        let profile: HostProfile
        if let cached = try? hostProfileCache.load(chip: chip, totalRAM: ram) {
            profile = cached
        } else {
            profile = HostProfile(probe: probe)
            try? hostProfileCache.save(profile)
        }
        return profile.budget(headroomReserve: headroomReserve)
    }

    // MARK: - Sizing

    /// Fetches every candidate's parsed metadata once per `(slot, ref)`
    /// occurrence, merging results for a ref shared across slots (see
    /// ``preferSuccess(left:right:)``).
    ///
    /// Metadata — not a footprint baked in at one fixed context — is what's
    /// cached here: ``JointFit``'s context ladder queries footprint and
    /// native-max-context at however many different context rungs it needs
    /// while deriving the working context, all purely sync from the metadata
    /// already in hand (see ``footprintBytes(for:context:metadataByRef:membership:residentKeys:)``),
    /// no further I/O once this returns.
    private func sizeCandidates(
        profile def: ProfileDefinition
    ) async -> [ModelRef: Result<RepoMetadata, RepoMetadataError>] {
        var out: [ModelRef: Result<RepoMetadata, RepoMetadataError>] = [:]
        for (_, refs) in def.candidatesBySlot {
            for ref in refs {
                let result = await metadataResult(for: ref)
                if let existing = out[ref] {
                    out[ref] = Self.preferSuccess(left: existing, right: result)
                } else {
                    out[ref] = result
                }
            }
        }
        return out
    }

    /// Fetches and parses one candidate's metadata, passing a thrown
    /// ``RepoMetadataError`` through unchanged and wrapping any other thrown
    /// error into ``RepoMetadataError/metadataUnavailable(_:)``.
    private func metadataResult(for ref: ModelRef) async -> Result<RepoMetadata, RepoMetadataError> {
        do {
            return .success(try await metadataReader.metadata(for: ref))
        } catch let error as RepoMetadataError {
            return .failure(error)
        } catch {
            return .failure(.metadataUnavailable(error.localizedDescription))
        }
    }

    /// Merges two metadata results for the same ref fetched via different
    /// slot memberships, keeping the first successful result — or, when both
    /// failed, the first (chronologically earliest) failure — so a transient
    /// failure fetching one slot's occurrence never poisons a later slot's
    /// successful one.
    private static func preferSuccess(
        left lhs: Result<RepoMetadata, RepoMetadataError>,
        right rhs: Result<RepoMetadata, RepoMetadataError>
    ) -> Result<RepoMetadata, RepoMetadataError> {
        switch (lhs, rhs) {
        case (.success, _):
            return lhs
        case (.failure, .success):
            return rhs
        case (.failure, .failure):
            return lhs
        }
    }

    /// Every slot a ref is a candidate for, across the whole profile.
    ///
    /// A ref shared across slots (e.g. one small model listed as both an
    /// embedding and a standard candidate) must be sized under *every*
    /// interpretation it could be used under — see
    /// ``footprintBytes(for:context:metadataByRef:membership:residentKeys:)``.
    private static func slotMembership(profile def: ProfileDefinition) -> [ModelRef: Set<ModelSlot>] {
        var membership: [ModelRef: Set<ModelSlot>] = [:]
        for (slot, refs) in def.candidatesBySlot {
            for ref in refs {
                membership[ref, default: []].insert(slot)
            }
        }
        return membership
    }

    /// The shared "no metadata fetched for this candidate" diagnostic, used
    /// everywhere ``sizeCandidates(profile:)`` came up empty for a `ref` that
    /// ``footprintBytes(for:context:metadataByRef:membership:residentKeys:)``
    /// or ``runJointFit(profile:budget:metadataByRef:residentKeys:progress:)``'s
    /// `nativeMaxContext` closure needs sized — kept in one place so both
    /// sites can't drift out of wording sync.
    private static func unsizedCandidateMessage(for ref: ModelRef) -> String {
        "candidate \(ref.stringValue) was not sized"
    }

    /// The raw footprint bytes for one candidate at a context, conservatively
    /// sized across every slot it is a candidate for: the embedding
    /// interpretation has no KV cache (weights alone), while standard/flash
    /// do — a ref that is a candidate for both is sized under both and the
    /// larger figure is kept, so neither slot's fit test under-estimates it.
    ///
    /// Pool-aware: for each interpretation, the figure charged against the
    /// budget is `0` when that exact ``ResidencyKey`` is already resident
    /// (`residentKeys`) — reusing an already-loaded model costs nothing
    /// marginal — and the real raw footprint otherwise. This is what makes an
    /// already-resident candidate "free" to reuse in a later profile's joint
    /// fit while a genuinely new candidate is still charged its real cost
    /// against whatever budget remains.
    private static func footprintBytes(
        for ref: ModelRef,
        context: Int,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        membership: [ModelRef: Set<ModelSlot>],
        residentKeys: Set<ResidencyKey>
    ) -> Result<Int64, RepoMetadataError> {
        guard let metadataResult = metadataByRef[ref] else {
            return .failure(.metadataUnavailable(Self.unsizedCandidateMessage(for: ref)))
        }
        switch metadataResult {
        case .failure(let error):
            return .failure(error)
        case .success(let metadata):
            let slots = membership[ref] ?? []
            var candidates: [Int64] = []
            if slots.contains(.embedding) {
                let key = ResidencyKey(ref: ref, role: .embedding)
                let raw = Footprint.embedder(weightBytes: metadata.weightBytes).footprint(context: context)
                candidates.append(residentKeys.contains(key) ? 0 : raw)
            }
            if slots.contains(.standard) || slots.contains(.flash) {
                let key = ResidencyKey(ref: ref, role: .llm(context: context))
                let raw = metadata.footprint.footprint(context: context)
                candidates.append(residentKeys.contains(key) ? 0 : raw)
            }
            // Total by construction: every ref in `metadataByRef` came from
            // `def.candidatesBySlot`, so `membership[ref]` always has at
            // least one slot, and thus at least one interpretation above.
            guard let largest = candidates.max() else {
                preconditionFailure("a sized candidate is a member of at least one slot")
            }
            return .success(largest)
        }
    }

    // MARK: - Joint fit

    /// Runs the pure joint fit and, on failure, records the diagnostics into the
    /// progress before rethrowing.
    private func runJointFit(
        profile def: ProfileDefinition,
        budget: Int64,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        residentKeys: Set<ResidencyKey>,
        progress: ResolutionProgress
    ) async throws -> JointResolution {
        let membership = Self.slotMembership(profile: def)
        do {
            return try JointFit.resolve(
                profile: def,
                budgetBytes: budget,
                footprint: { ref, context in
                    Self.footprintBytes(
                        for: ref, context: context, metadataByRef: metadataByRef,
                        membership: membership, residentKeys: residentKeys
                    )
                },
                nativeMaxContext: { ref in
                    (metadataByRef[ref]
                        ?? .failure(.metadataUnavailable(Self.unsizedCandidateMessage(for: ref))))
                        .map(\.nativeMaxContext)
                }
            )
        } catch let failure as ResolutionFailure {
            await recordFailure(failure: failure, progress: progress)
            throw failure
        }
    }

    // MARK: - Download & load

    /// Downloads and loads the chosen model for a slot through the given loader
    /// call: marks the slot downloading, then hands the ref, slot, and
    /// byte-progress reporter to `load`.
    ///
    /// The container type `C` is inferred from the loader call at each site —
    /// ``LoadedLLMContainer`` for the generation slots, ``LoadedEmbeddingContainer``
    /// for the embedding slot — so the generation and embedding load paths share
    /// one body and differ only in the closure passed in.
    ///
    /// - Parameters:
    ///   - chosen: The chosen model reference.
    ///   - slot: The slot the model is being loaded for.
    ///   - progress: The progress to mark downloading before loading.
    ///   - load: The loader call producing the resident container, invoked with
    ///     the ref, slot, and a best-effort download-progress reporter.
    /// - Returns: The resident container produced by `load`.
    /// - Throws: Any error thrown by `load`.
    private func download<C>(
        ref chosen: ModelRef,
        slot: ModelSlot,
        progress: ResolutionProgress,
        load: (ModelRef, ModelSlot, @escaping @Sendable (DownloadProgress) -> Void) async throws -> C
    ) async throws -> C {
        await setSlotState(slot, to: .downloading, progress: progress)
        let reporting = Self.reporter(slot: slot, progress: progress)
        return try await load(chosen, slot, reporting)
    }

    /// Preloads a downloaded container and marks its slot ready.
    private func finalize(
        slot: ModelSlot,
        container: any LoadedModelContainer,
        progress: ResolutionProgress
    ) async throws {
        await setSlotState(slot, to: .loading, progress: progress)
        try await loader.preload(container: container)
        await setSlotState(slot, to: .ready, progress: progress)
    }

    /// A best-effort, monotonic download-progress callback that updates a slot's
    /// byte counts on the main actor.
    ///
    /// Each tick applies its update in its own `Task { @MainActor }`, so ticks
    /// are unordered with respect to one another *and* to the awaited phase
    /// transitions. Two guards keep the surfaced progress trustworthy for the
    /// multi-GB downloads a UI bar tracks:
    ///
    /// - **State guard**: the update only applies while the slot is still
    ///   ``SlotProgress/State/downloading``, so a late callback never clobbers a
    ///   slot the orchestration has already moved to loading, ready, or failed.
    /// - **Monotonicity**: `bytesDownloaded` only ever advances
    ///   (`max(current, tick)`), so an out-of-order tick that arrives with a
    ///   smaller count cannot flick the bar backward; and a known
    ///   `bytesTotal` is adopted only when the tick actually reports one
    ///   (`> 0`), so a later tick that has not yet learned the total (`0`)
    ///   cannot erase it.
    ///
    /// - Parameters:
    ///   - slot: The slot whose byte counts this callback advances.
    ///   - progress: The UI-bindable progress whose slot is mutated (on the main
    ///     actor) and refreshed on each tick.
    /// - Returns: A `@Sendable` closure that applies one ``DownloadProgress`` tick
    ///   to the slot — monotonically, and only while it is still downloading.
    static func reporter(
        slot: ModelSlot,
        progress: ResolutionProgress
    ) -> @Sendable (DownloadProgress) -> Void {
        { dp in
            Task { @MainActor in
                guard var sp = progress.slots[slot], sp.state == .downloading else { return }
                sp.bytesDownloaded = max(sp.bytesDownloaded, dp.bytesDownloaded)
                if dp.bytesTotal > 0 {
                    sp.bytesTotal = dp.bytesTotal
                }
                progress.slots[slot] = sp
                progress.refreshFraction()
            }
        }
    }

    // MARK: - Profile assembly

    /// Assembles the resolved profile from the pool's loaded containers and the
    /// per-slot resolutions, stamping each handle with the router's id and recorder.
    private func buildProfile(
        definition def: ProfileDefinition,
        resolution: JointResolution,
        standardKey: ResidencyKey,
        flashKey: ResidencyKey,
        embeddingKey: ResidencyKey,
        residencyToken: ULID
    ) -> LanguageModelProfile {
        let embeddingRes = Self.slotResolution(for: resolution, slot: .embedding)
        let resolvedProfile = SessionSidecar.ResolvedProfile(
            definitionName: def.name,
            standard: resolution.standard,
            flash: resolution.flash,
            embedding: resolution.embedding,
            context: Self.slotResolution(for: resolution, slot: .standard).contextTokens
        )
        return LanguageModelProfile(
            definitionName: def.name,
            standard: makeRoutedLLM(
                slot: .standard,
                chosen: resolution.standard,
                resolution: Self.slotResolution(for: resolution, slot: .standard),
                key: standardKey,
                resolvedProfile: resolvedProfile
            ),
            flash: makeRoutedLLM(
                slot: .flash,
                chosen: resolution.flash,
                resolution: Self.slotResolution(for: resolution, slot: .flash),
                key: flashKey,
                resolvedProfile: resolvedProfile
            ),
            embedding: makeRoutedEmbedder(
                chosen: resolution.embedding,
                resolution: embeddingRes,
                key: embeddingKey,
                resolvedProfile: resolvedProfile
            ),
            router: self,
            residencyToken: residencyToken
        )
    }

    /// Builds a routed model handle for `slot` from its pooled entry,
    /// stamping it with this router's id, recorder, and transcripts root, and
    /// reusing the pool entry's own generation/fork-admission gates.
    ///
    /// Shared by ``makeRoutedLLM(slot:chosen:resolution:key:resolvedProfile:)``
    /// and ``makeRoutedEmbedder(chosen:resolution:key:resolvedProfile:)``:
    /// the `.standard`/`.flash` generation handles and the embedding handle
    /// are built identically except for the concrete container type they
    /// unwrap from the pool entry's type-erased ``PooledContainer``, which
    /// `unwrap` supplies. `maxConcurrentForks` is passed uniformly even
    /// though the embedding handle never forks — it is unused whenever
    /// `forkAdmissionGate` is supplied, as it always is here.
    ///
    /// - Parameters:
    ///   - slot: The slot this handle fills.
    ///   - chosen: The chosen model reference for the slot.
    ///   - resolution: Why this model won its slot.
    ///   - key: This slot's exact residency identity, looked up in ``pool``
    ///     for its container and gates.
    ///   - resolvedProfile: The run's resolved-profile facts, recorded onto
    ///     the sidecar of every root session vended from this handle.
    ///   - unwrap: Extracts this handle's concrete container type from the
    ///     pooled entry's ``PooledContainer``, or `nil` if the entry holds
    ///     the other container kind.
    /// - Returns: The routed model handle.
    private func makeRoutedModel<Container: Sendable>(
        slot: ModelSlot,
        chosen: ModelRef,
        resolution: SlotResolution,
        key: ResidencyKey,
        resolvedProfile: SessionSidecar.ResolvedProfile,
        unwrap: (PooledContainer) -> Container?
    ) -> RoutedModel<Container> {
        guard let entry = pool[key], let container = unwrap(entry.container) else {
            preconditionFailure(
                "a ResidencyKey acquired this resolve must have a matching pool entry for \(slot)"
            )
        }
        return RoutedModel(
            slot: slot,
            chosen: chosen,
            footprintBytes: Self.chosenFootprint(for: resolution),
            resolution: resolution,
            container: container,
            routerId: id,
            recorder: recorder,
            durableRecording: makeDurableRecording(
                slot: slot,
                chosen: chosen,
                resolution: resolution,
                resolvedProfile: resolvedProfile
            ),
            maxConcurrentForks: maxConcurrentForks,
            generationGate: entry.generationGate,
            forkAdmissionGate: entry.forkAdmissionGate
        )
    }

    /// Builds a generation handle for a slot from its pooled entry.
    ///
    /// The `.standard` and `.flash` slots construct identical ``RoutedLLM``
    /// handles differing only by slot, chosen ref, resolution, and pool key,
    /// so both go through ``makeRoutedModel(slot:chosen:resolution:key:resolvedProfile:unwrap:)``.
    private func makeRoutedLLM(
        slot: ModelSlot,
        chosen: ModelRef,
        resolution: SlotResolution,
        key: ResidencyKey,
        resolvedProfile: SessionSidecar.ResolvedProfile
    ) -> RoutedLLM {
        makeRoutedModel(
            slot: slot, chosen: chosen, resolution: resolution, key: key,
            resolvedProfile: resolvedProfile
        ) { container in
            guard case .llm(let llm) = container else { return nil }
            return llm
        }
    }

    /// Builds the embedding handle from its pooled entry — the
    /// ``makeRoutedLLM(slot:chosen:resolution:key:resolvedProfile:)``
    /// counterpart for the embedding role.
    ///
    /// The embedding handle never vends a session, so its writer is never
    /// reached — it is carried anyway because a durable root and its writer
    /// are one value, which is what keeps the generation handles from being
    /// handed a root with no writer.
    private func makeRoutedEmbedder(
        chosen: ModelRef,
        resolution: SlotResolution,
        key: ResidencyKey,
        resolvedProfile: SessionSidecar.ResolvedProfile
    ) -> RoutedEmbedder {
        makeRoutedModel(
            slot: .embedding, chosen: chosen, resolution: resolution, key: key,
            resolvedProfile: resolvedProfile
        ) { container in
            guard case .embedding(let embedder) = container else { return nil }
            return embedder
        }
    }

    /// Pairs this run's durable transcripts root with the sidecar writer
    /// sessions vended from one handle record their `session.json` through, or
    /// `nil` when this run has nowhere durable to record.
    ///
    /// Gated purely on "is there somewhere durable to write". The recording
    /// level is not a gate here — it is the returned writer's own business, so
    /// a root is never handed out without the writer that keeps what lands
    /// under it loadable (see ``DurableRecording``).
    ///
    /// - Parameters:
    ///   - slot: The slot the handle fills.
    ///   - chosen: The concrete model resident in that slot.
    ///   - resolution: Why that model won its slot, for the context it was
    ///     resolved at.
    ///   - resolvedProfile: The run's resolved-profile facts, recorded onto
    ///     root sessions.
    /// - Returns: The root and its writer, or `nil` when nothing is recorded
    ///   durably.
    private func makeDurableRecording(
        slot: ModelSlot,
        chosen: ModelRef,
        resolution: SlotResolution,
        resolvedProfile: SessionSidecar.ResolvedProfile
    ) -> DurableRecording? {
        guard let recordingsDir else { return nil }
        return DurableRecording(
            root: recordingsDir,
            sidecarWriter: SessionSidecarWriter(
                slot: slot,
                model: chosen,
                context: resolution.contextTokens,
                recordingLevel: recordingLevel,
                profile: resolvedProfile,
                routerId: id
            )
        )
    }

    // MARK: - Resolution lookups

    /// The ``SlotResolution`` for a slot in a joint resolution.
    ///
    /// Total by construction: a ``JointResolution`` only exists on the success
    /// path, where ``JointFit`` always records a resolution for every slot in
    /// allocation order — a missing slot is a broken invariant, not a runtime
    /// condition, so it traps rather than returning an optional the callers would
    /// have to unwrap.
    private static func slotResolution(for resolution: JointResolution, slot: ModelSlot)
        -> SlotResolution
    {
        guard let slotRes = resolution.slots.first(where: { $0.slot == slot }) else {
            preconditionFailure("JointResolution records a resolution for every slot; missing \(slot)")
        }
        return slotRes
    }

    /// The chosen candidate's `× 1.2` footprint estimate for a slot, or `0` when
    /// unrecorded.
    private static func chosenFootprint(for slotRes: SlotResolution) -> Int64 {
        slotRes.considered.first { $0.verdict == .chosen }?.estimatedFootprintBytes ?? 0
    }

    // MARK: - Progress mutations (main actor)

    /// Enters the sizing phase with all slots sizing.
    private func beginSizing(progress: ResolutionProgress) async {
        await MainActor.run {
            progress.phase = .sizing
            progress.slots = [
                .standard: SlotProgress(state: .sizing),
                .flash: SlotProgress(state: .sizing),
                .embedding: SlotProgress(state: .sizing),
            ]
            progress.refreshFraction()
        }
    }

    /// Records the chosen candidate per slot, resetting each to pending for the
    /// download phase.
    private func markChosen(resolution: JointResolution, progress: ResolutionProgress) async {
        await MainActor.run {
            for slotRes in resolution.slots {
                var sp = progress.slots[slotRes.slot] ?? SlotProgress()
                sp.chosen = slotRes.chosen
                sp.state = .pending
                progress.slots[slotRes.slot] = sp
            }
            progress.refreshFraction()
        }
    }

    /// Sets the overall phase.
    private func setPhase(_ phase: ResolutionProgress.Phase, progress: ResolutionProgress) async {
        await MainActor.run { progress.phase = phase }
    }

    /// Sets a single slot's state and refreshes the overall fraction.
    private func setSlotState(
        _ slot: ModelSlot,
        to state: SlotProgress.State,
        progress: ResolutionProgress
    ) async {
        await MainActor.run {
            var sp = progress.slots[slot] ?? SlotProgress()
            sp.state = state
            progress.slots[slot] = sp
            progress.refreshFraction()
        }
    }

    /// Marks the resolution complete: every slot ready, the bar full.
    private func complete(progress: ResolutionProgress) async {
        await MainActor.run {
            for (slot, var sp) in progress.slots {
                sp.state = .ready
                progress.slots[slot] = sp
            }
            progress.phase = .ready
            progress.refreshFraction()
            progress.fraction = 1.0
        }
    }

    /// Records a joint-fit failure into the progress: the unsatisfiable slots are
    /// marked failed and the phase carries the diagnostic description.
    private func recordFailure(failure: ResolutionFailure, progress: ResolutionProgress) async {
        await MainActor.run {
            for slotRes in failure.slots {
                var sp = progress.slots[slotRes.slot] ?? SlotProgress()
                sp.chosen = slotRes.chosen
                sp.state = slotRes.chosen == nil
                    ? .failed("no candidate fit the remaining budget")
                    : .sizing
                progress.slots[slotRes.slot] = sp
            }
            progress.phase = .failed(failure.description)
            progress.refreshFraction()
        }
    }

    /// Records a download/load/preload failure into the progress: every slot not
    /// already resident is marked failed and the phase carries the error text.
    private func recordLoadFailure(error: Error, progress: ResolutionProgress) async {
        let message = String(describing: error)
        await MainActor.run {
            for (slot, var sp) in progress.slots where sp.state != .ready {
                sp.state = .failed(message)
                progress.slots[slot] = sp
            }
            progress.phase = .failed(message)
            progress.refreshFraction()
        }
    }

    // MARK: - Defaults

    /// The default disposable cache directory under the user caches directory.
    private static func defaultCacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(moduleName, isDirectory: true)
    }

    /// The default recorder: JSONL under `recordingsDir` when set, else the no-op sink.
    private static func defaultRecorder(recordingsDir: URL?) -> any TranscriptRecorder {
        if let recordingsDir {
            return JSONLRecorder(directory: recordingsDir)
        }
        return NoneRecorder()
    }
}
