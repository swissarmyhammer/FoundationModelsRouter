import Foundation

/// The per-session transcript filename under a session's recording directory.
private let transcriptFileName = "transcript.jsonl"

/// A failure looking up or reconstructing data from a ``TranscriptTree``.
public enum TranscriptTreeError: Error, Equatable, LocalizedError {
    /// No session with this id exists in the loaded tree.
    case sessionNotFound(ULID)

    /// `directory` holds session data — a `transcript.jsonl`, or a nested
    /// session directory — but has no ``SessionSidecar`` identifying it, so
    /// whatever is recorded there cannot be placed in the tree.
    ///
    /// Every session writes its sidecar before it can record anything (see
    /// ``SessionSidecar/write(_:to:)``), so on a tree this library wrote, this
    /// means the file was deleted or never made it to disk. It is reported
    /// loudly, naming the exact directory: silently skipping it would truncate
    /// a descendant's reconstructed conversation to the part after the fork,
    /// which reads as a plausible — and wrong — transcript.
    case sidecarMissing(directory: URL)

    /// Two session directories carry the same session id in their names, so
    /// the id names no single session.
    ///
    /// The filesystem rules this out within one directory, but not across the
    /// tree — a copied or rsynced session directory pasted under another
    /// produces it. Reported rather than trapped, like every other
    /// malformed-tree condition this loader meets.
    case duplicateSessionId(id: ULID, directories: [URL])

    /// `directory`'s `session.json` exists but could not be read or decoded.
    case sidecarUnreadable(directory: URL)

    /// `directory` holds a `session.json` but is not named for a session:
    /// every session's directory is named by its own ULID, which is where its
    /// id (and creation order) comes from.
    case sessionDirectoryNotIdentified(directory: URL)

