import Foundation
import FoundationModelsExtras

@testable import FoundationModelsRouter

/// Hand-built ``SessionRecord`` values and `index.md` files, for the tests
/// that lay out a recording on disk by hand instead of vending sessions:
/// a malformed tree, a recording root the scan reads, a session the
/// transcript readers interpret. The values are placeholders the tests do
/// not read back.
enum SessionRecordFixtures {
    /// The concrete model each placeholder record holds.
    static let model: ModelRef = "org/model-a"

    /// The working context, in tokens, each placeholder record holds.
    static let context = 8_192

    /// A placeholder record of the session in `directory`.
    ///
    /// - Parameters:
    ///   - directory: The session folder. Its name is the session id when it
    ///     is a ULID; otherwise the record holds a new id.
    ///   - forkedAtEntryCount: The fork cut, or `nil` (the default) for a
    ///     root session.
    ///   - routerId: The recording root id. The default is a new id.
    ///   - instructions: The system instructions, or `nil` (the default).
    ///   - profile: The resolved profile, or `nil` (the default).
    ///   - agentSpawn: The spawn context, or `nil` (the default).
    ///   - configuration: The configuration envelope, or `nil` (the default).
    /// - Returns: The record.
    static func record(
        in directory: URL,
        forkedAtEntryCount: Int? = nil,
        routerId: ULID = .generate(),
        instructions: String? = nil,
        profile: SessionRecord.ResolvedProfile? = nil,
        agentSpawn: SessionRecord.AgentSpawn? = nil,
        configuration: SessionConfiguration.Persistable? = nil
    ) -> SessionRecord {
        SessionRecord(
            sessionId: ULID(directory.lastPathComponent) ?? .generate(),
            workingDirectory: directory,
            updatedAt: Date(),
            slot: .standard,
            model: model,
            context: context,
            recordingLevel: .full,
            routerId: routerId,
            forkedAtEntryCount: forkedAtEntryCount,
            instructions: instructions,
            profile: profile,
            agentSpawn: agentSpawn,
            configuration: configuration)
    }

    /// Makes `directory` and saves `record` as its `index.md`.
    ///
    /// - Parameters:
    ///   - record: The record to save.
    ///   - directory: The session folder. It is made when it is not there.
    /// - Throws: The error of the making of the folder or of the save.
    static func write(_ record: SessionRecord, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SessionIndexFile.save(record, in: directory)
    }

    /// Makes `directory` and saves a placeholder record of it as its
    /// `index.md`.
    ///
    /// - Parameters:
    ///   - directory: The session folder. It is made when it is not there.
    ///   - forkedAtEntryCount: The fork cut, or `nil` (the default) for a
    ///     root session.
    /// - Throws: The error of the making of the folder or of the save.
    static func writePlaceholder(in directory: URL, forkedAtEntryCount: Int? = nil) throws {
        try write(record(in: directory, forkedAtEntryCount: forkedAtEntryCount), to: directory)
    }
}
