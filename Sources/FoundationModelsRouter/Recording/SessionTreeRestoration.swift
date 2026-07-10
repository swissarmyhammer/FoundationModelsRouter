import Foundation
import FoundationModels

/// A failure restoring a session tree from disk via
/// ``RoutedModel/restoreSessionTree(root:registry:)``.
///
/// Restoration is rooted at a *root* session id — callers never restore an
/// individual fork — and every node's recorded model/slot must resolve
/// cleanly against the restoring profile; every foreseeable mismatch is a
/// typed, descriptive error here rather than a crash (see plan.md's
/// "Transcript fidelity" section, "Reconstruction end-to-end").
public enum SessionTreeRestorationError: Error, Equatable, LocalizedError {
    /// `id` names a session that exists in the loaded tree but is not a root
    /// (its ``SessionNode/parentId`` is non-nil). Restoration is a
    /// whole-tree operation rooted at the root id alone — a fork is restored
    /// only as part of restoring its root, never individually.
    case notARootSession(ULID)

    /// The calling handle's router has no durable transcripts root
    /// (recording to memory/none), so there is nothing on disk to restore.
    case noDurableRecordingsRoot

    /// `session`'s ``SessionIndexRecord`` has a `nil` ``SessionIndexRecord/slot``
    /// or ``SessionIndexRecord/model`` — either the record was never
    /// stamped with one (should not happen for a session vended through the
    /// normal `makeSession`/`fork` paths), or no `sessions.jsonl` exists at
    /// all and the tree was loaded through ``TranscriptTree/load(under:)``'s
    /// index-less fallback, which cannot recover either field.
    case missingSlotOrModel(session: ULID)

    /// `session`'s recorded ``SessionIndexRecord/slot`` has no corresponding
    /// generation handle on the restoring profile — today, only
    /// ``ModelSlot/embedding``, since a session is only ever vended from a
    /// ``ModelSlot/standard``/``ModelSlot/flash`` generation handle.
    case slotNotInProfile(session: ULID, slot: ModelSlot)

    /// `session`'s recorded ``SessionIndexRecord/model`` does not match the
    /// model resident in `slot` on the restoring profile — the recording was
    /// made against a different model than the one now loaded for that slot.
    case modelMismatch(session: ULID, slot: ModelSlot, recorded: ModelRef, resident: ModelRef)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .notARootSession(let id):
            return """
                Session \(id.description) is not a root session; restoreSessionTree(root:registry:) \
                restores only whole trees rooted at a root session's id.
                """
        case .noDurableRecordingsRoot:
            return "This model has no durable transcripts root (recording to memory/none); there is nothing on disk to restore."
        case .missingSlotOrModel(let session):
            return """
                Session \(session.description)'s index record has no recorded slot/model, so its \
                container cannot be selected for restoration.
                """
        case .slotNotInProfile(let session, let slot):
            return """
                Session \(session.description) recorded slot \(slot.rawValue), which has no generation \
                handle on the restoring profile.
                """
        case .modelMismatch(let session, let slot, let recorded, let resident):
            return """
                Session \(session.description) was recorded against model \(recorded.stringValue) in slot \
                \(slot.rawValue), but the restoring profile's resident model for that slot is \
                \(resident.stringValue).
                """
        }
    }
}

/// A restored fork tree: every session that was live under a router's
/// recorded root, reconstructed by ``RoutedModel/restoreSessionTree(root:registry:)``
/// as live, usable ``RoutedSession``s synced with what is on disk.
///
/// Mirrors ``TranscriptTree``'s own shape (``session(_:)``, ``children(of:)``),
/// but over live, driveable sessions instead of value-typed nodes.
public struct RestoredSessionTree: Sendable {
    /// The restored root session.
    public let root: RoutedSession

    /// Every restored session (the root and all its descendants), keyed by id.
    private let sessionsById: [ULID: RoutedSession]

    /// The loaded tree structure restoration walked, reused here only for
    /// its parent/child linkage.
    private let tree: TranscriptTree

    /// Creates a restored session tree.
    init(root: RoutedSession, sessionsById: [ULID: RoutedSession], tree: TranscriptTree) {
        self.root = root
        self.sessionsById = sessionsById
        self.tree = tree
    }

