import Foundation
import Metal

/// The OS/hardware reads behind a `HostProfile`, abstracted so the profiling and
/// budget logic stays pure and testable with injected values.
///
/// The live implementation is ``SystemMachineProbe``; tests supply a stub
/// returning fixed numbers. Each property mirrors one field of ``HostProfile``.
public protocol MachineProbe: Sendable {
    /// The chip / machine identifier, e.g. `"Apple M3 Max"`.
    var chip: String { get }

    /// Total physical RAM in bytes (`ProcessInfo.physicalMemory`, ≡ sysctl
    /// `hw.memsize`).
    var totalRAM: Int64 { get }

    /// The GPU working set the system is willing to back, in bytes
    /// (`MTLDevice.recommendedMaxWorkingSetSize`).
    var recommendedMaxWorkingSetSize: Int64 { get }
}

/// A one-time measurement of the host machine, used to compute the RAM budget a
/// resolved profile must fit within.
///
/// The profile is measured once at startup and cached to disk keyed by
/// `(chip, totalRAM)` (see ``HostProfileCache``). Every value is a byte count;
/// the type is pure data — `Sendable` and `Codable` — with no dependency on the
/// hardware it describes, so it serializes and round-trips cleanly.
public struct HostProfile: Sendable, Codable, Equatable {
    /// The chip / machine identifier, e.g. `"Apple M3 Max"`.
    public let chip: String

    /// Total physical RAM in bytes.
    public let totalRAM: Int64

    /// The GPU working set the system is willing to back, in bytes
    /// (≈ 70–75% of RAM on Apple Silicon).
    public let recommendedMaxWorkingSetSize: Int64

    /// Creates a host profile from explicit measurements.
    ///
    /// - Parameters:
    ///   - chip: The chip / machine identifier.
    ///   - totalRAM: Total physical RAM in bytes.
    ///   - recommendedMaxWorkingSetSize: The GPU working set in bytes.
    public init(chip: String, totalRAM: Int64, recommendedMaxWorkingSetSize: Int64) {
        self.chip = chip
        self.totalRAM = totalRAM
        self.recommendedMaxWorkingSetSize = recommendedMaxWorkingSetSize
    }

    /// Measures a host profile by reading the supplied probe.
    ///
    /// - Parameter probe: The machine probe to read; pass ``SystemMachineProbe``
    ///   for a live measurement or a stub for tests.
    public init(probe: MachineProbe) {
        self.init(
            chip: probe.chip,
            totalRAM: probe.totalRAM,
            recommendedMaxWorkingSetSize: probe.recommendedMaxWorkingSetSize
        )
    }

    /// The RAM budget a resolved profile's resident models must fit within.
    ///
    /// The budget is the smaller of what the GPU is willing to back and what
    /// remains of physical RAM after holding out fixed OS/app slack:
    /// `min(recommendedMaxWorkingSetSize, totalRAM - headroomReserve)`.
    ///
    /// - Parameter headroomReserve: Fixed slack in bytes held out of the budget.
    /// - Returns: The usable budget in bytes.
    public func budget(headroomReserve: Int64) -> Int64 {
        min(recommendedMaxWorkingSetSize, totalRAM - headroomReserve)
    }
}

/// The live ``MachineProbe`` that reads the host hardware.
///
/// Reads physical RAM from `ProcessInfo`, the recommended GPU working set from
/// the system default Metal device, and the chip identifier from `sysctl`
/// (`machdep.cpu.brand_string`, falling back to `hw.model`).
public struct SystemMachineProbe: MachineProbe {
    /// Creates a probe that reads the current host on each access.
    public init() {}

    /// The chip identifier from `machdep.cpu.brand_string`, or `hw.model` when
    /// the brand string is unavailable (e.g. on Apple Silicon).
    public var chip: String {
        Self.sysctlString("machdep.cpu.brand_string")
            ?? Self.sysctlString("hw.model")
            ?? "unknown"
    }

    /// Total physical RAM in bytes from `ProcessInfo.physicalMemory`.
    public var totalRAM: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// The recommended GPU working set in bytes from the system default Metal
    /// device, or `0` when no Metal device is available.
    public var recommendedMaxWorkingSetSize: Int64 {
        guard let device = MTLCreateSystemDefaultDevice() else { return 0 }
        return Int64(device.recommendedMaxWorkingSetSize)
    }

    /// Reads a string-valued `sysctl` by name.
    ///
    /// - Parameter name: The sysctl name, e.g. `"hw.model"`.
    /// - Returns: The value, or `nil` when the name is unknown or empty.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
