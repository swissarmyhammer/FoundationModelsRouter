import Foundation

/// The session index's filename under a router root — duplicated locally from
/// `SessionIndex.swift`'s own file-scoped constant of the same name, matching
/// this module's existing precedent of each JSONL sink/reader hardcoding its
/// filename independently rather than sharing one constant across files (see
/// `Sinks.swift` and `MergedTranscript.swift`, which both already hardcode
/// `"transcript.jsonl"` the same way).
private let sessionIndexFileName = "sessions.jsonl"

/// The per-session transcript filename under a session's recording directory.
private let transcriptFileName = "transcript.jsonl"

/// A failure looking up or reconstructing data from a ``TranscriptTree``.
public enum TranscriptTreeError: Error, Equatable, LocalizedError {
    /// No session with this id exists in the loaded tree.
    case sessionNotFound(ULID)

    /// ``TranscriptTree/effectiveEntryEvents(forSession:)`` needs this
    /// session's ``SessionNode/forkedAtEntryCount`` to truncate its parent's
    /// effective entries, but it is `nil` — the session was loaded through
    /// ``TranscriptTree/load(under:)``'s index-less fallback (no
    /// `sessions.jsonl` on disk), which cannot recover a fork's cut point
    /// from directory nesting or an event's `parentId` alone.
    case forkedAtEntryCountUnknown(ULID)

