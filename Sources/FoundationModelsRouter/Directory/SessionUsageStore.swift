import Foundation

/// What a host remembers about one session (ROUTER-3): the pin, the last use
/// and the recording root. A ``SessionUsageStore`` keeps one for each session
/// id.
///
/// Each date is ISO 8601 text in UTC with milliseconds (the text of the
/// Extras `DateTime`), as every other date Router writes to disk. The
/// initializer rounds each date to the millisecond, so a usage reads back
/// from the disk equal to the usage that was written.
public struct SessionUsage: Sendable, Codable, Equatable {
    /// The time of the first pin, or `nil` when the session is not pinned. A
    /// second pin keeps the first time, so a list of the pinned sessions can
    /// show the first pin first.
    public var pinnedAt: Date?

    /// The time of the last use of the session, or `nil` when the session
    /// has no use yet.
    public var lastUsedAt: Date?

    /// The recording root of the session, or `nil` when the store does not
    /// know it.
    public var recordingRoot: URL?

    /// Makes a usage. Each date is stored rounded to the millisecond, the
    /// precision of the file.
    ///
    /// - Parameters:
    ///   - pinnedAt: The time of the first pin, or `nil` for no pin.
    ///   - lastUsedAt: The time of the last use, or `nil` for no use.
    ///   - recordingRoot: The recording root, or `nil` when it is not known.
    public init(pinnedAt: Date? = nil, lastUsedAt: Date? = nil, recordingRoot: URL? = nil) {
        self.pinnedAt = pinnedAt.map(MillisecondDate.rounded)
        self.lastUsedAt = lastUsedAt.map(MillisecondDate.rounded)
        self.recordingRoot = recordingRoot
    }

    /// Whether the session is pinned.
    public var isPinned: Bool {
        pinnedAt != nil
    }

    /// The keys of the encoded usage.
    private enum CodingKeys: String, CodingKey {
        case pinnedAt, lastUsedAt, recordingRoot
    }

    /// Decodes a usage. An absent key decodes as `nil`.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: A decoding error when a key holds the wrong type, or a date
    ///   is not ISO 8601 text in UTC with milliseconds.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinnedAt = try container.decodeMillisecondDateIfPresent(forKey: .pinnedAt)
        lastUsedAt = try container.decodeMillisecondDateIfPresent(forKey: .lastUsedAt)
        recordingRoot = try container.decodeIfPresent(URL.self, forKey: .recordingRoot)
    }

    /// Encodes the usage, each date as text with milliseconds. A `nil` value
    /// writes no key.
    ///
    /// - Parameter encoder: The encoder.
    /// - Throws: What the encoder throws.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pinnedAt.map(MillisecondDate.text), forKey: .pinnedAt)
        try container.encodeIfPresent(lastUsedAt.map(MillisecondDate.text), forKey: .lastUsedAt)
        try container.encodeIfPresent(recordingRoot, forKey: .recordingRoot)
    }
}

/// The store of the ``SessionUsage`` of each session (ROUTER-3).
///
/// The calls are synchronous, so that a caller that holds a lock, such as a
/// summary of ``RouterSessionDirectory``, can read the store. A store is
/// `Sendable`: each call is safe from each thread.
public protocol SessionUsageStore: Sendable {
    /// The usage of each session that the store keeps.
    ///
    /// - Returns: The usages, by session id.
    func usages() -> [ULID: SessionUsage]

    /// The usage of one session.
    ///
    /// - Parameter id: The id of the session.
    /// - Returns: The usage, or `nil` when the store keeps no usage for `id`.
    func usage(of id: ULID) -> SessionUsage?

    /// Pins or unpins a session.
    ///
    /// A pin of a pinned session keeps the time of the first pin. An unpin
    /// clears the pin. An unpin of a session that has no last use removes its
    /// usage.
    ///
    /// - Parameters:
    ///   - pinned: `true` to pin the session, `false` to unpin it.
    ///   - id: The id of the session.
    ///   - recordingRoot: The recording root of the session, or `nil` to keep
    ///     the recording root that the store holds.
    ///   - time: The time of the pin.
    /// - Returns: The usage of the session after the change.
    /// - Throws: The error of a write that fails. The store then stays as it
    ///   was.
    @discardableResult
    func setPinned(_ pinned: Bool, of id: ULID, recordingRoot: URL?, at time: Date) throws -> SessionUsage

    /// Records a use of a session.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - recordingRoot: The recording root of the session, or `nil` to keep
    ///     the recording root that the store holds.
    ///   - time: The time of the use.
    /// - Returns: The usage of the session after the change.
    /// - Throws: The error of a write that fails. The store then stays as it
    ///   was.
    @discardableResult
    func markUsed(_ id: ULID, recordingRoot: URL?, at time: Date) throws -> SessionUsage
}
