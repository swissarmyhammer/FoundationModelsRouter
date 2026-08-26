import Foundation

/// The per-session transcript filename under a session's recording directory.
private let transcriptFileName = "transcript.jsonl"

/// A failure looking up or reconstructing data from a ``TranscriptTree``.
enum TranscriptTreeError: Error, Equatable, LocalizedError {
    /// No session with this id exists in the loaded tree.
    case sessionNotFound(ULID)

    /// `directory` holds session data but has no ``SessionSidecar``. The
    /// session cannot be placed in the tree.
    case sidecarMissing(directory: URL)

    /// Two session directories carry the same session id. The id names no
    /// single session.
    case duplicateSessionId(id: ULID, directories: [URL])

    /// `directory`'s `session.json` exists but could not be read or decoded.
    case sidecarUnreadable(directory: URL)

    /// `directory` holds a `session.json` but its name is not a session ULID.
    case sessionDirectoryNotIdentified(directory: URL)

    /// The session nests under a parent but its sidecar records no fork cut
    /// point (``SessionSidecar/forkedAtHistoryOrdinal`` or ``SessionSidecar/forkedAtEntryCount``).
    case forkCutPointMissing(session: ULID, directory: URL)

    /// A line of `session`'s transcript at `file`, not the last line, failed
    /// to decode. A torn final line is dropped with a warning instead.
    case transcriptLineCorrupt(session: ULID, file: URL)

    /// A localized message describing what error occurred.
    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "No session with id \(id.description) exists in this transcript tree."
        case .sidecarMissing(let directory):
            return """
                Directory \(directory.path) holds session data but no session.json, so what is \
                recorded there cannot be identified or reconstructed.
                """
        case .duplicateSessionId(let id, let directories):
            let paths = directories.map(\.path).joined(separator: ", ")
            return """
                Session id \(id.description) names more than one session directory (\(paths)), so it \
                identifies no single session.
                """
        case .sidecarUnreadable(let directory):
            return "Session directory \(directory.path)'s session.json could not be read or decoded."
        case .sessionDirectoryNotIdentified(let directory):
            return """
                Directory \(directory.path) holds a session.json but is not named for a session id, \
                so the session recorded there cannot be identified.
                """
        case .forkCutPointMissing(let id, let directory):
            return """
                Session \(id.description) (\(directory.path)) nests under a parent session but its \
                session.json records no fork cut point (neither forkedAtHistoryOrdinal nor \
                forkedAtEntryCount), so its effective transcript cannot be reconstructed.
                """
        case .transcriptLineCorrupt(let id, let file):
            return """
                Session \(id.description)'s transcript \(file.path) holds a corrupt line before its \
                last one, so the recorded log cannot be trusted.
                """
        }
    }
}

/// One session in a router's fork hierarchy, as ``TranscriptTree`` loads it.
/// A node is a complete subtree snapshot. ``children`` is ordered by ``id``,
/// which is creation order.
package struct SessionNode: Sendable, Equatable {
    /// This session's span id, read from the name of its own directory.
    package let id: ULID
    /// The span id of the session that forked this one, or `nil` for a root.
    let parentId: ULID?
    /// This session's own write-once facts, as it recorded them at creation.
    let sidecar: SessionSidecar
    /// This session's recording directory.
    let directory: URL
    /// This session's own forks, ordered by ``id`` (creation order).
    let children: [SessionNode]
}