    /// This session's ``SessionNode/parentId`` is non-nil, but no node with
    /// that id exists in the loaded tree, so ``TranscriptTree/effectiveEntryEvents(forSession:)``
    /// has no ancestor data to truncate and prepend.
    ///
    /// Thrown even when ``SessionNode/forkedAtEntryCount`` is known — a real,
    /// known cut point with no ancestor left to apply it to is a stronger
    /// reason to fail loudly than an unknown cut point, never a reason to
    /// silently return just this session's own entries as if that were its
    /// whole conversation. This can happen via the index-less fallback (a
    /// session that forked a child before ever generating leaves no
    /// `transcript.jsonl`, so the child's declared parent has no
    /// discoverable node at all) or via the index itself (the parent's own
    /// `sessions.jsonl` line was dropped by ``SessionIndexWriter``'s
    /// best-effort log-and-drop failure policy while the child's own line
    /// wrote fine).
    case parentUnresolvable(ULID)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "No session with id \(id.description) exists in this transcript tree."
        case .forkedAtEntryCountUnknown(let id):
            return """
                Session \(id.description)'s forkedAtEntryCount is unknown: it was loaded via \
                TranscriptTree's index-less fallback, which cannot recover a fork's cut point, so \
                its effective transcript cannot be reconstructed.
                """
        case .parentUnresolvable(let id):
            return """
                Session \(id.description) declares a parent that does not exist in this loaded \
                transcript tree, so its effective transcript cannot be reconstructed.
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
    /// This session's span id.
    public let id: ULID
    /// The span id of the session that forked this one, or `nil` for a root.
    public let parentId: ULID?
    /// How many of the parent's effective entry-kind events belong to this
    /// session's own effective transcript — the parent's
    /// ``LanguageModelSessionBackend/transcriptEntries()`` count at the moment
    /// this session forked from it (see ``SessionIndexRecord/forkedAtEntryCount``),
    /// or `nil` when unknown.
    ///
    /// `nil` only when this node was recovered through
    /// ``TranscriptTree/load(under:)``'s index-less fallback, which has no way
    /// to recover a fork's cut point. Meaningless (and never consulted) for a
    /// node with no ``parentId``.
    public let forkedAtEntryCount: Int?
    /// This session's recording directory, holding its own `transcript.jsonl`.
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
    /// Every session with no parent, ordered by ``SessionNode/id`` (creation
    /// order) — normally a router's root sessions, though the index-less
    /// fallback also surfaces here any session whose parent could not be
    /// recovered.
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
    /// Reads `sessions.jsonl` via ``SessionIndexWriter/read(under:)``, which
    /// dedupes records by ``SessionIndexRecord/sessionId`` (first record
    /// wins — see that type's own documentation), so even an accidentally
    /// duplicated index line can never yield two ``SessionNode``s for one
    /// session or a corrupted tree.
    ///
    /// When no `sessions.jsonl` exists under `routerDirectory` (a pre-index
    /// recording), falls back to enumerating every nested `transcript.jsonl`
    /// and deriving each session's id and parent from its own first recorded
    /// event — every line a session ever writes shares that session's
    /// `sessionId`/`parentId`, so any one line suffices, and the directory a
    /// file was found nested under becomes that session's ``SessionNode/directory``.
    /// The fallback cannot recover ``SessionNode/forkedAtEntryCount`` (it
    /// exists nowhere on disk outside the index), so every fallback node
    /// carries `nil` there; see ``effectiveEntryEvents(forSession:)``.
    ///
    /// - Parameter routerDirectory: The router's recording root —
    ///   `recordings/<routerId>/` — the same directory
    ///   ``SessionIndexWriter/read(under:)`` and ``MergedTranscript/merged(under:)``
    ///   read.
    /// - Returns: The loaded tree.
    /// - Throws: If `sessions.jsonl` or a nested `transcript.jsonl` exists but
    ///   cannot be read or decoded.
    public static func load(under routerDirectory: URL) throws -> TranscriptTree {
        // Keying the index/fallback choice on *decoded record count* rather
        // than mere file existence also recovers from a present-but-empty
        // `sessions.jsonl` — e.g. a dropped write that created the file (see
        // `JSONLAppend.swift`'s `openHandleForAppending`) but never
        // successfully appended a line to it — which would otherwise read as
        // "the index exists and says there are zero sessions" instead of
        // "the index is unusable, recover from the transcripts themselves."
        var rawNodes: [RawNode] = []
        let indexFileURL = routerDirectory.appendingPathComponent(sessionIndexFileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: indexFileURL.path) {
            rawNodes = try SessionIndexWriter.read(under: routerDirectory).map { record in
                RawNode(
                    id: record.sessionId,
                    parentId: record.parentId,
                    forkedAtEntryCount: record.forkedAtEntryCount,
                    directory: routerDirectory.appendingPathComponent(record.path, isDirectory: true)
                )
            }
        }
        if rawNodes.isEmpty {
            rawNodes = try fallbackRawNodes(under: routerDirectory)
        }
        let (roots, nodesById) = buildTree(from: rawNodes)
        return TranscriptTree(roots: roots, nodesById: nodesById)
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
    ///   the tree; ``TranscriptTreeError/parentUnresolvable(_:)`` if this
    ///   session or any ancestor on the path to a root declares a parent that
    ///   does not exist in the loaded tree (an orphan promoted to a root by
    ///   ``buildTree(from:)``); ``TranscriptTreeError/forkedAtEntryCountUnknown(_:)``
    ///   if this session or any ancestor on the path to a root has a
    ///   resolvable parent but an unknown `forkedAtEntryCount` (only possible
    ///   via the index-less fallback); otherwise if an underlying
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
    /// A true root (``SessionNode/parentId`` is `nil`) returns just its own
    /// entries — nothing to truncate and prepend. Any other node *requires*
    /// its parent to be resolvable: an orphan promoted to ``roots`` by
    /// ``buildTree(from:)`` (a non-nil `parentId` with no matching node) has
    /// no ancestor data to truncate, so this throws rather than silently
    /// returning `ownEntries` alone — even when ``SessionNode/forkedAtEntryCount``
    /// happens to be known, since a real cut point with nothing to apply it
    /// to is not usable data (see ``TranscriptTreeError/parentUnresolvable(_:)``).
    private func effectiveEntryEvents(for node: SessionNode) throws -> [TranscriptEvent] {
        let ownEntries = try entryKindEvents(for: node)
        guard let parentId = node.parentId else {
            return ownEntries
        }
        guard let parent = nodesById[parentId] else {
            throw TranscriptTreeError.parentUnresolvable(node.id)
        }
        guard let forkedAtEntryCount = node.forkedAtEntryCount else {
            throw TranscriptTreeError.forkedAtEntryCountUnknown(node.id)
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

    /// One session's identity, lineage, and directory — resolved from either
    /// the index or the fallback — before ``buildTree(from:)`` links flat
    /// nodes into the recursive ``SessionNode`` tree.
    private struct RawNode {
        let id: ULID
        let parentId: ULID?
        let forkedAtEntryCount: Int?
        let directory: URL
    }

    /// Links flat ``RawNode``s into the recursive ``SessionNode`` tree:
    /// groups by ``RawNode/parentId``, then recursively builds each node's
    /// children before the node itself, so children (and roots) come out
    /// ordered by id.
    ///
    /// A node whose ``RawNode/parentId`` is non-nil but does not match any
    /// other node's id is treated as a root for traversal purposes — its own
    /// ``SessionNode/parentId`` still honestly reports the parent it was
    /// forked from, but since that parent cannot be resolved in this loaded
    /// tree, it (and its whole subtree) would otherwise be unreachable from
    /// ``roots``/``session(_:)``/``children(of:)`` entirely. This matters
    /// most for the index-less fallback: a session that forked a child before
    /// ever generating writes no `transcript.jsonl` of its own (see
    /// ``RoutedSessionActor``'s lazy `session` meta event), so the child's
    /// declared parent may genuinely have no discoverable node at all.
    ///
    /// - Parameter rawNodes: Every session's flat identity/lineage/directory,
    ///   from either the index or the fallback.
    /// - Returns: The tree's roots and a flat id-keyed lookup of every node.
    private static func buildTree(
        from rawNodes: [RawNode]
    ) -> (roots: [SessionNode], nodesById: [ULID: SessionNode]) {
        let rawById = Dictionary(uniqueKeysWithValues: rawNodes.map { ($0.id, $0) })
        var childIdsByParent: [ULID: [ULID]] = [:]
        var rootIds: [ULID] = []
        for raw in rawNodes {
            if let parentId = raw.parentId, rawById[parentId] != nil {
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
                forkedAtEntryCount: raw.forkedAtEntryCount,
                directory: raw.directory,
                children: children
            )
            nodesById[id] = node
            return node
        }

        let roots = rootIds.sorted().compactMap(build)
        return (roots, nodesById)
    }

    // MARK: - Index-less fallback

    /// Enumerates every nested `transcript.jsonl` under `routerDirectory` and
    /// decodes each one's first line to recover its session's id and
    /// parent — the lineage a missing index can no longer supply directly.
    /// ``SessionNode/forkedAtEntryCount`` is unknowable this way, so every
    /// returned node carries `nil` there.
    ///
    /// - Parameter routerDirectory: The router's recording root to search.
    /// - Returns: One raw node per discovered `transcript.jsonl`.
    /// - Throws: If a discovered file cannot be read or its first line cannot
    ///   be decoded.
    private static func fallbackRawNodes(under routerDirectory: URL) throws -> [RawNode] {
        let decoder = JSONDecoder()
        return try transcriptFileURLs(under: routerDirectory).compactMap { fileURL -> RawNode? in
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first else {
                return nil
            }
            let firstEvent = try decoder.decode(TranscriptEvent.self, from: Data(firstLine.utf8))
            return RawNode(
                id: firstEvent.sessionId,
                parentId: firstEvent.parentId,
                forkedAtEntryCount: nil,
                directory: fileURL.deletingLastPathComponent()
            )
        }
    }

    /// Finds every `transcript.jsonl` nested at any depth under `directory` —
    /// the same enumeration ``MergedTranscript`` performs, kept file-local
    /// here rather than shared, matching this module's existing precedent
    /// (see the header comment on ``sessionIndexFileName``, above).
    ///
    /// - Parameter directory: The recording root to search.
    /// - Returns: The discovered file URLs, in no particular order.
    private static func transcriptFileURLs(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == transcriptFileName {
            files.append(url)
        }
        return files
    }
}