    /// Looks up a restored session anywhere in the tree by its id.
    ///
    /// - Parameter id: The session's span id.
    /// - Returns: The matching restored session, or `nil` if `id` was not
    ///   part of the restored tree.
    public func session(_ id: ULID) -> RoutedSession? {
        sessionsById[id]
    }

    /// A restored session's direct forks, ordered by id (creation order).
    ///
    /// - Parameter id: The parent session's span id.
    /// - Returns: Its restored children, or an empty array if `id` is
    ///   unknown or a leaf.
    public func children(of id: ULID) -> [RoutedSession] {
        tree.children(of: id).compactMap { sessionsById[$0.id] }
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// Restores a whole session tree from disk, rooted at a root session's id.
    ///
    /// Given a **root** session's id (forks are never restored individually —
    /// see ``SessionTreeRestorationError/notARootSession(_:)``), this loads the
    /// ``TranscriptTree`` under this handle's router recording root, computes
    /// every node's ``TranscriptTree/effectiveTranscript(forSession:registry:)``,
    /// seeds one backend per node via ``LoadedLLMContainer/makeSession(transcript:)``,
    /// and constructs a live ``RoutedSessionActor`` per node — preserving each
    /// node's original id, parent id, and recording directory, so a turn driven
    /// on a restored node appends to its existing `transcript.jsonl` rather than
    /// starting a new one.
    ///
    /// Each node's model/slot is resolved from its own ``SessionIndexRecord``
    /// against *this call's* owning profile — not necessarily this handle's own
    /// slot, since a tree's nodes may in principle be recorded against either
    /// generation slot: `.standard` records resolve through the owning
    /// profile's ``LanguageModelProfile/standard``, `.flash` through
    /// ``LanguageModelProfile/flash``. A `nil` slot/model, a slot with no
    /// generation handle, or a resident model that does not match the
    /// recorded one is a typed error naming the offending session — never a
    /// crash. Each restored session's `persistedEntryCount` starts at its
    /// reconstructed effective-transcript entry count, so its first live turn
    /// persists only what is genuinely new. `instructions`/``Grammar`` are
    /// rehydrated from the node's own ``SessionIndexRecord``, so a restored
    /// guided session constrains its next turn as the original did — for
    /// ``Grammar/jsonSchema(_:)``.
    ///
    /// **Known limitation: the `.ebnf` grammar case.**
    /// ``SessionIndexRecord/grammar`` persists only the grammar's `source`
    /// string, not which ``Grammar`` case it came from (``Grammar/jsonSchema(_:)``
    /// vs ``Grammar/ebnf(_:)`` share the same on-disk representation — see
    /// that type's `source`), so rehydration always reconstructs
    /// `.jsonSchema(source)`. A session originally guided by `.ebnf(_:)`
    /// restores with its grammar source intact but under the wrong case;
    /// its next turn is validated and recorded as `.jsonSchema`, which can
    /// behave differently from the original `.ebnf` turn (see
    /// ``Grammar/validateForXGrammar()``) — this mirrors the codebase's
    /// other honestly-documented restoration losses (plan.md's "Transcript
    /// fidelity" section, "Honest fidelity scope"). In practice this does
    /// not regress the live MLX backend, which already unconditionally
    /// rejects `.ebnf` (``GuidedRequestError/ebnfNotSupportedByLanguageModelSession``),
    /// so no `.ebnf`-guided session could ever have driven a real turn to
    /// restore in the first place; a stub/test backend that does support raw
    /// EBNF is the only place this is currently observable (see
    /// `SessionTreeRestorationTests.restoredEbnfGrammarReconstructsAsJSONSchema`).
    ///
    /// **No session-index re-append.** This never calls
    /// ``SessionIndexWriter/append(_:)`` — every node's record already exists
    /// in `sessions.jsonl` from when the tree was originally created (root vend
    /// and each fork), and restoration only *reads* that index. A restored
    /// session's own `sessionIndexWriter` is still threaded through, so a
    /// brand-new fork taken from a restored session afterward appends normally,
    /// exactly like any other fork.
    ///
    /// **Fork-admission gates.** Every restored node is constructed with
    /// `holdsAdmissionPermit: false` and shares this profile's normal
    /// per-model `serialGate`/`forkAdmissionGate` — restoring does not consume
    /// a fork-admission permit, because admission bounds in-flight *new* forks,
    /// and a restored session is a reconstruction of one that was already
    /// admitted (and, for a root, never needed admission at all).
    ///
    /// - Parameters:
    ///   - rootId: The root session's span id to restore the whole tree from.
    ///   - registry: The registered ``PersistableCustomSegment`` types a
    ///     `.custom` segment anywhere in the tree's recorded transcripts may
    ///     need to rebuild. Defaults to an empty registry.
    /// - Returns: The restored tree, rooted at the session named by `rootId`.
    /// - Throws: ``SessionTreeRestorationError`` for every documented
    ///   restoration-specific failure; ``TranscriptTreeError`` /
    ///   ``TranscriptReconstructionError`` for anything
    ///   ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:registry:)`` throws.
    public func restoreSessionTree(
        root rootId: ULID,
        registry: CustomSegmentRegistry = CustomSegmentRegistry()
    ) async throws -> RestoredSessionTree {
        // The handle references its profile weakly, mirroring
        // `makeSession(instructions:workingDirectory:)`'s own invariant: a
        // session (restored or not) is what retains the profile, so the
        // profile must still be alive when this is called.
        guard let owningProfile = owningProfileBox.current else {
            preconditionFailure(
                "restoreSessionTree requires a live owning LanguageModelProfile; the handle holds it weakly and the profile was released before this call"
            )
        }
        guard let recordingsRoot else {
            throw SessionTreeRestorationError.noDurableRecordingsRoot
        }

        let routerDirectory = recordingsRoot.appendingPathComponent(routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        guard let rootNode = tree.session(rootId) else {
            throw TranscriptTreeError.sessionNotFound(rootId)
        }
        guard rootNode.parentId == nil else {
            throw SessionTreeRestorationError.notARootSession(rootId)
        }

        let recordsById = Dictionary(
            uniqueKeysWithValues: try SessionIndexWriter.read(under: routerDirectory).map { ($0.sessionId, $0) }
        )

        var sessionsById: [ULID: RoutedSession] = [:]
        func restore(_ node: SessionNode) throws -> RoutedSession {
            guard let record = recordsById[node.id], let slot = record.slot, let model = record.model else {
                throw SessionTreeRestorationError.missingSlotOrModel(session: node.id)
            }
            let routedLLM: RoutedLLM
            switch slot {
            case .standard:
                routedLLM = owningProfile.standard
            case .flash:
                routedLLM = owningProfile.flash
            case .embedding:
                throw SessionTreeRestorationError.slotNotInProfile(session: node.id, slot: slot)
            }
            guard routedLLM.chosen == model else {
                throw SessionTreeRestorationError.modelMismatch(
                    session: node.id,
                    slot: slot,
                    recorded: model,
                    resident: routedLLM.chosen
                )
            }

            let transcript = try tree.effectiveTranscript(forSession: node.id, registry: registry)
            let backend = routedLLM.container.makeSession(transcript: transcript)
            // `SessionIndexRecord.grammar` is only the grammar's `source`
            // string — it does not distinguish `.jsonSchema(_:)` from
            // `.ebnf(_:)`, which share that representation — so a session
            // originally guided by `.ebnf(_:)` restores under the
            // `.jsonSchema` case instead (see this function's doc comment,
            // "Known limitation: `.ebnf` grammar case").
            let grammar = record.grammar.map(Grammar.jsonSchema)

            let session = makeRoutedSessionActor(
                profile: owningProfile,
                routerId: routedLLM.routerId,
                id: node.id,
                parentId: node.parentId,
                recordingDirectory: node.directory,
                workingDirectory: node.directory,
                backend: backend,
                slot: slot,
                model: model,
                recorder: routedLLM.recorder,
                instructions: record.instructions,
                grammar: grammar,
                serialGate: routedLLM.serialGate,
                forkAdmissionGate: routedLLM.forkAdmissionGate,
                holdsAdmissionPermit: false,
                persistedEntryCount: transcript.count,
                indexPath: record.path,
                sessionIndexWriter: routedLLM.sessionIndexWriter,
                pendingIndexWrite: nil
            )
            sessionsById[node.id] = session
            for child in node.children {
                _ = try restore(child)
            }
            return session
        }

        let root = try restore(rootNode)
        return RestoredSessionTree(root: root, sessionsById: sessionsById, tree: tree)
    }
}