/// The read side of the fork hierarchy. Fetch any session's transcript by
/// its ``ULID`` and inspect the tree as data. ``MergedTranscript`` gives the
/// flattened view of every session; this type gives the per-session view.
package struct TranscriptTree: Sendable {
    /// A router's root sessions, ordered by ``SessionNode/id``.
    package let roots: [SessionNode]

    /// Every session, keyed by id.
    private let nodesById: [ULID: SessionNode]

    private init(roots: [SessionNode], nodesById: [ULID: SessionNode]) {
        self.roots = roots
        self.nodesById = nodesById
    }

    // MARK: - Loading

    /// Loads the fork hierarchy under a router's recording root. Every
    /// directory with a ``SessionSidecar`` is a session. Its name is its id.
    /// The session directory it nests under is its parent. A session with a
    /// missing or unreadable sidecar fails the whole load. A deleted child
    /// directory is not detectable.
    ///
    /// - Parameter routerDirectory: The router's recording root.
    /// - Throws: ``TranscriptTreeError``, or
    ///   ``RecordingSchemaVersionError/recordingFromNewerRouter(directory:version:supported:)``
    ///   when a sidecar carries a newer schema version.
    package static func load(under routerDirectory: URL) throws -> TranscriptTree {
        let sessionDirectories = TranscriptFileDiscovery
            .fileURLs(named: sessionSidecarFileName, under: routerDirectory)
            .map { $0.deletingLastPathComponent() }
        let sessionDirectoryPaths = Set(sessionDirectories.map(\.standardizedPath))

        // A transcript with no sidecar beside it is a session that was
        // recorded but cannot be interpreted — loud, not skipped.
        for transcriptURL in TranscriptFileDiscovery.fileURLs(named: transcriptFileName, under: routerDirectory) {
            let directory = transcriptURL.deletingLastPathComponent()
            guard sessionDirectoryPaths.contains(directory.standardizedPath) else {
                throw TranscriptTreeError.sidecarMissing(directory: directory)
            }
        }

        let routerDirectoryPath = routerDirectory.standardizedPath
        let rawNodes = try sessionDirectories.map { directory in
            try rawNode(
                in: directory,
                sessionDirectoryPaths: sessionDirectoryPaths,
                routerDirectoryPath: routerDirectoryPath
            )
        }
        try checkForDuplicateIds(in: rawNodes)
        let (roots, nodesById) = buildTree(from: rawNodes)
        return TranscriptTree(roots: roots, nodesById: nodesById)
    }

    /// Throws ``TranscriptTreeError/duplicateSessionId(id:directories:)`` when
    /// any session id names more than one discovered directory.
    private static func checkForDuplicateIds(in rawNodes: [RawNode]) throws {
        let directoriesById = Dictionary(grouping: rawNodes, by: \.id)
        // Sorted so the reported id is stable when a tree collides more than
        // once, rather than whichever the enumeration reached first.
        for (id, nodes) in directoriesById.sorted(by: { $0.key < $1.key }) where nodes.count > 1 {
            throw TranscriptTreeError.duplicateSessionId(
                id: id,
                // Sorted so the reported directories do not depend on the order
                // the filesystem enumeration happened to reach them in.
                directories: nodes.map(\.directory).sorted { $0.path < $1.path }
            )
        }
    }

    /// Reads one session directory's identity, lineage, and facts.
    ///
    /// - Parameters:
    ///   - directory: The session directory.
    ///   - sessionDirectoryPaths: Every discovered session directory's standardized path.
    ///   - routerDirectoryPath: The router root's standardized path.
    /// - Throws: ``TranscriptTreeError`` when the directory, its sidecar, its
    ///   parent, or its transcript is not valid.
    private static func rawNode(
        in directory: URL,
        sessionDirectoryPaths: Set<String>,
        routerDirectoryPath: String
    ) throws -> RawNode {
        guard let id = ULID(directory.lastPathComponent) else {
            throw TranscriptTreeError.sessionDirectoryNotIdentified(directory: directory)
        }
        let decoded: SessionSidecar?
        do {
            decoded = try SessionSidecar.read(in: directory)
        } catch let error as RecordingSchemaVersionError {
            // Not corruption: the bytes decoded fine and name a schema version
            // newer than this reader knows. Rethrown typed rather than folded
            // into `sidecarUnreadable`, so a caller can tell "written by a
            // newer router" apart from "damaged on disk".
            throw error
        } catch {
            throw TranscriptTreeError.sidecarUnreadable(directory: directory)
        }
        // `directory` was discovered *by* its own `session.json`, so a `nil`
        // here means the file was removed while this load was running.
        guard let sidecar = decoded else {
            throw TranscriptTreeError.sidecarMissing(directory: directory)
        }
        // Enriches the in-memory sidecar with this session's own recorded
        // compaction count (never persisted back to the write-once
        // `session.json` — see ``SessionSidecar/compactionCount``'s own doc
        // comment), so a browser reading ``SessionNode/sidecar`` can badge a
        // folded session with no second pass over its transcript.
        let ownEvents = try decodeEvents(in: directory, forSession: id)
        let compactionCount = compactionCheckpoints(in: ownEvents).count
        return RawNode(
            id: id,
            parentId: try parentId(
                of: directory,
                sessionDirectoryPaths: sessionDirectoryPaths,
                routerDirectoryPath: routerDirectoryPath
            ),
            sidecar: sidecar.withCompactionCount(compactionCount),
            directory: directory
        )
    }

    /// The span id of the session `directory` nests directly under, or `nil`
    /// when it sits at the router root.
    ///
    /// - Throws: ``TranscriptTreeError/sidecarMissing(directory:)`` when the
    ///   enclosing directory is not the router root and not a discovered session.
    private static func parentId(
        of directory: URL,
        sessionDirectoryPaths: Set<String>,
        routerDirectoryPath: String
    ) throws -> ULID? {
        let enclosing = directory.deletingLastPathComponent()
        if enclosing.standardizedPath == routerDirectoryPath { return nil }
        guard sessionDirectoryPaths.contains(enclosing.standardizedPath),
            let parentId = ULID(enclosing.lastPathComponent)
        else {
            throw TranscriptTreeError.sidecarMissing(directory: enclosing)
        }
        return parentId
    }

    // MARK: - Tree access

    /// Returns the session with id `id`, or `nil` if no such session was loaded.
    func session(_ id: ULID) -> SessionNode? {
        nodesById[id]
    }

    /// A session's direct forks, ordered by id. Empty if `id` is unknown or a leaf.
    func children(of id: ULID) -> [SessionNode] {
        nodesById[id]?.children ?? []
    }

    // MARK: - Event retrieval

    /// Decodes one session's own recorded events, in `seq` order. Returns an
    /// empty array when the session has no `transcript.jsonl`.
    ///
    /// - Throws: ``TranscriptTreeError/sessionNotFound(_:)`` or
    ///   ``TranscriptTreeError/transcriptLineCorrupt(session:file:)``.
    func events(forSession id: ULID) throws -> [TranscriptEvent] {
        guard let node = nodesById[id] else {
            throw TranscriptTreeError.sessionNotFound(id)
        }
        return try Self.decodeEvents(in: node.directory, forSession: node.id)
    }

    /// This session's whole effective conversation, oldest first: the
    /// parent's effective entry-kind events truncated to this session's fork
    /// cut point, then this session's own entry-kind events. Only kinds with
    /// ``TranscriptEvent/Kind/isEntryKind`` appear. The cut point is
    /// ``SessionSidecar/forkedAtHistoryOrdinal`` or the legacy
    /// ``SessionSidecar/forkedAtEntryCount``.
    ///
    /// - Throws: ``TranscriptTreeError/sessionNotFound(_:)`` or
    ///   ``TranscriptTreeError/forkCutPointMissing(session:directory:)``.
    func effectiveEntryEvents(forSession id: ULID) throws -> [TranscriptEvent] {
        guard let node = nodesById[id] else {
            throw TranscriptTreeError.sessionNotFound(id)
        }
        return try effectiveEntryEvents(for: node)
    }

    /// The recursive worker behind ``effectiveEntryEvents(forSession:)``.
    private func effectiveEntryEvents(for node: SessionNode) throws -> [TranscriptEvent] {
        let ownEntries = try entryKindEvents(for: node)
        guard let parentId = node.parentId else {
            return ownEntries
        }
        // Total by construction: ``load(under:)`` only records a `parentId` for
        // a session nested under a *discovered* session directory, and every
        // discovered directory becomes a node.
        guard let parent = nodesById[parentId] else {
            preconditionFailure("a loaded node's parentId always names another loaded node")
        }
        // The cut point in the recorded history's own append-only
        // coordinates. A recording made before `forkedAtHistoryOrdinal`
        // existed falls back to the legacy `forkedAtEntryCount`: that count
        // was captured before any post-fork fold could rewind it, so on such
        // a recording it names the same position in these coordinates.
        guard let cut = node.sidecar.forkedAtHistoryOrdinal ?? node.sidecar.forkedAtEntryCount else {
            throw TranscriptTreeError.forkCutPointMissing(session: node.id, directory: node.directory)
        }
        let parentEffective = try effectiveEntryEvents(for: parent)
        return Array(parentEffective.prefix(cut)) + ownEntries
    }

    /// `node`'s own recorded events, filtered by ``TranscriptEvent/Kind/isEntryKind``.
    private func entryKindEvents(for node: SessionNode) throws -> [TranscriptEvent] {
        try Self.decodeEvents(in: node.directory, forSession: node.id).filter(\.kind.isEntryKind)
    }

    // MARK: - Event decoding

    /// Decodes every line of `directory`'s `transcript.jsonl` in `seq` order,
    /// or an empty array if that file does not exist. A torn final line is
    /// dropped with a warning.
    ///
    /// - Throws: ``TranscriptTreeError/transcriptLineCorrupt(session:file:)``
    ///   when a line before the last fails to decode.
    private static func decodeEvents(in directory: URL, forSession session: ULID) throws -> [TranscriptEvent] {
        let fileURL = directory.appendingPathComponent(transcriptFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let events = try TranscriptLineDecoding.decodeEvents(at: fileURL) { file in
            TranscriptTreeError.transcriptLineCorrupt(session: session, file: file)
        }
        return events.sorted { $0.seq < $1.seq }
    }

    // MARK: - Tree construction

    /// One session's identity, lineage, facts, and directory before linking.
    private struct RawNode {
        let id: ULID
        let parentId: ULID?
        let sidecar: SessionSidecar
        let directory: URL
    }

    /// Links flat ``RawNode``s into the recursive ``SessionNode`` tree.
    /// Children and roots come out ordered by id.
    private static func buildTree(
        from rawNodes: [RawNode]
    ) -> (roots: [SessionNode], nodesById: [ULID: SessionNode]) {
        let rawById = Dictionary(uniqueKeysWithValues: rawNodes.map { ($0.id, $0) })
        var childIdsByParent: [ULID: [ULID]] = [:]
        var rootIds: [ULID] = []
        for raw in rawNodes {
            if let parentId = raw.parentId {
                childIdsByParent[parentId, default: []].append(raw.id)
            } else {
                rootIds.append(raw.id)
            }
        }

        var nodesById: [ULID: SessionNode] = [:]
        func build(_ id: ULID) -> SessionNode? {
            guard let raw = rawById[id] else { return nil }
            let children = (childIdsByParent[id] ?? []).sorted().compactMap(build)
            let node = SessionNode(
                id: raw.id,
                parentId: raw.parentId,
                sidecar: raw.sidecar,
                directory: raw.directory,
                children: children
            )
            nodesById[id] = node
            return node
        }

        let roots = rootIds.sorted().compactMap(build)
        return (roots, nodesById)
    }
}

extension URL {
    /// This URL's canonical filesystem path with every symlink resolved, for
    /// direct comparison. Falls back to the standardized path when nothing
    /// exists at the URL.
    fileprivate var standardizedPath: String {
        (try? resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? standardizedFileURL.path
    }
}
