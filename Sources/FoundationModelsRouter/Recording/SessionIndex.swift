import Foundation
import os

/// The logger ``SessionIndexWriter`` reports a dropped record to, mirroring
/// ``JSONLRecorder``'s log-and-drop failure policy (see
/// Sources/FoundationModelsRouter/Recording/Sinks.swift).
private let sessionIndexLogger = makeModuleLogger(category: "SessionIndex")

/// The session index's filename under a router root
/// (`recordings/<routerId>/sessions.jsonl`), shared by the append and read
/// paths so the name is kept in exactly one place.
private let sessionIndexFileName = "sessions.jsonl"

/// One appended record in a router's session index — the fork hierarchy made
/// first-class, queryable data instead of something implicit in directory
/// nesting.
///
/// Written once per session, at the moment the session is created: a root
/// session (``RoutedModel/makeSession(instructions:workingDirectory:)`` /
/// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:)``)
/// carries `parentId: nil` and `forkedAtEntryCount: 0`; a fork
/// (``RoutedSessionActor/fork(workingDirectory:)``) carries its parent's id and
/// the parent's ``LanguageModelSessionBackend/transcriptEntries()`` count at
/// fork time — the same baseline the fork's own transcript-diff persistence
/// uses (see plan.md's "Transcript fidelity" section), so the index's lineage
/// cut point and the diff baseline are one fact, not two.
///
/// ``instructions``/``grammar`` are recorded (not just implied by transcript
/// content) so a future tree restoration can rehydrate a restored
/// ``RoutedSessionActor``'s actor state without replaying its transcript:
/// `grammar` in particular changes the behavior of every future `respond` and
/// exists nowhere else on disk today except implicitly on turn events.
public struct SessionIndexRecord: Codable, Sendable, Equatable {
    /// This session's span id.
    public let sessionId: ULID
    /// The span id of the session that forked this one, or `nil` for a root
    /// session.
    public let parentId: ULID?
    /// This session's recording directory, relative to the router root
    /// (`recordings/<routerId>/`) — e.g. the session id alone for a root, or
    /// `<rootId>/<forkId>` for a fork nested one level deep.
    public let path: String
    /// How many entries the parent's transcript held at fork time — `0` for a
    /// root session, or the parent's ``LanguageModelSessionBackend/transcriptEntries()``
    /// count at the moment this session was forked from it.
    public let forkedAtEntryCount: Int
    /// The model slot this session runs against, or `nil` when unknown.
    public let slot: ModelSlot?
    /// The concrete model reference this session runs against, or `nil` when
    /// unknown.
    public let model: ModelRef?
    /// This session's system instructions, or `nil`.
    public let instructions: String?
    /// This session's guided-generation grammar source, or `nil` for an
    /// unconstrained session.
    public let grammar: String?
    /// When this session was created.
    public let createdAt: Date

    /// Creates a session index record.
    ///
    /// - Parameters:
    ///   - sessionId: This session's span id.
    ///   - parentId: The forking session's span id, or `nil` for a root.
    ///   - path: This session's recording directory, relative to the router root.
    ///   - forkedAtEntryCount: The parent's transcript entry count at fork time,
    ///     or `0` for a root session.
    ///   - slot: The model slot this session runs against, or `nil`.
    ///   - model: The concrete model reference, or `nil`.
    ///   - instructions: This session's system instructions, or `nil`.
    ///   - grammar: This session's guided-generation grammar source, or `nil`.
    ///   - createdAt: When this session was created.
    public init(
        sessionId: ULID,
        parentId: ULID?,
        path: String,
        forkedAtEntryCount: Int,
        slot: ModelSlot?,
        model: ModelRef?,
        instructions: String?,
        grammar: String?,
        createdAt: Date
    ) {
        self.sessionId = sessionId
        self.parentId = parentId
        self.path = path
        self.forkedAtEntryCount = forkedAtEntryCount
        self.slot = slot
        self.model = model
        self.instructions = instructions
        self.grammar = grammar
        self.createdAt = createdAt
    }
}

/// Appends ``SessionIndexRecord``s as JSON lines to a router's
/// `recordings/<routerId>/sessions.jsonl`, and decodes them back.
///
/// One writer is born per router (see ``Router``), targeting that router's
/// fixed recording root — unlike ``JSONLRecorder``, which routes each append to
/// a caller-supplied per-session directory, every append here lands in the same
/// file. As an actor it serializes appends, so concurrent sessions/forks vending
/// at once still produce one well-formed line each with no interleaving or torn
/// writes. Writing is best-effort, mirroring ``JSONLRecorder``: any I/O failure
/// is logged and the record dropped — ``append(_:)`` never throws.
public actor SessionIndexWriter {
    /// The router-root directory `sessions.jsonl` is appended to
    /// (`recordings/<routerId>/`).
    private let directory: URL
    /// Encodes each record to a single compact JSON line (no embedded newlines).
    private let encoder = JSONEncoder()
    /// The append handle, opened lazily on first append and reused.
    private var handle: FileHandle?

    /// Creates a session index writer targeting a router's recording root.
    ///
    /// - Parameter directory: The router-root directory `sessions.jsonl` is
    ///   appended to, created on demand at first append.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Appends `record` as one JSON line to `sessions.jsonl`; logs and drops it
    /// on any I/O failure.
    public func append(_ record: SessionIndexRecord) async {
        appendJSONLine(
            record,
            encoder: encoder,
            logger: sessionIndexLogger,
            handle: { try self.handleForAppending() },
            describeFailure: { error in
                "dropping session index record for session \(record.sessionId.description): \(error.localizedDescription)"
            }
        )
    }

    /// Returns the reusable append handle, creating the directory and its
    /// `sessions.jsonl` and seeking to the end on first use.
    private func handleForAppending() throws -> FileHandle {
        if let handle { return handle }
        let opened = try openHandleForAppending(fileName: sessionIndexFileName, in: directory)
        handle = opened
        return opened
    }

    /// Decodes every record from a router root's `sessions.jsonl`, deduped by
    /// ``SessionIndexRecord/sessionId`` — first record wins.
    ///
    /// The record appended at creation time is authoritative, and a session id
    /// is never legitimately re-appended, so a duplicate line is a bug
    /// elsewhere — but this keeps reads correct regardless.
    ///
    /// - Parameter directory: The router-root directory to read `sessions.jsonl`
    ///   from — the same directory a writer targeting that router was
    ///   constructed with.
    /// - Returns: Every distinct session's record, in file order, or an empty
    ///   array when no `sessions.jsonl` exists yet.
    /// - Throws: Any error decoding an existing file's contents.
    public static func read(under directory: URL) throws -> [SessionIndexRecord] {
        let fileURL = directory.appendingPathComponent(sessionIndexFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var seen = Set<ULID>()
        var records: [SessionIndexRecord] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            let record = try decoder.decode(SessionIndexRecord.self, from: Data(line.utf8))
            if seen.insert(record.sessionId).inserted {
                records.append(record)
            }
        }
        return records
    }
}
