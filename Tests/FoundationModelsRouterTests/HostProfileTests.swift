import Foundation
import Testing

@testable import FoundationModelsRouter

@Suite("HostProfile")
struct HostProfileTests {
    /// One gigabyte in bytes — the unit the budget arithmetic works in.
    private static let gb: Int64 = 1 << 30

    /// Probe specs `(totalRAM, recommended)` in bytes.
    ///
    /// The total RAM changes from case to case, and in the last case it is
    /// only a little more than the working set. The budget is the working set
    /// in each case, so the total RAM has no effect on it.
    private static let budgetCases: [(totalRAM: Int64, recommended: Int64)] = [
        (128 * gb, 96 * gb),
        (32 * gb, 24 * gb),
        (16 * gb, 12 * gb),
        (8 * gb, 6 * gb),
        (6 * gb + 1, 6 * gb),
    ]

    /// A `MachineProbe` returning fixed, injected values so profiling logic is
    /// testable without reading the host hardware.
    private struct StubMachineProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    @Test("SystemMachineProbe reports positive total RAM")
    func systemMachineProbeReportsPositiveTotalRAM() {
        let probe = SystemMachineProbe()

        #expect(probe.totalRAM > 0)
    }

    @Test("SystemMachineProbe reports a non-empty chip identifier")
    func systemMachineProbeReportsNonEmptyChip() {
        let probe = SystemMachineProbe()

        #expect(!probe.chip.isEmpty)
    }

    @Test("SystemMachineProbe reports a non-negative recommended working set")
    func systemMachineProbeReportsNonNegativeWorkingSet() {
        let probe = SystemMachineProbe()

        #expect(probe.recommendedMaxWorkingSetSize >= 0)
    }

    @Test("HostProfile(probe: SystemMachineProbe()) matches the live probe's own values")
    func hostProfileFromSystemMachineProbeMatchesProbe() {
        let probe = SystemMachineProbe()

        let profile = HostProfile(probe: probe)

        #expect(profile.chip == probe.chip)
        #expect(profile.recommendedMaxWorkingSetSize == probe.recommendedMaxWorkingSetSize)
    }

    @Test("HostProfile(probe:) copies the probed chip and working set")
    func profileFromProbe() {
        let probe = StubMachineProbe(
            chip: "Apple M3 Max",
            totalRAM: 128 * Self.gb,
            recommendedMaxWorkingSetSize: 96 * Self.gb
        )

        let profile = HostProfile(probe: probe)

        #expect(profile.chip == "Apple M3 Max")
        #expect(profile.recommendedMaxWorkingSetSize == 96 * Self.gb)
    }

    @Test(
        "budget = recommendedMaxWorkingSetSize for any totalRAM",
        arguments: HostProfileTests.budgetCases
    )
    func budget(spec: (totalRAM: Int64, recommended: Int64)) {
        let (totalRAM, recommended) = spec
        let profile = HostProfile(
            probe: StubMachineProbe(
                chip: "Apple M2",
                totalRAM: totalRAM,
                recommendedMaxWorkingSetSize: recommended
            )
        )

        #expect(profile.budget() == recommended)
    }

    @Test("HostProfile Codable round-trips chip and working set")
    func codableRoundTrip() throws {
        let profile = HostProfile(
            chip: "Apple M4 Max",
            recommendedMaxWorkingSetSize: 96 * Self.gb
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)

        #expect(decoded == profile)
    }
}
