import Foundation
import Testing

@testable import FoundationModelsRouter

@Suite("HostProfile")
struct HostProfileTests {
    /// One gigabyte in bytes — the unit the budget arithmetic works in.
    private static let gb: Int64 = 1 << 30

    /// Budget specs `(totalRAM, recommended, reserve, expected)` in bytes.
    ///
    /// The first two cases let the recommended working set limit the budget; the
    /// last two cross the boundary where `totalRAM - reserve < recommended`, so
    /// the RAM headroom limits it instead.
    private static let budgetCases: [(totalRAM: Int64, recommended: Int64, reserve: Int64, expected: Int64)] = [
        (128 * gb, 96 * gb, 4 * gb, 96 * gb),
        (32 * gb, 24 * gb, 4 * gb, 24 * gb),
        (16 * gb, 12 * gb, 8 * gb, 8 * gb),
        (8 * gb, 6 * gb, 4 * gb, 4 * gb),
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
        #expect(profile.totalRAM == probe.totalRAM)
        #expect(profile.recommendedMaxWorkingSetSize == probe.recommendedMaxWorkingSetSize)
    }

    @Test("HostProfile(probe:) copies the probed chip, RAM, and working set")
    func profileFromProbe() {
        let probe = StubMachineProbe(
            chip: "Apple M3 Max",
            totalRAM: 128 * Self.gb,
            recommendedMaxWorkingSetSize: 96 * Self.gb
        )

        let profile = HostProfile(probe: probe)

        #expect(profile.chip == "Apple M3 Max")
        #expect(profile.totalRAM == 128 * Self.gb)
        #expect(profile.recommendedMaxWorkingSetSize == 96 * Self.gb)
    }

    @Test(
        "budget = min(recommended, totalRAM - reserve)",
        arguments: HostProfileTests.budgetCases
    )
    func budget(spec: (totalRAM: Int64, recommended: Int64, reserve: Int64, expected: Int64)) {
        let (totalRAM, recommended, reserve, expected) = spec
        let profile = HostProfile(
            chip: "Apple M2",
            totalRAM: totalRAM,
            recommendedMaxWorkingSetSize: recommended
        )

        #expect(profile.budget(headroomReserve: reserve) == expected)
    }

    @Test("HostProfile Codable round-trips chip, RAM, and working set")
    func codableRoundTrip() throws {
        let profile = HostProfile(
            chip: "Apple M4 Max",
            totalRAM: 128 * Self.gb,
            recommendedMaxWorkingSetSize: 96 * Self.gb
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)

        #expect(decoded == profile)
    }
}
