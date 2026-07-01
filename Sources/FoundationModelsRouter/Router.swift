import Foundation
import os

/// The logger the router reports best-effort manifest write failures to.
private let manifestLogger = Logger(
    subsystem: moduleName,
    category: "Manifest"
)

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

    /// When the router was constructed — the manifest's run-start instant.
    private let startedAt = Date()

    /// Every profile resolved during this run, in resolution order, recorded into
    /// the manifest as each resolve completes.
    private var resolvedProfiles: [RouterManifest.ResolvedProfile] = []

    /// Creates a router.
    ///
    /// - Parameters:
    ///   - id: The recording root id; pass one in to continue a prior recording
    ///     root. Defaults to a fresh ULID.
    ///   - headroomReserve: Bytes held out of the budget. Defaults to 4 GB.
    ///   - maxConcurrentForks: In-flight fork sessions per profile. Defaults to 4.
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
        maxConcurrentForks: Int = 4,
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
        _ def: ProfileDefinition,
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

        await beginSizing(progress)
        let budget = hostBudget()
        let footprints = await sizeCandidates(def)

        let resolution = try await runJointFit(def, budget: budget, footprints: footprints, progress: progress)
        await markChosen(resolution, progress: progress)

        do {
            await setPhase(.downloading, progress)
            // Both generation slots download and load identically — only the chosen
            // ref and slot differ — so they run through one loop over the (ref, slot)
            // pairs in standard-before-flash order. The embedding slot uses a
            // different loader call (no `context`) and stays separate.
            var generationContainers: [ModelSlot: any LoadedLLMContainer] = [:]
            for (chosen, slot) in [(resolution.standard, ModelSlot.standard), (resolution.flash, ModelSlot.flash)] {
                generationContainers[slot] = try await download(chosen, slot: slot, progress: progress) {
                    try await loader.loadLLM($0, slot: $1, context: def.context, reporting: $2)
                }
            }
            // Total by construction: the loop above populates both generation
            // slots, and `loadLLM` returns a non-optional container.
            guard let standardContainer = generationContainers[.standard],
                  let flashContainer = generationContainers[.flash]
            else {
                preconditionFailure("download loop populates both .standard and .flash generation slots")
            }
            let embeddingContainer = try await download(resolution.embedding, slot: .embedding, progress: progress) {
                try await loader.loadEmbedder($0, slot: $1, reporting: $2)
            }

            await setPhase(.loading, progress)
            // `finalize` takes the common `any LoadedModelContainer` base, so the
            // heterogeneous LLM/embedding containers upcast into one pair list and
            // finalize through a single loop — matching the download section above.
            let finalizePairs: [(ModelSlot, any LoadedModelContainer)] = [
                (.standard, standardContainer),
                (.flash, flashContainer),
                (.embedding, embeddingContainer),
            ]
            for (slot, container) in finalizePairs {
                try await finalize(slot, container: container, progress: progress)
            }

            await complete(progress)
            let residencyToken = ULID.generate()
            let profile = buildProfile(
                def,
                resolution: resolution,
                standardContainer: standardContainer,
                flashContainer: flashContainer,
                embeddingContainer: embeddingContainer,
                residencyToken: residencyToken
            )
            residencyState = .resident(residencyToken)
            recordResolvedProfile(def, resolution: resolution)
            writeManifest()
            return profile
        } catch {
            // A download/load/preload failure must move the bound progress to
            // `.failed` so a UI does not hang mid-pipeline, then rethrow.
            await recordLoadFailure(error, progress: progress)
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
            await loader.evict(container)
        }
    }

    // MARK: - Manifest

    /// Appends a resolved profile to the run's manifest record, capturing which
    /// concrete models won each slot for this machine.
    ///
    /// - Parameters:
    ///   - def: The authored profile that was resolved, for its name.
    ///   - resolution: The joint resolution naming the chosen model per slot.
    private func recordResolvedProfile(_ def: ProfileDefinition, resolution: JointResolution) {
        resolvedProfiles.append(
            RouterManifest.ResolvedProfile(
                definitionName: def.name,
                standard: resolution.standard,
                flash: resolution.flash,
                embedding: resolution.embedding
            )
        )
    }

    /// Writes the run manifest to `recordings/<routerId>/manifest.json`,
    /// best-effort.
    ///
    /// A no-op when the router has no durable transcripts root (recording to
    /// memory/none). Like transcript appends, a write failure is swallowed rather
    /// than surfaced, so a manifest problem never fails a resolve. Each call
    /// rewrites the whole file with the run's config, every profile resolved so
    /// far, and the current time as the run's end so far.
    private func writeManifest() {
        guard let recordingsDir else { return }
        let manifest = RouterManifest(
            routerId: id,
            config: RouterManifest.Config(
                headroomReserve: headroomReserve,
                maxConcurrentForks: maxConcurrentForks,
                recordingLevel: recordingLevel
            ),
            profiles: resolvedProfiles,
            start: startedAt,
            end: Date()
        )
        let directory = recordingsDir.appendingPathComponent(id.description, isDirectory: true)
        let fileURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: fileURL, options: .atomic)
        } catch {
            manifestLogger.error(
                "failed to write router manifest: \(error.localizedDescription, privacy: .public)"
            )
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

    /// Sizes every candidate across all slots into raw footprint bytes at the
    /// profile's context, ready for the joint-fit closure.
    private func sizeCandidates(
        _ def: ProfileDefinition
    ) async -> [ModelRef: Result<Int64, RepoMetadataError>] {
        var out: [ModelRef: Result<Int64, RepoMetadataError>] = [:]
        for (slot, refs) in def.candidatesBySlot {
            for ref in refs {
                let result = await footprintBytes(for: ref, slot: slot, context: def.context)
                if let existing = out[ref] {
                    out[ref] = Self.preferLarger(existing, result)
                } else {
                    out[ref] = result
                }
            }
        }
        return out
    }

    /// The raw footprint bytes for one candidate at a context, slot-aware: the
    /// embedding slot has no KV cache, so it is sized by weights alone.
    private func footprintBytes(
        for ref: ModelRef,
        slot: ModelSlot,
        context: Int
    ) async -> Result<Int64, RepoMetadataError> {
        do {
            let metadata = try await metadataReader.metadata(for: ref)
            let bytes: Int64
            if slot == .embedding {
                bytes = Footprint.embedder(weightBytes: metadata.weightBytes).footprint(context: context)
            } else {
                bytes = metadata.footprint.footprint(context: context)
            }
            return .success(bytes)
        } catch let error as RepoMetadataError {
            return .failure(error)
        } catch {
            return .failure(.metadataUnavailable(error.localizedDescription))
        }
    }

    /// Merges two footprint results for the same ref, keeping the larger
    /// (more conservative) successful figure and preferring success over failure.
    private static func preferLarger(
        _ lhs: Result<Int64, RepoMetadataError>,
        _ rhs: Result<Int64, RepoMetadataError>
    ) -> Result<Int64, RepoMetadataError> {
        switch (lhs, rhs) {
        case let (.success(a), .success(b)):
            return .success(max(a, b))
        case (.success, .failure):
            return lhs
        case (.failure, .success):
            return rhs
        case (.failure, .failure):
            return lhs
        }
    }

    // MARK: - Joint fit

    /// Runs the pure joint fit and, on failure, records the diagnostics into the
    /// progress before rethrowing.
    private func runJointFit(
        _ def: ProfileDefinition,
        budget: Int64,
        footprints: [ModelRef: Result<Int64, RepoMetadataError>],
        progress: ResolutionProgress
    ) async throws -> JointResolution {
        do {
            return try JointFit.resolve(profile: def, budgetBytes: budget) { ref in
                footprints[ref] ?? .failure(.metadataUnavailable("candidate \(ref.stringValue) was not sized"))
            }
        } catch let failure as ResolutionFailure {
            await recordFailure(failure, progress: progress)
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
        _ chosen: ModelRef,
        slot: ModelSlot,
        progress: ResolutionProgress,
        load: (ModelRef, ModelSlot, @escaping @Sendable (DownloadProgress) -> Void) async throws -> C
    ) async throws -> C {
        await setSlotState(slot, .downloading, progress: progress)
        let reporting = Self.reporter(slot: slot, progress: progress)
        return try await load(chosen, slot, reporting)
    }

    /// Preloads a downloaded container and marks its slot ready.
    private func finalize(
        _ slot: ModelSlot,
        container: any LoadedModelContainer,
        progress: ResolutionProgress
    ) async throws {
        await setSlotState(slot, .loading, progress: progress)
        try await loader.preload(container)
        await MainActor.run {
            var sp = progress.slots[slot] ?? SlotProgress()
            sp.state = .ready
            progress.slots[slot] = sp
            progress.refreshFraction()
        }
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
        _ def: ProfileDefinition,
        resolution: JointResolution,
        standardContainer: any LoadedLLMContainer,
        flashContainer: any LoadedLLMContainer,
        embeddingContainer: any LoadedEmbeddingContainer,
        residencyToken: ULID
    ) -> LanguageModelProfile {
        let embeddingRes = Self.slotResolution(resolution, slot: .embedding)
        return LanguageModelProfile(
            definitionName: def.name,
            standard: makeRoutedLLM(
                slot: .standard,
                chosen: resolution.standard,
                container: standardContainer,
                resolution: Self.slotResolution(resolution, slot: .standard)
            ),
            flash: makeRoutedLLM(
                slot: .flash,
                chosen: resolution.flash,
                container: flashContainer,
                resolution: Self.slotResolution(resolution, slot: .flash)
            ),
            embedding: RoutedEmbedder(
                slot: .embedding,
                chosen: resolution.embedding,
                footprintBytes: Self.chosenFootprint(embeddingRes),
                resolution: embeddingRes,
                container: embeddingContainer,
                routerId: id,
                recorder: recorder,
                recordingsRoot: recordingsDir
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
    /// - Returns: The routed generation handle.
    private func makeRoutedLLM(
        slot: ModelSlot,
        chosen: ModelRef,
        container: any LoadedLLMContainer,
        resolution: SlotResolution
    ) -> RoutedLLM {
        RoutedLLM(
            slot: slot,
            chosen: chosen,
            footprintBytes: Self.chosenFootprint(resolution),
            resolution: resolution,
            container: container,
            routerId: id,
            recorder: recorder,
            recordingsRoot: recordingsDir,
            maxConcurrentForks: maxConcurrentForks
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
    private static func slotResolution(_ resolution: JointResolution, slot: ModelSlot) -> SlotResolution {
        guard let slotRes = resolution.slots.first(where: { $0.slot == slot }) else {
            preconditionFailure("JointResolution records a resolution for every slot; missing \(slot)")
        }
        return slotRes
    }

    /// The chosen candidate's `× 1.2` footprint estimate for a slot, or `0` when
    /// unrecorded.
    private static func chosenFootprint(_ slotRes: SlotResolution) -> Int64 {
        slotRes.considered.first { $0.verdict == .chosen }?.estimatedFootprintBytes ?? 0
    }

    // MARK: - Progress mutations (main actor)

    /// Enters the sizing phase with all slots sizing.
    private func beginSizing(_ progress: ResolutionProgress) async {
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
    private func markChosen(_ resolution: JointResolution, progress: ResolutionProgress) async {
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
    private func setPhase(_ phase: ResolutionProgress.Phase, _ progress: ResolutionProgress) async {
        await MainActor.run { progress.phase = phase }
    }

    /// Sets a single slot's state and refreshes the overall fraction.
    private func setSlotState(
        _ slot: ModelSlot,
        _ state: SlotProgress.State,
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
    private func complete(_ progress: ResolutionProgress) async {
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
    private func recordFailure(_ failure: ResolutionFailure, progress: ResolutionProgress) async {
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
    private func recordLoadFailure(_ error: Error, progress: ResolutionProgress) async {
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
