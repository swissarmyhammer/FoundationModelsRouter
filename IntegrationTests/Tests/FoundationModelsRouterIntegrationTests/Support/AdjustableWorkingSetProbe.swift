import FoundationModelsRouter
import Synchronization

/// A ``MachineProbe`` whose recommended working set the test sets. It starts
/// at the working set of the host.
///
/// The suites that size the prompt-cache budget of a router use it:
/// `PromptCacheBudgetIntegrationTests` and
/// `ForkPromptCacheCopyIntegrationTests`.
final class AdjustableWorkingSetProbe: MachineProbe {
    /// The live probe that gives the chip and the physical RAM.
    private let live = SystemMachineProbe()

    /// The working set this probe reports.
    private let workingSet: Mutex<Int64>

    /// Makes a probe that reports the working set of the host.
    init() {
        workingSet = Mutex(live.recommendedMaxWorkingSetSize)
    }

    var chip: String { live.chip }

    var totalRAM: Int64 { live.totalRAM }

    var recommendedMaxWorkingSetSize: Int64 { workingSet.withLock { $0 } }

    /// Sets the working set the next reads report.
    ///
    /// - Parameter bytes: The working set, in bytes.
    func setWorkingSet(_ bytes: Int64) {
        workingSet.withLock { $0 = bytes }
    }
}
