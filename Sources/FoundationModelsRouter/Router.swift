import Foundation
import Tracing

/// The default in-flight fork-session ceiling per resolved profile. It is
/// `public` because a `public` initializer uses it as a default argument.
public let defaultMaxConcurrentForks = 4

/// The default headroom reserved out of the machine budget for OS and app use.
public let defaultHeadroomReserveBytes: Int64 = 4 << 30

/// Whether a session's activity is recorded: `off` or `full`.
public enum RecordingLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Record nothing.
    case off
    /// Record everything, including prompt and response text.
    case full
}

/// The exact identity of a resident model artifact.
///
/// Two candidates share a pool entry only when both the ``ModelRef`` and the
/// ``Role`` match. A generation model is keyed by its working context because
/// the KV cache is sized at load time.
private struct ResidencyKey: Hashable, Sendable {
    /// The role a resident model was loaded under.
    enum Role: Hashable, Sendable {
        /// Loaded as a generation model at this working context.
        case llm(context: Int)
        /// Loaded as an embedder — context-independent (weights only).
        case embedding
    }

    /// The model reference (repo + optional pinned revision).
    // Never read by name: both stored properties are consumed only through the
    // synthesized `Hashable`/`Equatable` conformance, which is exactly what
    // makes this a pool key. Deleting either would collapse every distinct
    // model (or role) onto one bucket of `pool`.
    // periphery:ignore
    let ref: ModelRef

    /// The role this instance was loaded under.
    // periphery:ignore
    let role: Role
}

/// A pool entry's loaded container, by container protocol.
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

/// One resident model in the router's pool, reference-counted across every
/// slot acquisition that holds it. Every ``RoutedModel`` built over this
/// entry shares its ``ResidentModelGates``.
private struct PoolEntry: Sendable {
    /// How many slot acquisitions currently hold this model.
    var refcount: Int

    /// This model's margined footprint at first load, the floor under ``footprintBytes``.
    let baseFootprintBytes: Int64

    /// The sum of the bytes every live acquisition charged the shared budget.
    /// Each release gives back its own acquisition's charge.
    var acquiredChargeBytes: Int64

    /// The steady-state bytes this entry holds against the shared budget:
    /// the live charge, floored at the first load's own footprint.
    var footprintBytes: Int64 { max(baseFootprintBytes, acquiredChargeBytes) }

    /// The loaded container.
    let container: PooledContainer

    /// The gates every handle built over this entry reuses.
    let gates: ResidentModelGates
}

/// One slot acquisition's hold on a pooled model: the pool key and the bytes
/// that acquisition charged the shared budget. A release gives back the
/// charge.
private struct ResidencyHold: Sendable {
    /// The pooled model this hold references.
    let key: ResidencyKey

    /// The `× 1.2` bytes this acquisition charged the shared budget.
    let chargedBytes: Int64
}

