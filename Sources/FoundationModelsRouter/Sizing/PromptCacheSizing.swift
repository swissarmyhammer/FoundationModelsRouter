import FoundationModelsExtras
import Synchronization

/// Sends the prompt-cache budget of one router to the loader of that router,
/// for each change of the footprint of its ``ModelPool``.
///
/// ## The footprints task
///
/// Each router makes one sizing. The sizing starts one task that reads
/// ``ModelPool/footprints``: the current footprint first, then each change.
/// For each value, the task sends the budget of ``PromptCacheBudget`` to the
/// prompt cache of the loader. Thus a load that a different caller starts
/// (the registry, the multitool), a release of a hold and an eviction each
/// resize the prompt cache of the router. When the router is released, the
/// sizing is released and cancels the task, so the task ends and the pool
/// removes its stream.
///
/// A stream value is only the signal. Each resize reads the footprint of the
/// pool at the time it runs, and all the resizes of one sizing run one at a
/// time. Thus a late value can not send an old budget after a newer one.
///
/// ## The router's own loads: the strict order
///
/// Inside its admission job, the router calls
/// ``withBudget(adding:isolation:_:)`` for each acquire. The sizing sends a
/// budget less the bytes that the acquire adds (the whole footprint of a new
/// model, or the session of a new hold on a resident model), and only then
/// runs the acquire. Thus the prompt cache is small before the loader's
/// `load` starts. After the acquire, on success and on failure, the sizing
/// sends the budget of the footprint of the pool again. While the acquire
/// runs, the footprints task sends no budget, because the added bytes and the
/// `loadingBytes` of the same load would count two times. A release while
/// the router loads thus resizes when the acquire ends. For that time the
/// budget is smaller than necessary, which is safe.
///
/// ## Limit: a load by a different caller
///
/// The footprints stream does not wait for the router. For a load that a
/// different caller starts, the pool first publishes the `loadingBytes` of
/// the load, and then the loader's `load` starts. The resize comes when the
/// footprints task reads that value, so it can come a short time after the
/// load started. A load takes seconds, so the prompt cache holds more than
/// its budget only for that short time.
///
/// An eviction publishes its value when its job ends. The last release of a
/// key submits the eviction job from a detached task, so the resize for the
/// freed weights can come a short time after the release.
final class PromptCacheSizing: Sendable {
    /// The task that reads the footprints of the pool and resizes the prompt
    /// cache for each value. It ends when this sizing is released.
    let footprintsTask: Task<Void, Never>

    /// The resizes of this sizing, one at a time.
    private let resizer: PromptCacheResizer

    /// Makes a sizing, and starts its footprints task.
    ///
    /// - Parameters:
    ///   - pool: The pool whose footprint sets the budget.
    ///   - loader: The loader whose prompt cache gets the budget.
    ///   - probe: The machine probe that gives the working set for each
    ///     resize.
    init(pool: ModelPool, loader: any ModelLoader, probe: any MachineProbe) {
        let resizer = PromptCacheResizer(pool: pool, loader: loader, probe: probe)
        let footprints = pool.footprints
        self.resizer = resizer
        footprintsTask = Task {
            for await _ in footprints {
                await resizer.resizeForFootprintChange()
            }
        }
    }

    deinit {
        footprintsTask.cancel()
    }

    /// Runs `body`, an acquire of the router, with a budget less
    /// `addedBytes`: the budget goes to the loader before `body` runs, and
    /// the budget of the footprint of the pool goes to the loader after
    /// `body` ends or throws.
    ///
    /// - Parameters:
    ///   - addedBytes: The bytes that the acquire adds: the whole footprint
    ///     of a new model, or the session of a new hold.
    ///   - isolation: The actor isolation of the caller, where `body` runs.
    ///   - body: The acquire.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func withBudget<T>(
        adding addedBytes: Int64,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        await resizer.beginAcquire(adding: addedBytes)
        do {
            let result = try await body()
            await resizer.endAcquire()
            return result
        } catch {
            await resizer.endAcquire()
            throw error
        }
    }
}

/// The resizes of one ``PromptCacheSizing``. They run one at a time, and
/// each reads the footprint of the pool at the time it runs.
private final class PromptCacheResizer: Sendable {
    /// The pool whose footprint sets the budget.
    private let pool: ModelPool

    /// The loader whose prompt cache gets the budget.
    private let loader: any ModelLoader

    /// The machine probe that gives the working set.
    private let probe: any MachineProbe

    /// Lets one resize run at a time.
    private let gate = AsyncSemaphore(value: 1)

    /// Whether an acquire of the router runs now. Read and written only
    /// while the caller holds ``gate``.
    private let isAcquiring = Mutex(false)

    /// Makes a resizer.
    ///
    /// - Parameters:
    ///   - pool: The pool whose footprint sets the budget.
    ///   - loader: The loader whose prompt cache gets the budget.
    ///   - probe: The machine probe that gives the working set.
    init(pool: ModelPool, loader: any ModelLoader, probe: any MachineProbe) {
        self.pool = pool
        self.loader = loader
        self.probe = probe
    }

    /// Sends the budget of the footprint of the pool, unless an acquire of
    /// the router runs now. That acquire sends the budget when it ends.
    func resizeForFootprintChange() async {
        await gate.withPermit {
            guard !isAcquiring.withLock({ $0 }) else { return }
            await sendBudget(addedBytes: 0)
        }
    }

    /// Marks the start of an acquire of the router, and sends the budget
    /// less `addedBytes`.
    ///
    /// - Parameter addedBytes: The bytes that the acquire adds.
    func beginAcquire(adding addedBytes: Int64) async {
        await gate.withPermit {
            isAcquiring.withLock { $0 = true }
            await sendBudget(addedBytes: addedBytes)
        }
    }

    /// Marks the end of an acquire of the router, and sends the budget of
    /// the footprint of the pool.
    func endAcquire() async {
        await gate.withPermit {
            isAcquiring.withLock { $0 = false }
            await sendBudget(addedBytes: 0)
        }
    }

    /// Sends the budget of the footprint of the pool now, less `addedBytes`.
    ///
    /// - Parameter addedBytes: The bytes that an acquire is about to add.
    private func sendBudget(addedBytes: Int64) async {
        await PromptCacheBudget.resize(
            loader: loader, workingSetBytes: HostProfile(probe: probe).budget(), footprint: pool.footprint,
            addedBytes: addedBytes)
    }
}
