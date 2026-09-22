import Foundation
import Synchronization

/// The exact identity of a resident model artifact.
///
/// Two candidates share a pool entry only when both the ``ModelRef`` and the
/// ``Role`` match. The working context is not part of the key: a loader does
/// not size a container by it, and the KV cache is allocated and priced per
/// session. One model at two contexts is one resident container.
package struct ResidencyKey: Hashable, Sendable {
    /// The role a resident model was loaded under.
    package enum Role: Hashable, Sendable {
        /// Loaded as a generation model: weights, and one KV cache for each session.
        case llm
        /// Loaded as an embedder: weights only.
        case embedding
    }

    /// The model reference (repo + optional pinned revision).
    // Never read by name: both stored properties are consumed only through the
    // synthesized `Hashable`/`Equatable` conformance, which is exactly what
    // makes this a pool key. Deleting either would collapse every distinct
    // model (or role) onto one entry of the pool.
    // periphery:ignore
    let ref: ModelRef

    /// The role this instance was loaded under.
    // periphery:ignore
    let role: Role
}

/// A pool entry's loaded container, by container protocol.
package enum PooledContainer: Sendable {
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

/// One resident model in the pool, reference-counted across every slot
/// acquisition that holds it. Every ``RoutedModel`` built over this entry
/// shares its ``ResidentModelGates``.
package struct PoolEntry: Sendable {
    /// How many slot acquisitions currently hold this model.
    var refcount: Int

    /// This model's `× 1.2` margined weights alone: the first load's margined
    /// footprint less that load's own margined KV cache at its context. The
    /// pool charges them one time, however many holds share the model.
    let baseWeightsBytes: Int64

    /// The sum of the `× 1.2` margined KV cache bytes every live hold adds on
    /// this model, each at its own context. Each release gives back its own
    /// hold's share. An embedder carries no KV cache, so this stays zero.
    var acquiredChargeBytes: Int64

    /// The steady-state bytes this entry holds against the shared budget:
    /// the weights one time, plus one KV cache for each live hold, whatever
    /// order the holds release in.
    var footprintBytes: Int64 { baseWeightsBytes + acquiredChargeBytes }

    /// The loaded container.
    let container: PooledContainer

    /// The gates every handle built over this entry reuses.
    let gates: ResidentModelGates

    /// Evicts ``container`` through the loader that loaded it. The pool calls
    /// it at zero references, whichever router releases last.
    let evict: @Sendable (any LoadedModelContainer) async -> Void

    /// Whether the acquisition that received this snapshot loaded the model:
    /// it is the only hold. Under the resolve lock no release can drop a
    /// hold, so an entry that was resident before has at least two holds
    /// after a bump.
    var isFirstHold: Bool { refcount == 1 }
}

/// One slot acquisition's charge on a pooled model: the pool key and the KV
/// cache bytes that acquisition added on the model. A release gives back
/// that share.
///
/// This is the pool's own bookkeeping, and not the caller-facing
/// ``ResidencyHold``, which is the reference-counted object whose last release
/// gives a whole residency back.
package struct SlotCharge: Sendable {
    /// The pooled model this charge references.
    let key: ResidencyKey

    /// The `× 1.2` margined KV cache bytes this charge adds on the pooled
    /// model at its own context, and what its release gives back. Zero for an
    /// embedder. The weights come back when the last charge releases and the
    /// model is evicted.
    let sessionBytes: Int64
}

/// The resident-model pool. One instance serves every router in a process,
/// so a model that two routers name is loaded one time and priced one time.
/// ``shared`` is that instance; a router names it when it is given no pool.
///
/// The first loader wins a key. The router that first loads a key makes the
/// container with its own loader and mints the entry's ``ResidentModelGates``.
/// A later router that names the same key gets that container and those
/// gates, whatever its own loader would have made.
///
/// Residency is reference-counted per ``ResidencyKey`` across every profile
/// that holds it. A resolve prices a resident candidate at its marginal cost
/// and acquires it later, so a whole resolve and a whole release each run
/// under ``withResolveLock(isolation:_:)``. The lock is process-wide: every
/// resolve on every router over one pool runs one at a time. The lock is
/// what stops two routers from loading one key two times.
///
/// A container is freed only when the last ``ResidencyHold`` on it is
/// deallocated. Residency follows ARC and not the router: a dropped ``Router``
/// frees nothing, and a profile or handle that is still referenced keeps its
/// models resident and charged. A host reads ``residentModelCount`` to see
/// what the process holds.
///
/// Every test router names a pool: pass a fresh ``init()`` result as the
/// `pool:` argument of ``Router``. Suites run in parallel, and a stub one
/// suite makes resident in ``shared`` would satisfy another suite's key.
public actor ModelPool {
    /// The pool every router uses when none is given.
    public static let shared = ModelPool()

    /// Serializes every resolve and every release in the process. It is
    /// `nonisolated` so a caller holds it across its own `await`s and gives
    /// it back in a `defer`, which an isolated method cannot do.
    private nonisolated let resolveLock = AsyncSemaphore(value: 1)

    /// The resident models, keyed by exact artifact identity.
    private var entries: [ResidencyKey: PoolEntry] = [:]

    /// The charges each resident profile was granted, by residency token.
    /// A drained release gives back each charge and forgets the token, so a
    /// token released twice is a no-op.
    private var residentProfiles: [ULID: [SlotCharge]] = [:]

    /// Residency tokens whose ``ResidencyHold`` was deallocated, waiting to be
    /// released.
    ///
    /// A hold's `deinit` runs on whatever thread dropped the last reference and
    /// cannot `await` the actor, so it appends the token here through
    /// ``enqueuePendingRelease(_:)`` instead. ``drainPendingReleases()`` empties
    /// the queue at the top of every resolve, before that resolve measures the
    /// host budget, so freed bytes are visible to the very first measurement
    /// rather than to a later, racing one. The queue — never the eager task
    /// that also drains it — is what makes a release certain.
    private nonisolated let pendingReleases = Mutex<[ULID]>([])

    /// Makes an empty pool. Tests make one per router for isolation.
    public init() {}

    /// How many models are resident in this pool. For a host that wants to
    /// know what a process holds at shutdown.
    public var residentModelCount: Int { entries.count }

    /// Runs `body` under the resolve-wide lock.
    ///
    /// The lock is fair: a caller with no permit suspends and resumes in
    /// arrival order. The permit is given back when `body` returns, throws,
    /// or is unwound by cancellation.
    ///
    /// - Parameters:
    ///   - isolation: The caller's actor isolation, which defaults to the
    ///     caller's own. `body` runs there, so a router's resolve stays on
    ///     the router.
    ///   - body: The work to run while holding the lock.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Rethrows any error `body` throws.
    package func withResolveLock<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await resolveLock.withPermit(isolation: isolation, body)
    }

    /// Runs `body` under the resolve-wide lock, and gives up the wait when the
    /// calling task is cancelled.
    ///
    /// A resolve queued behind another resolve holds nothing yet, so a caller
    /// the user cancels leaves the queue at once instead of waiting for a
    /// permit it no longer wants. See ``AsyncSemaphore/waitUnlessCancelled()``.
    ///
    /// - Parameters:
    ///   - isolation: The caller's actor isolation, which defaults to the
    ///     caller's own. `body` runs there.
    ///   - body: The work to run while holding the lock.
    /// - Returns: Whatever `body` returns.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   the lock is acquired, or any error `body` throws.
    package func withResolveLockUnlessCancelled<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async throws -> T {
        try await resolveLock.withPermitUnlessCancelled(isolation: isolation, body)
    }

    /// The sum of every resident model's footprint against the shared budget.
    package var residentFootprintBytes: Int64 {
        entries.values.reduce(Int64(0)) { $0 + $1.footprintBytes }
    }

    /// The keys of every resident model.
    package var residentKeys: Set<ResidencyKey> { Set(entries.keys) }

    /// Acquires the pooled model identified by `key`: bumps a resident
    /// entry's refcount, or loads a fresh entry through `load` and inserts
    /// it. Call it under ``withResolveLock(isolation:_:)``.
    ///
    /// - Parameters:
    ///   - key: This candidate's exact residency identity.
    ///   - footprintBytes: This slot's whole margined footprint: the weights
    ///     plus this hold's own KV cache. A fresh entry's weights are this
    ///     figure less `sessionBytes`.
    ///   - sessionBytes: The margined KV cache this hold adds at its own
    ///     context, and what its release gives back. Zero for an embedder.
    ///   - load: The loader call that produces a fresh resident container.
    ///     It is `@Sendable` because the pool, not the caller, runs it.
    ///   - evict: The loader call that frees the container at zero references.
    /// - Returns: The entry after this acquisition. Its ``PoolEntry/isFirstHold``
    ///   tells whether this call loaded it.
    /// - Throws: Any error `load` raises.
    package func acquire(
        key: ResidencyKey,
        footprintBytes: Int64,
        sessionBytes: Int64,
        load: @Sendable () async throws -> PooledContainer,
        evict: @escaping @Sendable (any LoadedModelContainer) async -> Void
    ) async throws -> PoolEntry {
        if var entry = entries[key] {
            entry.refcount += 1
            entry.acquiredChargeBytes += sessionBytes
            entries[key] = entry
            return entry
        }
        let entry = PoolEntry(
            refcount: 1,
            baseWeightsBytes: footprintBytes - sessionBytes,
            acquiredChargeBytes: sessionBytes,
            container: try await load(),
            gates: ResidentModelGates(),
            evict: evict
        )
        entries[key] = entry
        return entry
    }

    /// Records the charges a resolved profile was granted, by its residency
    /// token. The release of the profile's last ``ResidencyHold`` gives them
    /// back.
    ///
    /// - Parameters:
    ///   - token: The residency token minted for the profile.
    ///   - charges: One charge for each of the profile's slots.
    package func grant(token: ULID, charges: [SlotCharge]) {
        residentProfiles[token] = charges
    }

    /// Records that the ``ResidencyHold`` for `token` was deallocated, so its
    /// residency is given back.
    ///
    /// Synchronous and `nonisolated`, because a hold's `deinit` runs on
    /// whatever thread dropped the last reference and cannot `await` this
    /// actor. Queueing the token is what makes the release certain; the task
    /// started here only brings it forward, so a residency nothing resolves
    /// after is still freed promptly. The next resolve on any router over this
    /// pool drains the queue itself, and a token drained twice is a no-op.
    ///
    /// - Parameter token: The residency token of the deallocated hold.
    package nonisolated func enqueuePendingRelease(_ token: ULID) {
        pendingReleases.withLock { $0.append(token) }
        Task { await self.drainPendingReleasesTakingResolveLock() }
    }

    /// Drains the pending queue for a caller that holds no lock.
    private func drainPendingReleasesTakingResolveLock() async {
        await withResolveLock {
            await drainPendingReleases()
        }
    }

    /// Releases every residency queued by ``enqueuePendingRelease(_:)``. A
    /// pooled model that drops to zero references is evicted.
    ///
    /// The caller must already hold the resolve lock. A resolve calls it
    /// before it measures the host budget, so the freed bytes reach that
    /// measurement instead of racing it.
    package func drainPendingReleases() async {
        let tokens = pendingReleases.withLock { queued -> [ULID] in
            defer { queued.removeAll() }
            return queued
        }
        for token in tokens {
            guard let charges = residentProfiles.removeValue(forKey: token) else { continue }
            await release(charges: charges)
        }
    }

    /// Gives back every charge in `charges`, one pooled model at a time.
    ///
    /// The one place a set of charges is released, so a resolve that failed
    /// part way and a whole residency that ended give their bytes back the
    /// same way. Call it under ``withResolveLock(isolation:_:)``.
    ///
    /// - Parameter charges: The charges to give back.
    package func release(charges: [SlotCharge]) async {
        for charge in charges {
            await release(charge: charge)
        }
    }

    /// Gives back one charge: decrements the model's refcount, gives back the
    /// charge's KV cache share, and evicts the model at zero references. A
    /// no-op when the key is not resident.
    ///
    /// - Parameter charge: The charge to give back.
    private func release(charge: SlotCharge) async {
        guard var entry = entries[charge.key] else { return }
        entry.refcount -= 1
        entry.acquiredChargeBytes -= charge.sessionBytes
        if entry.refcount <= 0 {
            entries.removeValue(forKey: charge.key)
            await entry.evict(entry.container.erased)
        } else {
            entries[charge.key] = entry
        }
    }
}
