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

    @Test("a profile persists to and reloads from the cache dir unchanged")
    func cacheRoundTrip() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = HostProfileCache(cacheDir: dir)

        let profile = HostProfile(
            chip: "Apple M1 Pro",
            totalRAM: 32 * Self.gb,
            recommendedMaxWorkingSetSize: 21 * Self.gb
        )

        #expect(try cache.load(chip: profile.chip, totalRAM: profile.totalRAM) == nil)

        try cache.save(profile)
        let reloaded = try cache.load(chip: profile.chip, totalRAM: profile.totalRAM)

        #expect(reloaded == profile)
    }

    @Test("the cache key distinguishes different (chip, totalRAM) machines")
    func cacheKeySeparation() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = HostProfileCache(cacheDir: dir)

        let m1 = HostProfile(chip: "Apple M1", totalRAM: 16 * Self.gb, recommendedMaxWorkingSetSize: 11 * Self.gb)
        let m2 = HostProfile(chip: "Apple M2", totalRAM: 16 * Self.gb, recommendedMaxWorkingSetSize: 11 * Self.gb)
        let m1Big = HostProfile(chip: "Apple M1", totalRAM: 64 * Self.gb, recommendedMaxWorkingSetSize: 48 * Self.gb)

        try cache.save(m1)
        try cache.save(m2)
        try cache.save(m1Big)

        #expect(try cache.load(chip: "Apple M1", totalRAM: 16 * Self.gb) == m1)
        #expect(try cache.load(chip: "Apple M2", totalRAM: 16 * Self.gb) == m2)
        #expect(try cache.load(chip: "Apple M1", totalRAM: 64 * Self.gb) == m1Big)
    }

    /// Creates a unique temporary directory for cache tests.
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostProfileTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