/// The shared entry point: built once at app start, it resolves authored
/// ``ProfileDefinition``s into resident ``LanguageModelProfile``s for this
/// machine, reporting UI-bindable progress.
///
/// The router holds the repo-metadata cache and the injected seams: a
/// ``MachineProbe`` for the budget, a ``MetadataSource`` for sizing, and a
/// ``ModelLoader`` for the download and load. The host itself is probed on
/// each resolve, so no host measurement is kept.
///
/// A router admits several resident profiles at one time. It prices the
/// union of every resident model against one shared budget. Residency is
/// reference-counted per ``ResidencyKey`` across every profile that
/// references it. ``resolve(profile:reporting:)`` and ``release(token:)``
/// are serialized by `poolLock`.
public actor Router {
    /// The recording root id; sortable by construction time.
    public nonisolated let id: ULID

    /// Bytes held out of the budget for OS/app headroom.
    let headroomReserve: Int64

    /// The in-flight fork-session ceiling per resolved profile.
    let maxConcurrentForks: Int

    /// The durable transcripts root, or `nil` when recording to memory/none.
    let recordingsDir: URL?

    /// The recorder every vended session and embed call holds: the base sink,
    /// wrapped in a ``GatingRecorder`` when the level or `redact` hook applies.
    let recorder: any TranscriptRecorder

    /// How much of a session's activity is recorded, enforced through ``recorder``.
    let recordingLevel: RecordingLevel

    /// The tracer every vended handle opens its embed span through, or `nil`
    /// to read `InstrumentationSystem.tracer` at call time. See
    /// ``RoutedModel/tracer``.
    let tracer: (any Tracer)?

    /// The machine probe behind the budget.
    private let probe: any MachineProbe

    /// The repo-metadata reader (fetch + parse + cache) behind sizing.
    private let metadataReader: RepoMetadataReader

    /// The download+load step behind resolution.
    private let loader: any ModelLoader

    /// Serializes every entry point that mutates ``pool``:
    /// ``resolve(profile:reporting:)`` end to end and ``release(token:)``.
    /// A resolve prices a pooled candidate at its marginal cost and acquires
    /// it later, so a concurrent release must not evict that key in between.
    private let poolLock = AsyncSemaphore(value: 1)

    /// The resident-model pool, keyed by exact artifact identity and
    /// reference-counted across every profile that references it.
    private var pool: [ResidencyKey: PoolEntry] = [:]

    /// The pool holds each resident profile was granted, by residency token.
    /// ``release(token:)`` gives back each hold's charge and forgets the token,
    /// so a double release is a no-op.
    private var residentProfiles: [ULID: [ResidencyHold]] = [:]

    /// Creates a router.
    ///
    /// - Parameters:
    ///   - id: The recording root id. Pass one in to continue a prior root.
    ///   - headroomReserve: Bytes held out of the budget.
    ///   - maxConcurrentForks: In-flight fork sessions per profile.
    ///   - cacheDir: The disposable cache directory, or `nil` for the user caches directory.
    ///   - recordingsDir: The durable transcripts root, or `nil`.
    ///   - recorder: The recorder, or `nil` for a JSONL recorder under `recordingsDir` or ``NoneRecorder``.
    ///   - recordingLevel: How much to record.
    ///   - redact: An optional redaction hook applied to recorded text.
    ///   - tracer: The tracer every vended handle opens its embed span
    ///     through, or `nil` (the default) to read
    ///     `InstrumentationSystem.tracer` at call time. See
    ///     ``RoutedModel/tracer``.
    ///   - probe: The machine probe behind the budget.
    ///   - metadataSource: The metadata fetch behind sizing.
    ///   - loader: The download and load step. Pass a configured ``LiveModelLoader`` for real loading.
    public init(
        id: ULID = .generate(),
        headroomReserve: Int64 = defaultHeadroomReserveBytes,
        maxConcurrentForks: Int = defaultMaxConcurrentForks,
        cacheDir: URL? = nil,
        recordingsDir: URL? = nil,
        recorder: (any TranscriptRecorder)? = nil,
        recordingLevel: RecordingLevel = .full,
        redact: (@Sendable (String) -> String)? = nil,
        tracer: (any Tracer)? = nil,
        probe: any MachineProbe = SystemMachineProbe(),
        metadataSource: any MetadataSource = HuggingFaceMetadataSource(),
        loader: any ModelLoader = UnconfiguredModelLoader()
    ) {
        self.id = id
        self.headroomReserve = headroomReserve
        self.maxConcurrentForks = maxConcurrentForks
        let resolvedCacheDir = cacheDir ?? Self.defaultCacheDir()
        self.recordingsDir = recordingsDir
        let baseRecorder = recorder ?? Self.defaultRecorder(recordingsDir: recordingsDir)
        // Verbatim recording — `.full` with no `redact` hook — needs no gate, so
        // the base sink is threaded down directly; this keeps a session and embed
        // call *born holding the router's recorder itself* in the common case. Any
        // trimming (`.off`) or redaction wraps the base sink so every event
        // source honors it.
        if recordingLevel == .full, redact == nil {
            self.recorder = baseRecorder
        } else {
            self.recorder = GatingRecorder(level: recordingLevel, redact: redact, wrapping: baseRecorder)
        }
        self.recordingLevel = recordingLevel
        self.tracer = tracer
        self.probe = probe
        self.metadataReader = RepoMetadataReader(source: metadataSource, cacheDir: resolvedCacheDir)
        self.loader = loader
    }

    /// Resolves an authored profile into a resident ``LanguageModelProfile``
    /// for this machine, reporting progress through sizing, downloading,
    /// loading, and ready or failed.
    ///
    /// The effective budget is the machine budget less every pooled model's
    /// footprint. A pooled candidate is charged only its marginal cost. The
    /// whole pipeline is single-flight on this router.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive, mutated on the main actor.
    /// - Returns: The resolved, resident profile.
    /// - Throws: ``ResolutionFailure`` when no trio fits the effective budget,
    ///   or any download or load error from the ``ModelLoader``.
    public func resolve(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress
    ) async throws -> LanguageModelProfile {
        // Resolution is the slowest thing the library does, so the whole call
        // — the lock wait included — is one span, and each model this resolve
        // has to fetch opens a child span under it. `withSpan` records a
        // thrown error on the span and raises it again.
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.resolve, ofKind: .client) { span in
                span.attributes[RouterTracing.AttributeKey.routerId] = id.description
                span.attributes[RouterTracing.AttributeKey.profileDefinitionName] = def.name
                return try await runResolve(profile: def, reporting: progress, span: span)
            }
    }

    /// The body of ``resolve(profile:reporting:)``, running inside its span.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive, mutated on the main actor.
    ///   - span: The resolve span, which takes the budget this attempt priced
    ///     against and, on success, the model each slot chose.
    /// - Returns: The resolved, resident profile.
    /// - Throws: ``ResolutionFailure`` when no trio fits the effective budget,
    ///   or any download or load error from the ``ModelLoader``.
    private func runResolve(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress,
        span: any Span
    ) async throws -> LanguageModelProfile {
        await poolLock.wait()
        defer { poolLock.signal() }

        await beginSizing(progress: progress)
        let totalBudget = hostBudget()
        let residentFootprint = pool.values.reduce(Int64(0)) { $0 + $1.footprintBytes }
        let effectiveBudget = totalBudget - residentFootprint
        span.attributes[RouterTracing.AttributeKey.budgetBytes] = effectiveBudget
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

        // Populated incrementally as each slot is acquired — the key beside
        // the bytes that acquisition charged the budget — so a mid-pipeline
        // failure's `catch` below can see exactly what this attempt already
        // holds and give each share back, whether that slot was freshly
        // loaded or reused (bumped) an already-resident entry.
        var slotHolds: [ModelSlot: ResidencyHold] = [:]
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
                let chargedBytes = Self.chosenCharge(for: slotRes)
                let key = try await acquireLLM(
                    key: ResidencyKey(ref: chosen, role: .llm(context: slotRes.contextTokens)),
                    chosen: chosen,
                    slot: slot,
                    context: slotRes.contextTokens,
                    footprintBytes: Self.chosenFootprint(for: slotRes),
                    chargedBytes: chargedBytes,
                    newKeys: &newKeys,
                    progress: progress
                )
                slotHolds[slot] = ResidencyHold(key: key, chargedBytes: chargedBytes)
            }

            let embeddingRes = Self.slotResolution(for: resolution, slot: .embedding)
            let embeddingCharge = Self.chosenCharge(for: embeddingRes)
            let embeddingKey = try await acquireEmbedder(
                key: ResidencyKey(ref: resolution.embedding, role: .embedding),
                chosen: resolution.embedding,
                footprintBytes: Self.chosenFootprint(for: embeddingRes),
                chargedBytes: embeddingCharge,
                newKeys: &newKeys,
                progress: progress
            )
            slotHolds[.embedding] = ResidencyHold(key: embeddingKey, chargedBytes: embeddingCharge)

            await setPhase(.loading, progress: progress)
            // Only the freshly-acquired keys need preloading — a reused key
            // was already preloaded the resolve that first loaded it — and
            // each distinct key is preloaded at most once even if two slots
            // in this same resolve share it (e.g. `standard` and `flash`
            // both winning the identical ref+context).
            var preloadedKeys: Set<ResidencyKey> = []
            for slot in [ModelSlot.standard, .flash, .embedding] {
                guard let key = slotHolds[slot]?.key, newKeys.contains(key) else { continue }
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
            guard let standardKey = slotHolds[.standard]?.key, let flashKey = slotHolds[.flash]?.key,
                  let embeddingKey = slotHolds[.embedding]?.key
            else {
                preconditionFailure("the acquisition loop above populates all three slot holds")
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
            residentProfiles[residencyToken] = Array(slotHolds.values)
            Self.recordChosenModels(resolution: resolution, on: span)
            return profile
        } catch {
            // Give back everything this attempt already acquired — a fresh
            // load is fully evicted, a reused entry's refcount bump and its
            // charge are undone — so a partial failure never leaks a
            // phantom-resident pool entry with no owning profile.
            for hold in slotHolds.values {
                await releaseKey(key: hold.key, chargedBytes: hold.chargedBytes)
            }
            // A download/load/preload failure must move the bound progress to
            // `.failed` so a UI does not hang mid-pipeline, then rethrow.
            await recordLoadFailure(error: error, progress: progress)
            throw error
        }
    }

    /// Names the model each slot chose on the resolve span.
    ///
    /// Written only once the whole resolve succeeded, so the span of a resolve
    /// that threw carries the budget and the error but names no winner.
    ///
    /// - Parameters:
    ///   - resolution: The joint fit this resolve applied.
    ///   - span: The resolve span to write the three keys on.
    private static func recordChosenModels(resolution: JointResolution, on span: any Span) {
        let chosenBySlot: [ModelSlot: ModelRef] = [
            .standard: resolution.standard,
            .flash: resolution.flash,
            .embedding: resolution.embedding,
        ]
        for (slot, chosen) in chosenBySlot {
            span.attributes[RouterTracing.AttributeKey.chosenModelRef(slot: slot)] =
                chosen.stringValue
        }
    }

    // MARK: - Residency

    /// Acquires the pooled model identified by `key`: bumps an existing
    /// entry's refcount, or downloads through `load` and inserts a fresh entry.
    ///
    /// - Parameters:
    ///   - key: This candidate's exact residency identity.
    ///   - chosen: The chosen model reference.
    ///   - slot: The slot being acquired.
    ///   - footprintBytes: This slot's whole margined footprint, the floor of a fresh entry.
    ///   - chargedBytes: The bytes this acquisition charged the shared budget.
    ///   - newKeys: Accumulates `key` when this call inserted a fresh entry.
    ///   - progress: The progress to drive through acquisition.
    ///   - load: The loader call that produces a fresh resident container.
    ///   - wrap: Wraps a fresh container into a ``PooledContainer``.
    /// - Returns: `key`.
    /// - Throws: Any error the loader raises.
    private func acquireModel<Loaded>(
        key: ResidencyKey,
        chosen: ModelRef,
        slot: ModelSlot,
        footprintBytes: Int64,
        chargedBytes: Int64,
        newKeys: inout Set<ResidencyKey>,
        progress: ResolutionProgress,
        load: (ModelRef, ModelSlot, @escaping @Sendable (DownloadProgress) -> Void) async throws ->
            Loaded,
        wrap: (Loaded) -> PooledContainer
    ) async throws -> ResidencyKey {
        if var entry = pool[key] {
            entry.refcount += 1
            entry.acquiredChargeBytes += chargedBytes
            pool[key] = entry
            await setSlotState(slot, to: .ready, progress: progress)
            return key
        }
        // Below the early return above, so a slot the pool already held opens
        // no load span at all: a trace therefore shows a fresh resolve's loads
        // and a later resolve's reuse as two different shapes.
        let container = try await withLoadSpan(
            chosen: chosen, slot: slot, footprintBytes: footprintBytes
        ) {
            try await download(ref: chosen, slot: slot, progress: progress, load: load)
        }
        pool[key] = PoolEntry(
            refcount: 1,
            baseFootprintBytes: footprintBytes,
            acquiredChargeBytes: chargedBytes,
            container: wrap(container),
            gates: ResidentModelGates(maxConcurrentForks: maxConcurrentForks)
        )
        newKeys.insert(key)
        return key
    }

    /// Acquires a generation slot for `key` through
    /// ``acquireModel(key:chosen:slot:footprintBytes:chargedBytes:newKeys:progress:load:wrap:)``.
    ///
    /// - Parameter context: The working context to load a fresh container at.
    private func acquireLLM(
        key: ResidencyKey,
        chosen: ModelRef,
        slot: ModelSlot,
        context: Int,
        footprintBytes: Int64,
        chargedBytes: Int64,
        newKeys: inout Set<ResidencyKey>,
        progress: ResolutionProgress
    ) async throws -> ResidencyKey {
        try await acquireModel(
            key: key, chosen: chosen, slot: slot, footprintBytes: footprintBytes,
            chargedBytes: chargedBytes,
            newKeys: &newKeys, progress: progress,
            load: { try await loader.loadLLM(ref: $0, slot: $1, context: context, reporting: $2) },
            wrap: { .llm($0) }
        )
    }

    /// Acquires the embedding slot for `key` through
    /// ``acquireModel(key:chosen:slot:footprintBytes:chargedBytes:newKeys:progress:load:wrap:)``.
    private func acquireEmbedder(
        key: ResidencyKey,
        chosen: ModelRef,
        footprintBytes: Int64,
        chargedBytes: Int64,
        newKeys: inout Set<ResidencyKey>,
        progress: ResolutionProgress
    ) async throws -> ResidencyKey {
        try await acquireModel(
            key: key, chosen: chosen, slot: .embedding, footprintBytes: footprintBytes,
            chargedBytes: chargedBytes,
            newKeys: &newKeys, progress: progress,
            load: { try await loader.loadEmbedder(ref: $0, slot: $1, reporting: $2) },
            wrap: { .embedding($0) }
        )
    }

    /// Releases the resident-model references a profile was granted at
    /// resolve time. A pooled model that drops to zero references is evicted.
    ///
    /// Idempotent: a token not in ``residentProfiles`` is a no-op.
    ///
    /// - Parameter token: The residency token of the profile to release.
    func release(token: ULID) async {
        await poolLock.wait()
        defer { poolLock.signal() }
        guard let holds = residentProfiles.removeValue(forKey: token) else { return }
        for hold in holds {
            await releaseKey(key: hold.key, chargedBytes: hold.chargedBytes)
        }
    }

    /// Decrements one pooled model's refcount and gives back `chargedBytes`.
    /// Evicts the model at zero references. A no-op when `key` is not pooled.
    private func releaseKey(key: ResidencyKey, chargedBytes: Int64) async {
        guard var entry = pool[key] else { return }
        entry.refcount -= 1
        entry.acquiredChargeBytes -= chargedBytes
        if entry.refcount <= 0 {
            pool.removeValue(forKey: key)
            await loader.evict(container: entry.container.erased)
        } else {
            pool[key] = entry
        }
    }

    // MARK: - Budget

    /// The RAM budget for this machine, measured from a fresh probe read.
    ///
    /// The three reads are cheap, so each resolve takes them again rather than
    /// remember an earlier answer. A value the OS changes — the GPU working set
    /// after an OS update — therefore reaches the very next budget.
    private func hostBudget() -> Int64 {
        HostProfile(probe: probe).budget(headroomReserve: headroomReserve)
    }

    // MARK: - Sizing

    /// Fetches every candidate's parsed metadata, merging results for a ref
    /// shared across slots with ``preferSuccess(left:right:)``.
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

    /// Fetches and parses one candidate's metadata. A non-``RepoMetadataError``
    /// error becomes ``RepoMetadataError/metadataUnavailable(_:)``.
    private func metadataResult(for ref: ModelRef) async -> Result<RepoMetadata, RepoMetadataError> {
        do {
            return .success(try await metadataReader.metadata(for: ref))
        } catch let error as RepoMetadataError {
            return .failure(error)
        } catch {
            return .failure(.metadataUnavailable(error.localizedDescription))
        }
    }

    /// Merges two metadata results for one ref: the first success, or the
    /// first failure when both failed.
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
    private static func slotMembership(profile def: ProfileDefinition) -> [ModelRef: Set<ModelSlot>] {
        var membership: [ModelRef: Set<ModelSlot>] = [:]
        for (slot, refs) in def.candidatesBySlot {
            for ref in refs {
                membership[ref, default: []].insert(slot)
            }
        }
        return membership
    }

    /// The shared diagnostic for a candidate that has no fetched metadata.
    private static func unsizedCandidateMessage(for ref: ModelRef) -> String {
        "candidate \(ref.stringValue) was not sized"
    }

    /// The raw footprint bytes for one candidate at a context, sized under
    /// every slot it is a candidate for, with the largest figure kept.
    ///
    /// A candidate whose ``ResidencyKey`` is in `residentKeys` is charged its
    /// marginal cost: one session KV cache for a generation model, zero for
    /// an embedder.
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
                let sessionKV = metadata.footprint.kvBytes(context: context)
                candidates.append(residentKeys.contains(key) ? sessionKV : raw)
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

    /// The per-session KV cache bytes for one candidate loaded as a generation
    /// model at a working context. This figure is never discounted for
    /// residency.
    ///
    /// - Parameters:
    ///   - ref: The candidate to size.
    ///   - context: The working context one session decodes at.
    ///   - metadataByRef: The sizing metadata fetched for every candidate.
    /// - Returns: The raw KV cache bytes, or why the candidate cannot be sized.
    private static func sessionBytes(
        for ref: ModelRef,
        context: Int,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>]
    ) -> Result<Int64, RepoMetadataError> {
        guard let metadataResult = metadataByRef[ref] else {
            return .failure(.metadataUnavailable(Self.unsizedCandidateMessage(for: ref)))
        }
        return metadataResult.map { $0.footprint.kvBytes(context: context) }
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
                sessionBytes: { ref, context in
                    Self.sessionBytes(for: ref, context: context, metadataByRef: metadataByRef)
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

    /// Opens one load span and runs `body` — the fetch and load of one slot's
    /// model — inside it.
    ///
    /// The caller is ``acquireModel(key:chosen:slot:footprintBytes:chargedBytes:newKeys:progress:load:wrap:)``,
    /// past the point where an already-resident model returns, so only a model
    /// this resolve really fetches opens a span here. The span is a child of
    /// the resolve span, because the resolve span is the current one for the
    /// whole call. `withSpan` records a thrown error on the span and raises it
    /// again.
    ///
    /// - Parameters:
    ///   - chosen: The model reference being loaded.
    ///   - slot: The slot the model fills.
    ///   - footprintBytes: The chosen candidate's whole margined footprint.
    ///   - body: The load work the span measures.
    /// - Returns: Whatever `body` produced.
    /// - Throws: Whatever `body` throws.
    private func withLoadSpan<Loaded>(
        chosen: ModelRef,
        slot: ModelSlot,
        footprintBytes: Int64,
        _ body: () async throws -> Loaded
    ) async throws -> Loaded {
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.load, ofKind: .client) { span in
                span.attributes[RouterTracing.AttributeKey.modelRef] = chosen.stringValue
                span.attributes[RouterTracing.AttributeKey.slot] = slot.rawValue
                span.attributes[RouterTracing.AttributeKey.footprintBytes] = footprintBytes
                return try await body()
            }
    }

    /// Marks a slot downloading, then loads its chosen model through `load`,
    /// which receives the ref, slot, and a download-progress reporter.
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

    /// A monotonic download-progress callback that updates a slot's byte
    /// counts on the main actor. A tick applies only while the slot is still
    /// ``SlotProgress/State/downloading``, and never moves the counts backward.
    ///
    /// - Parameters:
    ///   - slot: The slot whose byte counts this callback advances.
    ///   - progress: The UI-bindable progress whose slot is mutated.
    /// - Returns: A `@Sendable` closure that applies one ``DownloadProgress`` tick.
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

    /// Builds a routed model handle for `slot` from its pooled entry, with
    /// this router's id, recorder, tracer, transcripts root, and the entry's
    /// gates.
    ///
    /// - Parameters:
    ///   - slot: The slot this handle fills.
    ///   - chosen: The chosen model reference for the slot.
    ///   - resolution: Why this model won its slot.
    ///   - key: This slot's residency identity, looked up in ``pool``.
    ///   - resolvedProfile: The run's resolved-profile facts for root session sidecars.
    ///   - unwrap: Extracts the concrete container from a ``PooledContainer``, or `nil`.
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
            gates: entry.gates,
            tracer: tracer
        )
    }

    /// Builds a generation handle for a slot from its pooled entry.
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

    /// Builds the embedding handle from its pooled entry.
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

    /// Pairs this run's durable transcripts root with the sidecar writer for
    /// one handle, or `nil` when there is no durable root.
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

    /// The ``SlotResolution`` for a slot in a joint resolution. Traps when
    /// the slot is missing, because ``JointFit`` records every slot.
    private static func slotResolution(for resolution: JointResolution, slot: ModelSlot)
        -> SlotResolution
    {
        guard let slotRes = resolution.slots.first(where: { $0.slot == slot }) else {
            preconditionFailure("JointResolution records a resolution for every slot; missing \(slot)")
        }
        return slotRes
    }

    /// The report ``JointFit`` recorded for the candidate a slot chose, or
    /// `nil` when the slot recorded none.
    private static func chosenReport(for slotRes: SlotResolution) -> CandidateReport? {
        slotRes.considered.first { $0.verdict == .chosen }
    }

    /// The chosen candidate's margined footprint estimate for a slot, or `0`.
    private static func chosenFootprint(for slotRes: SlotResolution) -> Int64 {
        chosenReport(for: slotRes)?.estimatedFootprintBytes ?? 0
    }

    /// The bytes ``JointFit`` charged the shared budget for a slot's chosen
    /// candidate, or `0`.
    private static func chosenCharge(for slotRes: SlotResolution) -> Int64 {
        chosenReport(for: slotRes)?.chargedBytes ?? 0
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
