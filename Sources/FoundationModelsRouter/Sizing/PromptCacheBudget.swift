/// The bytes that a prompt cache holds at one time.
///
/// The fork keeps one KV prompt cache for each session. An entry is in one of
/// three states: in memory, spilling (its write to disk has not ended), or on
/// disk. A spilling entry stays in memory until its write ends.
public struct PromptCacheUsage: Sendable, Equatable {
    /// The bytes of the entries in memory.
    public let memoryBytes: Int

    /// The bytes of the entries whose write to disk has not ended. These bytes
    /// are still in memory.
    public let spillingBytes: Int

    /// The bytes of the spill files on disk.
    public let diskBytes: Int

    /// A usage with no entry in memory, none spilling and none on disk.
    public static let zero = PromptCacheUsage(memoryBytes: 0, spillingBytes: 0, diskBytes: 0)

    /// Makes a usage from the three byte totals.
    ///
    /// - Parameters:
    ///   - memoryBytes: The bytes of the entries in memory.
    ///   - spillingBytes: The bytes of the entries whose write to disk has not
    ///     ended.
    ///   - diskBytes: The bytes of the spill files on disk.
    public init(memoryBytes: Int, spillingBytes: Int, diskBytes: Int) {
        self.memoryBytes = memoryBytes
        self.spillingBytes = spillingBytes
        self.diskBytes = diskBytes
    }

    /// The prompt-cache bytes in memory now: the entries in memory plus the
    /// entries that are being written to disk.
    public var residentBytes: Int { memoryBytes + spillingBytes }
}

/// The prompt cache a pool entry sizes, and the working set it sizes against.
///
/// The pool keeps one on each entry. An unload has no router on the stack (a
/// dropped ``ResidencyHold`` starts it), so the entry must carry the target
/// and the working set of the resolve that loaded it.
package struct PromptCacheSizing: Sendable {
    /// The loader whose prompt cache gets the budget.
    let loader: any ModelLoader

    /// The recommended working set, in bytes, that the resolve measured.
    let workingSetBytes: Int64
}

/// The memory budget of the prompt cache (`generation-queue.md`, section 3).
///
/// ## The budget
///
/// The budget is the recommended working set less the footprint of each
/// resident pool entry, and less the prompt-cache bytes that are being written
/// to disk. The footprint of an entry is its weights plus one KV estimate for
/// each slot hold, not for each session: many sessions share one hold, so no
/// session is counted two times.
///
/// The fork limits only the entries in memory with this budget. An entry that
/// is being written to disk is still in memory, and the fork has one serial
/// writer, so the spilling bytes can stay high for some time. The resident
/// prompt-cache memory is thus the bytes in memory plus the spilling bytes, and
/// the budget holds the spilling bytes out. The value is conservative: when the
/// writes end, the budget stays that much smaller until the next change of the
/// resident footprint sends it again.
///
/// ## Why the whole remainder
///
/// The Router gives the prompt cache all the memory that the resident models
/// do not use, and keeps no further reserve. The measurements of fork task
/// ^mre55m3 show that a write to disk and a read back cost much less than the
/// prefill they save (for Qwen3-4B-4bit at 32k tokens: a 13.1 s prefill, and a
/// 1.19 s write plus a 0.16 s read). A spill is thus better than a drop, and a
/// small budget would not save the prefill cost. But a small budget makes more
/// spills, and each spill stalls the other models, so the budget is as large as
/// the footprints permit.
///
/// ## The `evalLock` stall
///
/// A spill write holds the process-wide `evalLock` of MLX for the whole write.
/// While it runs, the evaluation of EVERY model stops, not only the evaluation
/// of the model that owns the entry. The longest holds measured: 1.19 s for a
/// 32k entry of Qwen3-4B-4bit (4.8 GB), 0.22 s for a 32k entry of
/// Qwen3.8-27B-mxfp4 (2.3 GB), 0.12 s and 0.05 s at 4k. A load that makes the
/// budget smaller can spill many entries, and the serial writer then stalls the
/// other models for the sum of their writes.
///
/// ## More than one pool
///
/// The prompt cache of the fork is one store for the whole process, but each
/// ``ModelPool`` sends a budget that counts only its own resident entries. The
/// budgets do not add: the last pool that sends a budget sets it. A second pool
/// is an isolated budget on purpose (`model-pool.md`, section 5), and it already
/// prices its models against the whole working set. A process that has resident
/// models in two pools can thus hold more than the working set, in weights and
/// in prompt cache. One pool for each process, ``ModelPool/shared``, is the
/// configuration this budget is correct for.
enum PromptCacheBudget {
    /// The most bytes the prompt-cache entries in memory may hold.
    ///
    /// - Parameters:
    ///   - workingSetBytes: The recommended working set of the host.
    ///   - residentFootprints: The footprint of each resident pool entry.
    ///   - usage: The prompt-cache usage now.
    /// - Returns: The memory budget, in bytes.
    static func memoryBudgetBytes(
        workingSetBytes: Int64, residentFootprints: [Int64], usage: PromptCacheUsage
    ) -> Int {
        let residentCacheCeiling = workingSetBytes - residentFootprints.reduce(0, +)
        let budget = residentCacheCeiling - Int64(usage.spillingBytes)
        return Int(clamping: max(0, budget))
    }
}
