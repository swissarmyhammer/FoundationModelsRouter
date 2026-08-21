import MLX
import Testing

/// The wall-clock ceiling this suite runs under.
///
/// One minute rather than the shared ``integrationTestBudgetMinutes`` the
/// model-loading suites take: this suite adds four integers and downloads
/// nothing. The three runs of 2026-08-20 measured it at 0.001, then 0.001,
/// then 0.0 seconds; see ``integrationTestBudgetMinutes`` for the whole
/// three-run table.
private let metalLibraryBootstrapTimeLimitMinutes = 1

/// The first operand in the run the probe below adds on the GPU.
///
/// The values themselves carry no meaning. Evaluating *any* GPU-device
/// `MLXArray` is what aborts the process when the metallib symlink is missing,
/// so the cheapest arithmetic there is makes the point at no cost.
private let metalLibraryProbeFirstOperand: Int32 = 1

/// The last operand in the run the probe below adds on the GPU.
///
/// The run holds four operands rather than one so that its sum differs from
/// every operand in it: a `sum` that returned one of its own terms would still
/// fail the expectation.
private let metalLibraryProbeLastOperand: Int32 = 4

/// The operands the probe below adds on the GPU.
private let metalLibraryProbeOperands: [Int32] = Array(
    metalLibraryProbeFirstOperand...metalLibraryProbeLastOperand
)

// MARK: - Suite

/// The demonstration that ``GatedRealModelSuiteTrait`` really is what installs
/// the metallib symlink — not the discipline of the test bodies (task
/// d48rmth).
///
/// Every other gated `@Test` in this target used to open by reading
/// `GatedSuiteSerialGate.shared`, whose initializer ran
/// ``MetalLibraryTestBootstrap``. Twenty bodies all remembered to; nothing
/// enforced it, and a body that forgot did not fail an assertion — mlx-swift
/// cannot find its shader library under a plain `swift test` until the symlink
/// exists, so the first GPU-device `MLXArray` evaluation aborted the whole test
/// process with "Failed to load the default metallib", taking every other
/// suite's results with it.
///
/// This suite is that forgetful test, written on purpose. Its body touches no
/// gate, no bootstrap, and no router type at all; it evaluates a GPU-device
/// `MLXArray` and nothing else. The only thing standing between it and the
/// abort is the `.exclusiveRealModel` trait on the `@Suite` line, so the suite
/// passing is the proof that the trait, on its own, is enough — and the suite
/// aborting the process is how a regression that removes the trait announces
/// itself.
///
/// Deliberately not a hermetic (ungated) suite: it needs a Metal device, which
/// is exactly what the gate exists to keep this target off of.
@Suite(
    "Gated coverage: a gated @Test with no per-test gate line reaches the GPU safely (task d48rmth)",
    .serialized,
    .timeLimit(.minutes(metalLibraryBootstrapTimeLimitMinutes)),
    .exclusiveRealModel
)
struct MetalLibraryBootstrapIntegrationTests {
    @Test("a GPU-device MLXArray evaluation completes with no per-test bootstrap call")
    func gpuEvaluationSucceedsWithoutAPerTestGateLine() {
        let total = MLXArray(metalLibraryProbeOperands).sum(stream: .gpu)
        #expect(total.item(Int32.self) == metalLibraryProbeOperands.reduce(0, +))
    }
}
