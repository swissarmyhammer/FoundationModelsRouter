import Foundation
import FoundationModels
import FoundationModelsExtras
import Metrics
import Tracing

/// Whether a session's activity is recorded: `off` or `full`.
public enum RecordingLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// Record nothing.
    case off
    /// Record everything, including prompt and response text.
    case full
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
/// union of every model resident in its ``ModelPool`` against one shared
/// budget. The pool is the Extras pool of the process: every router, the
/// registry and the multitool take their models from ``ModelPool/shared``
/// unless a router is given its own pool, so a model that two users name is
/// loaded one time. The router is one user of the pool. The pool counts the
/// holds of each ``ModelPoolKey``, and each resolve keeps one ``ModelHold``
/// for each slot. The measurement, the joint fit and the acquires of one
/// ``resolve(profile:reporting:)`` run as one admission job of the pool, so
/// no other load and no eviction occurs between the measurement and the
/// acquires.
public actor Router {
    /// The recording root id; sortable by construction time.
    public nonisolated let id: ULID

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

    /// The decoding strategy every backend this router's handles make
    /// decodes with, or `nil` for the provider default. A decode option of
    /// the router, not of the shared container: two routers over one pooled
    /// container each decode with their own mode (`model-pool.md` §2.5).
    let samplingMode: GenerationOptions.SamplingMode?

    /// The Extras model pool this router resolves into. Every user of one
    /// pool shares its residents and its admission queue.
    package nonisolated let pool: ModelPool

    /// The prompt-cache sizing of this router: it sends the budget to the
    /// prompt cache of ``loader`` for each change of the footprint of
    /// ``pool``, and around each acquire of a resolve.
    nonisolated let promptCacheSizing: PromptCacheSizing

    /// Creates a router.
    ///
    /// The router starts one task that reads the footprints of `pool` and
    /// sends the prompt-cache budget to `loader`. The task ends when the
    /// router is released.
    ///
    /// - Parameters:
    ///   - id: The recording root id. Pass one in to continue a prior root.
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
    ///   - samplingMode: The decoding strategy every session this router
    ///     vends decodes with. `nil` (the default) leaves the provider
    ///     default, which samples. `.greedy` gives repeatable output.
    ///   - pool: The resident-model pool to resolve into. The default,
    ///     ``ModelPool/shared``, is one pool for the whole process. Pass a
    ///     fresh ``ModelPool`` for a router that must not share residents.
    public init(
        id: ULID = .generate(),
        cacheDir: URL? = nil,
        recordingsDir: URL? = nil,
        recorder: (any TranscriptRecorder)? = nil,
        recordingLevel: RecordingLevel = .full,
        redact: (@Sendable (String) -> String)? = nil,
        tracer: (any Tracer)? = nil,
        probe: any MachineProbe = SystemMachineProbe(),
        metadataSource: any MetadataSource = HuggingFaceMetadataSource(),
        loader: any ModelLoader = UnconfiguredModelLoader(),
        samplingMode: GenerationOptions.SamplingMode? = nil,
        pool: ModelPool = .shared
    ) {
        self.id = id
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
        self.samplingMode = samplingMode
        self.pool = pool
        self.promptCacheSizing = PromptCacheSizing(pool: pool, loader: loader, probe: probe)
    }

    /// Resolves an authored profile into a resident ``LanguageModelProfile``
    /// for this machine, reporting progress through sizing, downloading,
    /// loading, and ready, failed or cancelled.
    ///
    /// The effective budget is the machine budget less every pooled model's
    /// footprint. A pooled candidate is charged only its marginal cost. The
    /// measurement, the joint fit, each acquire and each preload run as one
    /// admission job of the Extras ``ModelPool``. Each load of a new model,
    /// by a router or by any other user of the pool, and each eviction is a
    /// job in the same FIFO admission queue. Thus no other load and no
    /// eviction occurs between the measurement and the acquires.
    ///
    /// Cancelling the calling task stops the resolve. A resolve whose
    /// admission job waits in the queue leaves it at once; a job that is
    /// already running stops at the next stage boundary. Either way the bound
    /// progress ends at ``ResolutionProgress/Phase/cancelled`` and not at
    /// ``ResolutionProgress/Phase/failed(_:)``, the admission job ends, every
    /// hold the attempt had taken is given back, and no half-resolved profile
    /// is left resident. The models already downloaded
    /// stay in the Hugging Face cache, so a later resolve continues the
    /// transfer rather than starting it again.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive, mutated on the main actor.
    /// - Returns: The resolved, resident profile. Its `standard` and `flash`
    ///   slots never use the same model.
    /// - Throws: ``SameGenerationModelFailure`` before any load when the
    ///   profile names only one model for both the `standard` and the `flash`
    ///   slot, ``ResolutionFailure`` when no trio fits the effective budget,
    ///   ``NoWindowFailure`` when the profile names no context and no standard
    ///   candidate's window could be read,
    ///   `CancellationError` when the calling task is cancelled, or any download
    ///   or load error from the ``ModelLoader``.
    public func resolve(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress
    ) async throws -> LanguageModelProfile {
        // Resolution is the slowest thing the library does, so the whole call
        // — the lock wait included — is one span, and each model this resolve
        // has to fetch opens a child span under it. `withSpan` records a
        // thrown error on the span and raises it again.
        try await RouterTelemetry.tracer(explicit: tracer)
            .withSpan(RouterTelemetry.SpanName.resolve, ofKind: .client) { span in
                span.attributes[RouterTelemetry.AttributeKey.routerId] = id.description
                span.attributes[RouterTelemetry.AttributeKey.profileDefinitionName] = def.name
                return try await runResolve(profile: def, reporting: progress, span: span)
            }
    }

    /// The slots a resolve acquires, in acquisition order: `standard` before
    /// `flash`, then the embedding.
    private static let acquisitionOrder: [ModelSlot] = [.standard, .flash, .embedding]

    /// One slot's hold this resolve took, and whether this resolve loaded
    /// the model.
    private struct AcquiredSlot {
        /// The hold of the slot. Dropping it gives it back to the pool.
        let hold: ModelHold

        /// Whether this resolve loaded the model through its own loader, so
        /// its container needs a preload.
        let isNewLoad: Bool
    }

    /// What the admission job of one resolve gives back: the joint fit it
    /// applied, the hold of each slot, and the container of each handle.
    private struct AdmittedResolve: Sendable {
        /// The joint fit the job applied.
        let resolution: JointResolution

        /// The hold of each slot, in ``acquisitionOrder``.
        let holds: [ModelHold]

        /// The generation container of the `standard` slot.
        let standard: any LoadedLLMContainer

        /// The generation container of the `flash` slot.
        let flash: any LoadedLLMContainer

        /// The embedding container of the `embedding` slot.
        let embedding: any LoadedEmbeddingContainer
    }

    /// The body of ``resolve(profile:reporting:)``, running inside its span. It
    /// records a cancellation.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive, mutated on the main actor.
    ///   - span: The resolve span, which takes the budget this attempt priced
    ///     against and, on success, the model each slot chose.
    /// - Returns: The resolved, resident profile.
    /// - Throws: ``SameGenerationModelFailure`` when the profile names only one
    ///   model for both generation slots,
    ///   ``ResolutionFailure`` when no trio fits the effective budget,
    ///   ``NoWindowFailure`` when the profile names no context and no standard
    ///   candidate's window could be read,
    ///   `CancellationError` when the calling task is cancelled, or any download
    ///   or load error from the ``ModelLoader``.
    private func runResolve(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress,
        span: any Span
    ) async throws -> LanguageModelProfile {
        // Every `CancellationError` the pipeline raises — from the admission
        // queue or from a stage boundary within — ends as
        // ``ResolutionProgress/Phase/cancelled`` and never as `.failed`, so a
        // host tells the user's own stop apart from a fault. A resolve
        // cancelled in the admission queue never started its job and never
        // took a hold, so the phase is the whole of what it leaves.
        do {
            return try await runResolvePipeline(profile: def, reporting: progress, span: span)
        } catch let cancellation as CancellationError {
            await recordCancellation(progress: progress)
            throw cancellation
        }
    }

    /// The stages of ``runResolve(profile:reporting:span:)``: the sizing, then
    /// one admission job of the pool, then the profile.
    ///
    /// - Parameters:
    ///   - def: The authored profile to resolve.
    ///   - progress: The UI-bindable progress to drive, mutated on the main actor.
    ///   - span: The resolve span, which takes the budget this attempt priced
    ///     against and, on success, the model each slot chose.
    /// - Returns: The resolved, resident profile.
    /// - Throws: ``SameGenerationModelFailure`` when the profile names only one
    ///   model for both generation slots,
    ///   ``ResolutionFailure`` when no trio fits the effective budget,
    ///   ``NoWindowFailure`` when the profile names no context and no standard
    ///   candidate's window could be read,
    ///   `CancellationError` when the calling task is cancelled, or any download
    ///   or load error from the ``ModelLoader``.
    private func runResolvePipeline(
        profile def: ProfileDefinition,
        reporting progress: ResolutionProgress,
        span: any Span
    ) async throws -> LanguageModelProfile {
        // Each stage below opens with a cancellation check, so a resolve the
        // user cancelled stops at the next stage boundary rather than paying
        // for the whole pipeline. A throw drops every hold this attempt took,
        // so a cancelled resolve gives back all that it acquired.
        try Task.checkCancellation()
        await beginSizing(progress: progress)
        try await rejectSharedGenerationModel(profile: def, progress: progress)
        // The metadata does not depend on the pool, so its fetch runs before
        // the admission job and does not keep the admission queue waiting.
        let metadataByRef = await sizeCandidates(profile: def)
        try Task.checkCancellation()

        // An admission job runs on a task of its own, which inherits no task
        // local. The service context of the resolve span goes into the job,
        // so each load span stays a child of the resolve span. The metrics
        // factory of the caller goes into the job too, so each load metric
        // goes where the metrics of the caller go.
        let serviceContext = ServiceContext.current
        let metricsFactory = MetricsSystem.factory
        let admitted = try await pool.admit { admission in
            try await withMetricsFactory(metricsFactory) {
                try await ServiceContext.withValue(serviceContext) {
                    try await self.runAdmission(
                        admission: admission, profile: def, metadataByRef: metadataByRef, progress: progress,
                        span: span)
                }
            }
        }

        try Task.checkCancellation()
        await complete(progress: progress)
        let profile = buildProfile(definition: def, admitted: admitted)
        Self.recordChosenModels(resolution: admitted.resolution, on: span)
        return profile
    }

    /// The admission job of one resolve: measures the budget, runs the joint
    /// fit, and acquires the three slots. The job is the one job that runs in
    /// the admission queue of the pool, so no other load and no eviction
    /// occurs between the measurement and the acquires.
    ///
    /// - Parameters:
    ///   - admission: The pool inside this admission job.
    ///   - def: The authored profile to resolve.
    ///   - metadataByRef: The sizing metadata fetched for every candidate.
    ///   - progress: The UI-bindable progress to drive, mutated on the main actor.
    ///   - span: The resolve span, which takes the budget this attempt priced
    ///     against.
    /// - Returns: The joint fit, the holds and the containers of the profile.
    /// - Throws: ``ResolutionFailure`` when no trio fits the effective budget,
    ///   ``NoWindowFailure`` when the profile names no context and no standard
    ///   candidate's window could be read, `CancellationError` when the
    ///   calling task is cancelled, or any download or load error.
    private func runAdmission(
        admission: ModelPoolAdmission,
        profile def: ProfileDefinition,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        progress: ResolutionProgress,
        span: any Span
    ) async throws -> AdmittedResolve {
        try Task.checkCancellation()
        let totalBudget = hostBudget()
        let footprint = admission.footprint
        let effectiveBudget = totalBudget - footprint.totalBytes
        span.attributes[RouterTelemetry.AttributeKey.budgetBytes] = effectiveBudget

        let resolution = try await runJointFit(
            profile: def,
            budget: effectiveBudget,
            metadataByRef: metadataByRef,
            residentKeys: Set(footprint.resident.keys),
            progress: progress
        )
        await markChosen(resolution: resolution, progress: progress)

        do {
            return try await acquireSlots(
                admission: admission, resolution: resolution, metadataByRef: metadataByRef, progress: progress)
        } catch {
            // A download/load/preload failure must move the bound progress to
            // `.failed` so a UI does not hang mid-pipeline, then rethrow. A
            // cancel is not a failure: its phase is set by the caller of this
            // pipeline, which owns the `.cancelled` phase for every stage.
            if !(error is CancellationError) {
                await recordLoadFailure(error: error, progress: progress)
            }
            throw error
        }
    }

    /// Acquires the three slots of `resolution`, preloads each model this
    /// resolve loaded, and gets the container of each handle.
    ///
    /// Each hold is a local value, so a throw drops every hold this attempt
    /// took, and the pool gives it back: the last hold of a fresh load is
    /// evicted, and a hold on a model that was resident before is released.
    /// A partial failure thus never leaks a resident model with no owner.
    ///
    /// - Parameters:
    ///   - admission: The pool inside the admission job of this resolve.
    ///   - resolution: The joint fit this resolve applies.
    ///   - metadataByRef: The sizing metadata fetched for every candidate.
    ///   - progress: The progress to drive through acquisition.
    /// - Returns: The joint fit, the holds and the containers of the profile.
    /// - Throws: `CancellationError` when the calling task is cancelled, any
    ///   download, load or preload error, or an error when the container of
    ///   a hold does not fit its slot.
    private func acquireSlots(
        admission: ModelPoolAdmission,
        resolution: JointResolution,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        progress: ResolutionProgress
    ) async throws -> AdmittedResolve {
        await setPhase(.downloading, progress: progress)
        var acquired: [ModelSlot: AcquiredSlot] = [:]
        for slot in Self.acquisitionOrder {
            try Task.checkCancellation()
            acquired[slot] = try await acquire(
                slot: slot, resolution: resolution, metadataByRef: metadataByRef,
                admission: admission, progress: progress)
        }

        await setPhase(.loading, progress: progress)
        // Only the fresh loads of this resolve need preloading — a reused
        // model was preloaded by the user that loaded it. No two slots of one
        // resolve share a key: `standard` and `flash` never name the same
        // model, and the embedding key has its own role.
        for slot in Self.acquisitionOrder {
            try Task.checkCancellation()
            guard let slotHold = acquired[slot], slotHold.isNewLoad else { continue }
            try await finalize(slot: slot, hold: slotHold.hold, progress: progress)
        }

        try Task.checkCancellation()
        guard let standard = acquired[.standard], let flash = acquired[.flash],
              let embedding = acquired[.embedding]
        else {
            preconditionFailure("the acquisition loop above populates all three slots")
        }
        return AdmittedResolve(
            resolution: resolution,
            holds: [standard.hold, flash.hold, embedding.hold],
            standard: try standard.hold.generationContainer(),
            flash: try flash.hold.generationContainer(),
            embedding: try PooledEmbeddingContainer(hold: embedding.hold)
        )
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
        for slot in acquisitionOrder {
            span.attributes[RouterTelemetry.AttributeKey.chosenModelRef(slot: slot)] =
                chosenRef(of: slot, in: resolution).stringValue
        }
    }

    // MARK: - Residency

    /// Takes the hold of one slot inside the admission job of this resolve: a
    /// new hold on a resident model, or a load of a new model through this
    /// router's loader.
    ///
    /// Before the acquire, the prompt cache of this router's loader gets a
    /// budget less the bytes the acquire adds: the whole footprint of a new
    /// model, so the prompt cache is small before the weights load, or the
    /// session of a new hold on a resident model. After the acquire, and
    /// after a failed acquire, the budget goes back to the footprint of the
    /// pool (``PromptCacheSizing/withBudget(adding:isolation:_:)``).
    ///
    /// - Parameters:
    ///   - slot: The slot being acquired.
    ///   - resolution: The joint fit this resolve applies.
    ///   - metadataByRef: The sizing metadata fetched for every candidate.
    ///   - admission: The pool inside the admission job of this resolve.
    ///   - progress: The progress to drive through acquisition.
    /// - Returns: The hold, and whether this call loaded the model.
    /// - Throws: Any error the loader raises.
    private func acquire(
        slot: ModelSlot,
        resolution: JointResolution,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        admission: ModelPoolAdmission,
        progress: ResolutionProgress
    ) async throws -> AcquiredSlot {
        let slotRes = Self.slotResolution(for: resolution, slot: slot)
        let chosen = Self.chosenRef(of: slot, in: resolution)
        let footprintBytes = Self.chosenFootprint(for: slotRes)
        let sessionBytes = Self.chosenSessionBytes(
            of: slot, chosen: chosen, context: slotRes.contextTokens, metadataByRef: metadataByRef)
        let slotLoader = SlotPoolLoader(
            loader: loader, slot: slot, context: slotRes.contextTokens,
            reporting: Self.reporter(slot: slot, progress: progress))
        let isResident = admission.footprint.resident[ModelPoolKey(ref: chosen, role: slot.poolRole)] != nil

        return try await promptCacheSizing.withBudget(adding: isResident ? sessionBytes : footprintBytes) {
            if isResident {
                let hold = try await slotLoader.acquireHold(
                    of: chosen, in: admission, footprintBytes: footprintBytes, sessionBytes: sessionBytes)
                await setSlotState(slot, to: .ready, progress: progress)
                return AcquiredSlot(hold: hold, isNewLoad: false)
            }
            // Only a model the pool did not hold opens a load span, so a
            // trace shows a fresh resolve's loads and a later resolve's
            // reuse as two different shapes.
            let hold = try await withLoadSpan(chosen: chosen, slot: slot, footprintBytes: footprintBytes) {
                await setSlotState(slot, to: .downloading, progress: progress)
                return try await slotLoader.acquireHold(
                    of: chosen, in: admission, footprintBytes: footprintBytes, sessionBytes: sessionBytes)
            }
            return AcquiredSlot(hold: hold, isNewLoad: true)
        }
    }

    // MARK: - Budget

    /// The RAM budget for this machine, measured from a fresh probe read.
    ///
    /// The reads are cheap, so each resolve takes them again rather than
    /// remember an earlier answer. A value the OS changes — the GPU working set
    /// after an OS update — therefore reaches the very next budget.
    private func hostBudget() -> Int64 {
        HostProfile(probe: probe).budget()
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
    /// A candidate whose ``ModelPoolKey`` is in `residentKeys` is charged its
    /// marginal cost: one session KV cache at `context` for a generation
    /// model, whatever context it was first loaded at, and zero for an
    /// embedder.
    private static func footprintBytes(
        for ref: ModelRef,
        context: Int,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        membership: [ModelRef: Set<ModelSlot>],
        residentKeys: Set<ModelPoolKey>
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
                let key = ModelPoolKey(ref: ref, role: .embedding)
                let raw = Footprint.embedder(weightBytes: metadata.weightBytes).footprint(context: context)
                candidates.append(residentKeys.contains(key) ? 0 : raw)
            }
            if slots.contains(.standard) || slots.contains(.flash) {
                let key = ModelPoolKey(ref: ref, role: .llm)
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

    /// The raw KV cache estimate of one session of the candidate a slot
    /// chose at `context`: the share its hold adds on the pooled container,
    /// and what the hold's release gives back. An embedder carries no KV
    /// cache, so the embedding slot adds zero.
    ///
    /// Traps when a generation candidate has no metadata, because
    /// ``JointFit`` chooses a candidate only after it sized it.
    ///
    /// - Parameters:
    ///   - slot: The slot that chose the candidate.
    ///   - ref: The chosen candidate.
    ///   - context: The working context its sessions decode at.
    ///   - metadataByRef: The sizing metadata fetched for every candidate.
    /// - Returns: The raw KV cache bytes.
    private static func chosenSessionBytes(
        of slot: ModelSlot,
        chosen ref: ModelRef,
        context: Int,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>]
    ) -> Int64 {
        guard slot.poolRole == .llm else { return 0 }
        switch sessionBytes(for: ref, context: context, metadataByRef: metadataByRef) {
        case .success(let cacheBytes):
            return cacheBytes
        case .failure:
            preconditionFailure("JointFit sizes every candidate it chooses; \(ref.stringValue) has no metadata")
        }
    }

    // MARK: - Joint fit

    /// Throws before any sizing or load when `def` names only one model for
    /// both the `standard` slot and the `flash` slot, and records the failure
    /// into the progress. The standard and flash slots never use the same
    /// model; see ``SameGenerationModelFailure``.
    ///
    /// - Throws: ``SameGenerationModelFailure`` when
    ///   ``ProfileDefinition/sharedGenerationModel`` is not `nil`.
    private func rejectSharedGenerationModel(
        profile def: ProfileDefinition,
        progress: ResolutionProgress
    ) async throws {
        guard let model = def.sharedGenerationModel else { return }
        let failure = SameGenerationModelFailure(profileName: def.name, model: model)
        await recordFailure(
            outcomes: [(.flash, nil)],
            failedReason: "the standard slot already uses the only flash candidate",
            description: failure.description,
            progress: progress
        )
        throw failure
    }

    /// Runs the pure joint fit and, on failure, records the diagnostics into the
    /// progress before rethrowing.
    private func runJointFit(
        profile def: ProfileDefinition,
        budget: Int64,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        residentKeys: Set<ModelPoolKey>,
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
            await recordFailure(
                outcomes: failure.slots.map { ($0.slot, $0.chosen) },
                failedReason: "no candidate fit the remaining budget",
                description: failure.description,
                progress: progress
            )
            throw failure
        } catch let failure as NoWindowFailure {
            await recordFailure(
                outcomes: [(.standard, nil)],
                failedReason: "no candidate window could be read",
                description: failure.description,
                progress: progress
            )
            throw failure
        }
    }

    // MARK: - Download & load

    /// Opens one load span and runs `body` — the fetch and load of one slot's
    /// model — inside it.
    ///
    /// The caller is ``acquire(slot:resolution:metadataByRef:admission:progress:)``,
    /// for a model the pool does not hold, so only a model this resolve really
    /// fetches opens a span here. The span is a child of the resolve span,
    /// because the admission job carries the service context of the resolve
    /// span. `withSpan` records a thrown error on the span and raises it
    /// again.
    ///
    /// A load that ends also records its duration
    /// (``RouterMetrics/recordLoad(duration:model:slot:)``), through the
    /// metrics factory that the resolve bound around its admission job. A
    /// load that throws records no duration.
    ///
    /// - Parameters:
    ///   - chosen: The model reference being loaded.
    ///   - slot: The slot the model fills.
    ///   - footprintBytes: The chosen candidate's whole raw footprint estimate.
    ///   - body: The load work the span measures.
    /// - Returns: Whatever `body` produced.
    /// - Throws: Whatever `body` throws.
    private func withLoadSpan<Loaded>(
        chosen: ModelRef,
        slot: ModelSlot,
        footprintBytes: Int64,
        _ body: () async throws -> Loaded
    ) async throws -> Loaded {
        try await RouterTelemetry.tracer(explicit: tracer)
            .withSpan(RouterTelemetry.SpanName.load, ofKind: .client) { span in
                span.attributes[RouterTelemetry.AttributeKey.modelRef] = chosen.stringValue
                span.attributes[RouterTelemetry.AttributeKey.slot] = slot.rawValue
                span.attributes[RouterTelemetry.AttributeKey.footprintBytes] = footprintBytes
                let startedAt = ContinuousClock.now
                let loaded = try await body()
                RouterMetrics().recordLoad(duration: startedAt.duration(to: .now), model: chosen, slot: slot)
                return loaded
            }
    }

    /// Preloads the container of a hold this resolve loaded, and marks its
    /// slot ready.
    ///
    /// This router's loader loaded the container, so it is a
    /// ``LoadedModelContainer`` of that loader.
    ///
    /// - Parameters:
    ///   - slot: The slot of the hold.
    ///   - hold: A hold whose model this resolve loaded.
    ///   - progress: The progress to drive.
    /// - Throws: What the preload throws.
    private func finalize(slot: ModelSlot, hold: ModelHold, progress: ResolutionProgress) async throws {
        guard let container = hold.container as? any LoadedModelContainer else {
            preconditionFailure("the router's loader loaded the container of \(hold.key.ref.stringValue)")
        }
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

    /// Assembles the resolved profile from the containers and the holds the
    /// admission job gave back, and the per-slot resolutions, stamping each
    /// handle with the router's id and recorder.
    ///
    /// Each handle keeps all three holds. The profile holds the handles, so
    /// the residency lives exactly as long as the last of the four objects,
    /// and a tool that keeps only a handle keeps its models resident.
    ///
    /// - Parameters:
    ///   - def: The authored profile this resolve applied.
    ///   - admitted: What the admission job of this resolve gave back.
    /// - Returns: The resolved profile.
    private func buildProfile(definition def: ProfileDefinition, admitted: AdmittedResolve) -> LanguageModelProfile {
        let resolution = admitted.resolution
        let resolvedProfile = SessionSidecar.ResolvedProfile(
            definitionName: def.name,
            standard: resolution.standard,
            flash: resolution.flash,
            embedding: resolution.embedding,
            context: Self.slotResolution(for: resolution, slot: .standard).contextTokens
        )
        return LanguageModelProfile(
            definitionName: def.name,
            standard: makeRoutedModel(
                slot: .standard, container: admitted.standard, admitted: admitted, resolvedProfile: resolvedProfile),
            flash: makeRoutedModel(
                slot: .flash, container: admitted.flash, admitted: admitted, resolvedProfile: resolvedProfile),
            embedding: makeRoutedModel(
                slot: .embedding, container: admitted.embedding, admitted: admitted, resolvedProfile: resolvedProfile)
        )
    }

    /// Builds a routed model handle for `slot` over `container`, with this
    /// router's id, recorder, tracer, sampling mode, and transcripts root.
    ///
    /// - Parameters:
    ///   - slot: The slot this handle fills.
    ///   - container: The container of the slot.
    ///   - admitted: What the admission job of this resolve gave back: the
    ///     joint fit, and the holds this handle keeps its models resident with.
    ///   - resolvedProfile: The run's resolved-profile facts for root session sidecars.
    /// - Returns: The routed model handle.
    private func makeRoutedModel<Container: Sendable>(
        slot: ModelSlot,
        container: Container,
        admitted: AdmittedResolve,
        resolvedProfile: SessionSidecar.ResolvedProfile
    ) -> RoutedModel<Container> {
        let chosen = Self.chosenRef(of: slot, in: admitted.resolution)
        let resolution = Self.slotResolution(for: admitted.resolution, slot: slot)
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
            tracer: tracer,
            samplingMode: samplingMode,
            residencyHolds: admitted.holds
        )
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

    /// The model a slot chose in a joint resolution.
    ///
    /// - Parameters:
    ///   - slot: The slot.
    ///   - resolution: The joint resolution.
    /// - Returns: The chosen model reference of `slot`.
    private static func chosenRef(of slot: ModelSlot, in resolution: JointResolution) -> ModelRef {
        switch slot {
        case .standard: resolution.standard
        case .flash: resolution.flash
        case .embedding: resolution.embedding
        }
    }

    /// The report ``JointFit`` recorded for the candidate a slot chose, or
    /// `nil` when the slot recorded none.
    private static func chosenReport(for slotRes: SlotResolution) -> CandidateReport? {
        slotRes.considered.first { $0.verdict == .chosen }
    }

    /// The chosen candidate's raw footprint estimate for a slot, or `0`.
    private static func chosenFootprint(for slotRes: SlotResolution) -> Int64 {
        chosenReport(for: slotRes)?.estimatedFootprintBytes ?? 0
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
    ///
    /// - Parameters:
    ///   - outcomes: Each slot the failure reports, with the model it chose, or `nil` when it chose none.
    ///   - failedReason: The failed state of a slot that chose no model.
    ///   - description: The diagnostic description of the failure.
    private func recordFailure(
        outcomes: [(slot: ModelSlot, chosen: ModelRef?)],
        failedReason: String,
        description: String,
        progress: ResolutionProgress
    ) async {
        await MainActor.run {
            for outcome in outcomes {
                var sp = progress.slots[outcome.slot] ?? SlotProgress()
                sp.chosen = outcome.chosen
                sp.state = outcome.chosen == nil ? .failed(failedReason) : .sizing
                progress.slots[outcome.slot] = sp
            }
            progress.phase = .failed(description)
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

    /// Records a cancelled resolution into the progress: the phase says the
    /// caller stopped it, and the slots keep the states they had reached, so a
    /// host can still show how far the attempt got.
    private func recordCancellation(progress: ResolutionProgress) async {
        await MainActor.run {
            progress.phase = .cancelled
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
