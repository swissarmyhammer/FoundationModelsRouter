import Foundation

/// The default in-flight fork-session ceiling per resolved profile.
///
/// Shared between ``Router/init(id:headroomReserve:maxConcurrentForks:cacheDir:recordingsDir:recorder:recordingLevel:redact:probe:metadataSource:loader:)``
/// and ``RoutedModel/init(slot:chosen:footprintBytes:resolution:container:routerId:recorder:durableRecording:maxConcurrentForks:)``'s
/// own default, so a ``RoutedModel`` constructed directly (outside a
/// ``Router``, e.g. in tests) admits the same ceiling a router-vended one
/// would.
///
/// `public` (not `internal`) because both initializers that default to it are
/// `public`: a default argument expression must be at least as visible as the
/// declaration it defaults on, since it is evaluated at every call site.
public let defaultMaxConcurrentForks = 4

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

/// A failure operating the ``Router`` lifecycle.
public enum RouterError: Error, Equatable {
    /// A profile is already resident: the router admits one active profile at a
    /// time so it never over-commits RAM. Release the resident profile (see
    /// ``LanguageModelProfile/release()``) before resolving another.
    case profileAlreadyResident
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

    /// The router's mutually-exclusive residency state, making impossible states
    /// unrepresentable: it is either idle, resolving, or resident — never, say,
    /// "resident and resolving" at once.
    ///
    /// The ``ResidencyState/resident(_:)`` case carries the residency token of the
    /// currently resident profile: a unique, never-reused ``ULID`` (not an
    /// `ObjectIdentifier`, whose address-derived value a freed profile could hand
    /// to a later one), so it imposes the one-active-profile rule without keeping a
    /// dropped profile alive and without a stale release ever matching a newer
    /// profile. The ``ResidencyState/resolving`` case is entered synchronously
    /// before the first suspension so a second ``resolve(_:reporting:)`` entering
    /// during the download/load awaits is rejected rather than racing to
    /// over-commit.
    private var residencyState: ResidencyState = .idle

    /// The router's mutually-exclusive residency lifecycle.
    ///
    /// Modeling the states as one enum makes the impossible combinations — such
    /// as "resident while resolving" — unrepresentable, unlike a separate
    /// residency-token optional and in-flight flag.
    private enum ResidencyState {
        /// No profile is resident and none is being resolved.
        case idle
        /// A ``Router/resolve(_:reporting:)`` is in flight; a second concurrent
        /// resolve is rejected until it settles.
        case resolving
        /// A profile is resident, carrying its unique residency token so a stale
        /// release cannot clobber a newer profile.
        case resident(ULID)
    }