    /// ``TranscriptTree/effectiveEntryEvents(forSession:)`` needs this
    /// session's ``SessionSidecar/forkedAtEntryCount`` to truncate its
    /// parent's effective entries, but its sidecar has none — it nests under a
    /// parent session yet records no cut point, so it cannot say how much of
    /// that parent's conversation is its own.
    case forkCutPointMissing(session: ULID, directory: URL)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
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
                session.json records no forkedAtEntryCount, so its effective transcript cannot be \
                reconstructed.
                """
        }
    }
}

/// One session in a router's fork hierarchy, as reconstructed by
/// ``TranscriptTree``.
///
/// Value-typed and fully self-contained: ``children`` holds the actual child
/// nodes, not ids to look up elsewhere, so a `SessionNode` handed to a caller
/// is a complete, walkable subtree snapshot as of ``TranscriptTree/load(under:)``.
/// ``children`` is ordered by ``id`` — since a `ULID` is time-sortable, that is
/// creation order (see `Core/ULID.swift`).
public struct SessionNode: Sendable, Equatable {
    /// This session's span id, read from the name of its own directory.
    public let id: ULID
    /// The span id of the session that forked this one — the session whose
    /// directory this one nests directly under — or `nil` for a root.
    public let parentId: ULID?
    /// This session's own write-once facts, as it recorded them at creation.
    public let sidecar: SessionSidecar
    /// This session's recording directory, holding its own `session.json` and
    /// `transcript.jsonl`.
    public let directory: URL
    /// This session's own forks, ordered by ``id`` (creation order).
    public let children: [SessionNode]
}

/// The queryable read-side of the fork hierarchy: fetch any session's
/// transcript directly by its ``ULID``, and inspect the tree as data — no
/// caller-side directory walking (see plan.md's "Transcript fidelity"
/// section, "Retrieval & the fork hierarchy as first-class data").
///
/// ``MergedTranscript`` answers "everything under this router, flattened,
/// interleaved by `(ts, seq)`"; `TranscriptTree` answers "where does this one
/// session sit in the fork tree", "what did this one session itself record",
/// and "what was this one session's whole effective conversation as its live
/// `Transcript` actually held it" — the two views coexist, and neither
/// supersedes the other.
public struct TranscriptTree: Sendable {
    /// A router's root sessions — every session sitting directly at the
    /// recording root rather than nested under another session's directory —
    /// ordered by ``SessionNode/id`` (creation order).
    public let roots: [SessionNode]

    /// Every session, keyed by id, for O(1) ``session(_:)``/``children(of:)``
    /// lookups without walking ``roots``.
    private let nodesById: [ULID: SessionNode]

    private init(roots: [SessionNode], nodesById: [ULID: SessionNode]) {
        self.roots = roots
        self.nodesById = nodesById
    }

    // MARK: - Loading

    /// Loads the fork hierarchy under a router's recording root.
    ///
    /// The tree is read from the layout itself: every directory holding a
    /// ``SessionSidecar`` is a session, its own directory name is its id, and
    /// the session directory it nests under (if any) is its parent. Nothing
    /// else on disk is consulted for structure — there is no index to fall out
    /// of step with the directories it describes.
    ///
    /// A session directory whose sidecar is missing or undecodable fails the
    /// **whole load**, naming that directory, rather than dropping that one
    /// node: a dropped session leaves its own forks unreachable and truncates
    /// their reconstructed conversations to the part after the fork, with
    /// nothing on disk to show anything was lost. One unreadable session is
    /// therefore deliberately louder than the sessions it can still read are
    /// useful — a partially-loaded tree cannot say which of its transcripts
    /// are whole. Since a sidecar is written before its session records
    /// anything, and is never rewritten, this state means the file was deleted
    /// or a write was dropped (see ``SessionSidecarWriter``'s best-effort
    /// policy).
    ///
    /// - Parameter routerDirectory: The router's recording root —
    ///   `recordings/<routerId>/` — the same directory
    ///   ``MergedTranscript/merged(under:)`` reads.
    /// - Returns: The loaded tree.
    /// - Throws: ``TranscriptTreeError/sidecarMissing(directory:)`` for a
    ///   session directory with no `session.json`;
    ///   ``TranscriptTreeError/sidecarUnreadable(directory:)`` if one cannot be
    ///   decoded; ``TranscriptTreeError/sessionDirectoryNotIdentified(directory:)``
    ///   if a sidecar sits in a directory not named for a session id.
    public static func load(under routerDirectory: URL) throws -> TranscriptTree {
        let sessionDirectories = fileURLs(named: sessionSidecarFileName, under: routerDirectory)
            .map { $0.deletingLastPathComponent() }
        let sessionDirectoryPaths = Set(sessionDirectories.map(\.standardizedPath))

        // A transcript with no sidecar beside it is a session that was
        // recorded but cannot be interpreted — loud, not skipped.
        for transcriptURL in fileURLs(named: transcriptFileName, under: routerDirectory) {
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

    /// Throws when any session id names more than one discovered directory.
    ///
    /// ``buildTree(from:)`` keys nodes by id, which requires ids to be unique;
    /// this turns what would otherwise be a trap deep in a `Dictionary`
    /// initializer into ``TranscriptTreeError/duplicateSessionId(id:directories:)``
    /// naming the colliding directories.
    ///
    /// - Parameter rawNodes: Every discovered session's raw node.
    /// - Throws: ``TranscriptTreeError/duplicateSessionId(id:directories:)``.
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
    ///   - directory: The session directory, known to hold a `session.json`.
    ///   - sessionDirectoryPaths: Every discovered session directory's
    ///     standardized path, to resolve this one's parent by nesting.
    ///   - routerDirectoryPath: The router root's standardized path — a
    ///     session directly inside it is a root.
    /// - Returns: The raw node for `directory`.
    /// - Throws: ``TranscriptTreeError`` if the directory is not named for a
    ///   session id, its sidecar cannot be decoded, or the directory it nests
    ///   under is not a session's (see ``parentId(of:sessionDirectoryPaths:routerDirectoryPath:)``).
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
        } catch {
            throw TranscriptTreeError.sidecarUnreadable(directory: directory)
        }
        // `directory` was discovered *by* its own `session.json`, so a `nil`
        // here means the file was removed while this load was running.
        guard let sidecar = decoded else {
            throw TranscriptTreeError.sidecarMissing(directory: directory)
        }
        return RawNode(
            id: id,
            parentId: try parentId(
                of: directory,
                sessionDirectoryPaths: sessionDirectoryPaths,
                routerDirectoryPath: routerDirectoryPath
            ),
            sidecar: sidecar,
            directory: directory
        )
    }

    /// The span id of the session `directory` nests directly under, or `nil`
    /// when it sits at the router root and is therefore a root session.
    ///
    /// - Parameters:
    ///   - directory: The session directory whose parent to resolve.
    ///   - sessionDirectoryPaths: Every discovered session directory's
    ///     standardized path.
    ///   - routerDirectoryPath: The router root's standardized path.
    /// - Returns: The enclosing session's id, or `nil` for a root.
    /// - Throws: ``TranscriptTreeError/sidecarMissing(directory:)`` when the
    ///   enclosing directory is neither the router root nor a discovered
    ///   session — either a parent session whose own sidecar is gone, or a
    ///   directory that was never a session at all with a session nested
    ///   inside it. Both leave this session unplaceable, and treating either as
    ///   a root would silently truncate its reconstructed conversation to its
    ///   own turns; the error names the enclosing directory, which is the one
    ///   that has to change either way.
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

    /// Looks up a session anywhere in the tree by its id alone — no directory
    /// path required.
    ///
    /// - Parameter id: The session's span id.
    /// - Returns: The matching node, or `nil` if no such session was loaded.
    public func session(_ id: ULID) -> SessionNode? {
        nodesById[id]
    }

    /// A session's direct forks, ordered by id (creation order).
    ///
    /// - Parameter id: The parent session's span id.
    /// - Returns: Its children, or an empty array if `id` is unknown or a leaf.
    public func children(of id: ULID) -> [SessionNode] {
        nodesById[id]?.children ?? []
    }

    // MARK: - Event retrieval

    /// Decodes one session's own recorded events — its `transcript.jsonl`
    /// alone, never an ancestor's or a descendant's.
    ///
    /// - Parameter id: The session's span id.
    /// - Returns: Every event that session recorded, in `seq` order, or an
    ///   empty array if the session never recorded anything (no
    ///   `transcript.jsonl` was ever created for it — a session writes no file
    ///   at all until its first generation).
    /// - Throws: ``TranscriptTreeError/sessionNotFound(_:)`` if `id` is not in
    ///   the tree; otherwise if `transcript.jsonl` exists but cannot be read
    ///   or decoded.
    public func events(forSession id: ULID) throws -> [TranscriptEvent] {
        guard let node = nodesById[id] else {
            throw TranscriptTreeError.sessionNotFound(id)
        }
        return try Self.decodeEvents(in: node.directory)
    }

    /// This session's whole effective conversation: recursively, the
    /// parent's effective entry-kind events truncated to
    /// ``SessionNode/forkedAtEntryCount``, followed by this session's own
    /// entry-kind events — exactly mirroring what its live `Transcript` held
    /// (see plan.md's "Transcript fidelity" section).
    ///
    /// "Entry-kind" means ``TranscriptEvent/Kind/instructions``,
    /// ``TranscriptEvent/Kind/prompt``, ``TranscriptEvent/Kind/toolCalls``,
    /// ``TranscriptEvent/Kind/toolOutput``, ``TranscriptEvent/Kind/response``,
    /// and ``TranscriptEvent/Kind/reasoning`` only: the router-only
    /// ``TranscriptEvent/Kind/session`` meta event and
    /// ``TranscriptEvent/Kind/embedding`` events never appear in the result,
    /// even if present in the underlying files.
    ///
    /// A root's result is just its own entry-kind events — there is no parent
    /// to truncate and prepend. A fork's parent contribution is *that
    /// parent's own effective conversation* (already recursively including
    /// whatever it in turn inherited), truncated to this session's
    /// `forkedAtEntryCount` — so an ancestor that keeps generating turns after
    /// this session forked from it never leaks into the result: the
    /// truncation point was fixed at fork time, independent of how much the
    /// ancestor's own transcript grows afterward.
    ///
    /// - Parameter id: The session's span id.
    /// - Returns: The session's full effective entry-kind conversation, oldest
    ///   first.
    /// - Throws: ``TranscriptTreeError/sessionNotFound(_:)`` if `id` is not in
    ///   the tree; ``TranscriptTreeError/forkCutPointMissing(session:directory:)``
    ///   if this session or any ancestor on the path to a root nests under a
    ///   parent yet records no cut point; otherwise if an underlying
    ///   `transcript.jsonl` cannot be read or decoded.
    public func effectiveEntryEvents(forSession id: ULID) throws -> [TranscriptEvent] {
        guard let node = nodesById[id] else {
            throw TranscriptTreeError.sessionNotFound(id)
        }
        return try effectiveEntryEvents(for: node)
    }

    /// The recursive worker behind ``effectiveEntryEvents(forSession:)``,
    /// operating on an already-resolved node so the parent walk never repeats
    /// the ``nodesById`` lookup the public entry point already did.
    ///
    /// A root (``SessionNode/parentId`` is `nil`) returns just its own
    /// entries — nothing to truncate and prepend.
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
        guard let forkedAtEntryCount = node.sidecar.forkedAtEntryCount else {
            throw TranscriptTreeError.forkCutPointMissing(session: node.id, directory: node.directory)
        }
        let parentEffective = try effectiveEntryEvents(for: parent)
        return Array(parentEffective.prefix(forkedAtEntryCount)) + ownEntries
    }

    /// `node`'s own recorded events, filtered to entry kinds only.
    private func entryKindEvents(for node: SessionNode) throws -> [TranscriptEvent] {
        try Self.decodeEvents(in: node.directory).filter { Self.isEntryKind($0.kind) }
    }

    // MARK: - Entry-kind filter

    /// Whether `kind` mirrors one of `FoundationModels.Transcript.Entry`'s six
    /// cases. The router-only ``TranscriptEvent/Kind/session``/
    /// ``TranscriptEvent/Kind/embedding`` kinds and the legacy
    /// ``TranscriptEvent/Kind/toolCall`` are not entry-kind. Exhaustive over
    /// every ``TranscriptEvent/Kind`` case, so a future case added to the enum
    /// fails to compile here until this switch is updated, rather than
    /// silently defaulting either way.
    private static func isEntryKind(_ kind: TranscriptEvent.Kind) -> Bool {
        switch kind {
        case .instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning:
            return true
        case .session, .embedding, .toolCall:
            return false
        }
    }

    // MARK: - Event decoding

    /// Decodes every line of `directory`'s `transcript.jsonl`, or an empty
    /// array if that file was never created (see ``events(forSession:)``).
    private static func decodeEvents(in directory: URL) throws -> [TranscriptEvent] {
        let fileURL = directory.appendingPathComponent(transcriptFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var events: [TranscriptEvent] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            events.append(try decoder.decode(TranscriptEvent.self, from: Data(line.utf8)))
        }
        return events.sorted { $0.seq < $1.seq }
    }

    // MARK: - Tree construction

    /// One session's identity, lineage, facts, and directory, before
    /// ``buildTree(from:)`` links flat nodes into the recursive
    /// ``SessionNode`` tree.
    private struct RawNode {
        let id: ULID
        let parentId: ULID?
        let sidecar: SessionSidecar
        let directory: URL
    }

    /// Links flat ``RawNode``s into the recursive ``SessionNode`` tree:
    /// groups by ``RawNode/parentId``, then recursively builds each node's
    /// children before the node itself, so children (and roots) come out
    /// ordered by id.
    ///
    /// - Parameter rawNodes: Every session's flat identity/lineage/facts.
    /// - Returns: The tree's roots and a flat id-keyed lookup of every node.
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

    // MARK: - Discovery

    /// Finds every file named `fileName` nested at any depth under
    /// `directory` — the same enumeration ``MergedTranscript`` performs, kept
    /// file-local here rather than shared, matching this module's existing
    /// precedent (each JSONL sink/reader hardcodes its own filename; see
    /// `Sinks.swift` and `MergedTranscript.swift`).
    ///
    /// - Parameters:
    ///   - fileName: The file name to match.
    ///   - directory: The recording root to search.
    /// - Returns: The discovered file URLs, in no particular order.
    private static func fileURLs(named fileName: String, under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            files.append(url)
        }
        return files
    }
}

extension URL {
    /// This URL's filesystem path in a directly comparable form: the canonical
    /// path the filesystem itself reports, with every symlink resolved.
    ///
    /// ``TranscriptTree`` resolves a session's parent by comparing enclosing
    /// directories, where one side comes from a caller-supplied `URL` and the
    /// other from a `FileManager` enumeration. The two routinely spell the same
    /// directory differently — on macOS the temporary directory is reached
    /// through a symlink (`/var` → `/private/var`), which an enumeration
    /// resolves and a caller's `URL` does not — so they are compared by this
    /// rather than by `==`, which would read two spellings of one directory as
    /// two directories and report a present parent as missing.
    ///
    /// Falls back to the standardized path for a URL with nothing at it: there
    /// is no canonical path to ask the filesystem for, and comparing the
    /// literal path is the best available answer.
    fileprivate var standardizedPath: String {
        (try? resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? standardizedFileURL.path
    }
}
