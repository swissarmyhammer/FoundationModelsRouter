import CryptoKit
import Foundation

/// A disposable on-disk cache of ``HostProfile`` measurements, keyed by
/// `(chip, totalRAM)`.
///
/// The host is measured once and stored as JSON under a configured cache
/// directory so subsequent runs skip re-probing. Each `(chip, totalRAM)` pair
/// maps to its own file, so distinct machines never collide. The cache is
/// disposable — deleting it only forces a re-measurement, never data loss — and
/// is separate from the recordings directory.
public struct HostProfileCache: Sendable {
    /// The directory under which profile JSON files are written.
    public let cacheDir: URL

    /// Creates a cache rooted at the given directory.
    ///
    /// The directory is created on demand when a profile is saved; it need not
    /// exist yet.
    ///
    /// - Parameter cacheDir: The disposable directory to read and write under.
    public init(cacheDir: URL) {
        self.cacheDir = cacheDir
    }

    /// Loads the cached profile for a machine, if present.
    ///
    /// - Parameters:
    ///   - chip: The chip identifier of the machine.
    ///   - totalRAM: The total physical RAM in bytes of the machine.
    /// - Returns: The cached profile, or `nil` when nothing is cached for the key.
    /// - Throws: If a cached file exists but cannot be read or decoded.
    public func load(chip: String, totalRAM: Int64) throws -> HostProfile? {
        let url = fileURL(chip: chip, totalRAM: totalRAM)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(HostProfile.self, from: data)
    }

    /// Saves a profile under its `(chip, totalRAM)` key, creating the cache
    /// directory if needed and overwriting any existing entry for the key.
    ///
    /// - Parameter profile: The profile to persist.
    /// - Throws: If the directory cannot be created or the file cannot be written.
    public func save(_ profile: HostProfile) throws {
        try FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )
        let url = fileURL(chip: profile.chip, totalRAM: profile.totalRAM)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }

    /// The file URL for a given cache key.
    ///
    /// The key components are hashed into a collision-resistant filename so
    /// arbitrary chip strings stay filesystem-safe and distinct keys map to
    /// distinct files.
    private func fileURL(chip: String, totalRAM: Int64) -> URL {
        let key = "\(chip)\u{0}\(totalRAM)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("host-profile-\(hex).json", isDirectory: false)
    }
}