    /// Creates a router.
    ///
    /// - Parameters:
    ///   - id: The recording root id; pass one in to continue a prior recording
    ///     root. Defaults to a fresh ULID.
    ///   - headroomReserve: Bytes held out of the budget. Defaults to 4 GB.
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
        headroomReserve: Int64 = 4 << 30,
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
    /// Computes the budget from the host profile, sizes every candidate via repo
    /// metadata, runs joint fit to pick the trio, then downloads, loads, and
    /// preloads the chosen three. On an unsatisfiable profile it sets the
    /// progress phase to ``ResolutionProgress/Phase/failed(_:)`` and throws
    /// ``ResolutionFailure`` carrying the per-slot diagnostics.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive (mutated on the main actor).
    /// - Returns: The resolved, resident profile.
    /// - Throws: ``ResolutionFailure`` when no trio co-fits the budget, or any
    ///   download/load error from the ``ModelLoader``.
    public func resolve(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress
    ) async throws -> LanguageModelProfile {
        guard case .idle = residencyState else {
            throw RouterError.profileAlreadyResident
        }
        residencyState = .resolving
        // If resolution throws before reaching residency, return to idle; a
        // successful resolve sets `.resident(token)` below, which this leaves
        // untouched.
        defer {
            if case .resolving = residencyState { residencyState = .idle }
        }

        await beginSizing(progress: progress)
        let budget = hostBudget()
        let metadataByRef = await sizeCandidates(profile: def)

        let resolution = try await runJointFit(profile: def, budget: budget, metadataByRef: metadataByRef, progress: progress)
        await markChosen(resolution: resolution, progress: progress)

        do {
            await setPhase(.downloading, progress: progress)
            // Both generation slots download and load identically — only the chosen
            // ref and slot differ — so they run through one loop over the (ref, slot)
            // pairs in standard-before-flash order. The embedding slot uses a
            // different loader call (no `context`) and stays separate.
            var generationContainers: [ModelSlot: any LoadedLLMContainer] = [:]
            for (chosen, slot) in [
                (resolution.standard, ModelSlot.standard), (resolution.flash, ModelSlot.flash),
            ] {
                // The context joint fit actually resolved this slot at — the
                // authored `def.context` verbatim when explicit, or the rung
                // the ladder settled on when it was `nil` (see `JointFit`).
                let context = Self.slotResolution(for: resolution, slot: slot).contextTokens
                generationContainers[slot] = try await download(ref: chosen, slot: slot, progress: progress) {
                    try await loader.loadLLM(ref: $0, slot: $1, context: context, reporting: $2)
                }
            }
            // Total by construction: the loop above populates both generation
            // slots, and `loadLLM` returns a non-optional container.
            guard let standardContainer = generationContainers[.standard],
                  let flashContainer = generationContainers[.flash]
            else {
                preconditionFailure("download loop populates both .standard and .flash generation slots")
            }
            let embeddingContainer = try await download(ref: resolution.embedding, slot: .embedding, progress: progress) {
                try await loader.loadEmbedder(ref: $0, slot: $1, reporting: $2)
            }

            await setPhase(.loading, progress: progress)
            // `finalize` takes the common `any LoadedModelContainer` base, so the
            // heterogeneous LLM/embedding containers upcast into one pair list and
            // finalize through a single loop — matching the download section above.
            let finalizePairs: [(ModelSlot, any LoadedModelContainer)] = [
                (.standard, standardContainer),
                (.flash, flashContainer),
                (.embedding, embeddingContainer),
            ]
            for (slot, container) in finalizePairs {
                try await finalize(slot: slot, container: container, progress: progress)
            }

            await complete(progress: progress)
            let residencyToken = ULID.generate()
            let profile = buildProfile(
                definition: def,
                resolution: resolution,
                standardContainer: standardContainer,
                flashContainer: flashContainer,
                embeddingContainer: embeddingContainer,
                residencyToken: residencyToken
            )
            residencyState = .resident(residencyToken)
            return profile
        } catch {
            // A download/load/preload failure must move the bound progress to
            // `.failed` so a UI does not hang mid-pipeline, then rethrow.
            await recordLoadFailure(error: error, progress: progress)
            throw error
        }
    }

    // MARK: - Residency

