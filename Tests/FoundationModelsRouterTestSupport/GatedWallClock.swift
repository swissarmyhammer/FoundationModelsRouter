import Foundation

/// The wall clock a gated real-model step took, printed however that step
/// ended.
///
/// Task ^k0d30s4 gives every integration test a budget of two minutes and asks
/// each one to print its own measurement, so a regression against that budget
/// is visible without a stopwatch. Both gated test targets state a budget, both
/// hold their tests to it with `.timeLimit`, and both print the measurement
/// from ``GatedRealModelSuiteTrait``, the suite-scoped trait every gated suite
/// carries.
///
/// The measuring itself stands here, in one place, so no caller can drift into
/// printing the same measurement in a second shape — a grep for one tag
/// collects a whole run either way.
///
/// This module is where it can stand. `swift test` builds one `.xctest` for
/// each test target, and SwiftPM cannot share source between two test targets;
/// ``GatedRealModelBudget`` and ``MetalLibraryTestBootstrap`` are here for the
/// same reason.
public enum GatedWallClock {
    /// The format one measurement is printed in — one decimal place of
    /// seconds.
    ///
    /// A gated step costs seconds, not milliseconds, and a reader comparing a
    /// run against a budget stated in whole minutes needs no more precision
    /// than this.
    private static let secondsFormat = "%.1f"

    /// Runs `work`, then prints how long it took.
    ///
    /// The measurement is printed on the success path and on the throwing path
    /// alike, so a step that failed — or that its own time limit cancelled —
    /// still states what it cost. That is the case the budget most needs a
    /// number for.
    ///
    /// - Parameters:
    ///   - label: The tag the printed line opens with, in brackets. One tag for
    ///     each target, so a grep collects that target's whole run.
    ///   - subject: What was measured, as a `key=value` pair — the suite or the
    ///     test the step belongs to.
    ///   - work: The step itself.
    /// - Returns: Whatever `work` returns.
    /// - Throws: Whatever `work` throws, rethrown once the measurement is
    ///   printed.
    public static func printing<T>(
        label: String,
        subject: String,
        performing work: () async throws -> T
    ) async rethrows -> T {
        let startedAt = Date()
        defer {
            let seconds = Date().timeIntervalSince(startedAt)
            print(
                "[\(label)] \(subject) "
                    + "wallClockSeconds=\(String(format: secondsFormat, seconds))")
        }
        return try await work()
    }
}