    /// Evicts a resident profile's three containers through the loader and frees
    /// the residency slot, so the next ``resolve(_:reporting:)`` can proceed.
    ///
    /// Called by ``LanguageModelProfile/release()`` (and its `deinit`). Matching
    /// on the unique residency `token` makes it idempotent and safe against a
    /// stale caller: it only evicts and clears while `token` is the token
    /// currently resident, so a double release — or a `deinit` firing after an
    /// explicit release, or after a *different* profile has since been resolved —
    /// is a no-op that cannot evict the wrong models or clobber another profile's
    /// residency. Because the token is never reused (unlike an address-derived
    /// `ObjectIdentifier`), a freed profile's `deinit` can never collide with a
    /// later profile's token. The slot is cleared before eviction so a concurrent
    /// release of the same profile cannot double-evict.
    ///
    /// - Parameters:
    ///   - token: The residency token of the profile asking to be released.
    ///   - containers: That profile's three resident containers, to evict.
    func release(token: ULID, containers: [any LoadedModelContainer]) async {
        guard case .resident(let current) = residencyState, current == token else { return }
        residencyState = .idle
        for container in containers {
            await loader.evict(container: container)
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
    /// already in hand (see ``footprintBytes(for:context:metadataByRef:membership:)``),
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
    /// ``footprintBytes(for:context:metadataByRef:membership:)``.
    private static func slotMembership(profile def: ProfileDefinition) -> [ModelRef: Set<ModelSlot>] {
        var membership: [ModelRef: Set<ModelSlot>] = [:]
        for (slot, refs) in def.candidatesBySlot {
            for ref in refs {
                membership[ref, default: []].insert(slot)
            }
        }
        return membership
    }

    /// The raw footprint bytes for one candidate at a context, conservatively
    /// sized across every slot it is a candidate for: the embedding
    /// interpretation has no KV cache (weights alone), while standard/flash
    /// do — a ref that is a candidate for both is sized under both and the
    /// larger figure is kept, so neither slot's fit test under-estimates it.
    private static func footprintBytes(
        for ref: ModelRef,
        context: Int,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        membership: [ModelRef: Set<ModelSlot>]
    ) -> Result<Int64, RepoMetadataError> {
        guard let metadataResult = metadataByRef[ref] else {
            return .failure(.metadataUnavailable("candidate \(ref.stringValue) was not sized"))
        }
        switch metadataResult {
        case .failure(let error):
            return .failure(error)
        case .success(let metadata):
            let slots = membership[ref] ?? []
            var candidates: [Int64] = []
            if slots.contains(.embedding) {
                candidates.append(
                    Footprint.embedder(weightBytes: metadata.weightBytes).footprint(context: context))
            }
            if slots.contains(.standard) || slots.contains(.flash) {
                candidates.append(metadata.footprint.footprint(context: context))
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
        progress: ResolutionProgress
    ) async throws -> JointResolution {
        let membership = Self.slotMembership(profile: def)
        do {
            return try JointFit.resolve(
                profile: def,
                budgetBytes: budget,
                footprint: { ref, context in
                    Self.footprintBytes(for: ref, context: context, metadataByRef: metadataByRef, membership: membership)
                },
                nativeMaxContext: { ref in
                    (metadataByRef[ref]
                        ?? .failure(.metadataUnavailable("candidate \(ref.stringValue) was not sized")))
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

    /// Assembles the resolved profile from the loaded containers and the
    /// per-slot resolutions, stamping each handle with the router's id and recorder.
    private func buildProfile(
        definition def: ProfileDefinition,
        resolution: JointResolution,
        standardContainer: any LoadedLLMContainer,
        flashContainer: any LoadedLLMContainer,
        embeddingContainer: any LoadedEmbeddingContainer,
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
                container: standardContainer,
                resolution: Self.slotResolution(for: resolution, slot: .standard),
                resolvedProfile: resolvedProfile
            ),
            flash: makeRoutedLLM(
                slot: .flash,
                chosen: resolution.flash,
                container: flashContainer,
                resolution: Self.slotResolution(for: resolution, slot: .flash),
                resolvedProfile: resolvedProfile
            ),
            embedding: RoutedEmbedder(
                slot: .embedding,
                chosen: resolution.embedding,
                footprintBytes: Self.chosenFootprint(for: embeddingRes),
                resolution: embeddingRes,
                container: embeddingContainer,
                routerId: id,
                recorder: recorder,
                // The embedding handle never vends a session, so its writer is
                // never reached — it is here because a durable root and its
                // writer are one value, which is what keeps the two generation
                // handles above from being handed a root with no writer.
                durableRecording: makeDurableRecording(
                    slot: .embedding,
                    chosen: resolution.embedding,
                    resolution: embeddingRes,
                    resolvedProfile: resolvedProfile
                )
            ),
            router: self,
            residencyToken: residencyToken
        )
    }

    /// Builds a generation handle for a slot, stamping it with this router's id,
    /// recorder, and transcripts root.
    ///
    /// The `.standard` and `.flash` slots construct identical ``RoutedLLM``
    /// handles differing only by slot, chosen ref, container, and resolution, so
    /// both go through this one helper.
    ///
    /// - Parameters:
    ///   - slot: The slot this handle fills.
    ///   - chosen: The chosen model reference for the slot.
    ///   - container: The loaded, resident generation container.
    ///   - resolution: Why this model won its slot.
    ///   - resolvedProfile: The run's resolved-profile facts, recorded onto
    ///     the sidecar of every root session vended from this handle.
    /// - Returns: The routed generation handle.
    private func makeRoutedLLM(
        slot: ModelSlot,
        chosen: ModelRef,
        container: any LoadedLLMContainer,
        resolution: SlotResolution,
        resolvedProfile: SessionSidecar.ResolvedProfile
    ) -> RoutedLLM {
        RoutedLLM(
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
            maxConcurrentForks: maxConcurrentForks
        )
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
                profile: resolvedProfile
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
