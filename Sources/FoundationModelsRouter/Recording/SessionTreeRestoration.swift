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
    /// (its ``SessionNode/parentId`` is non-nil).
    ///
    /// Restoration is a whole-tree operation rooted at the root id alone — a
    /// fork is restored only as part of restoring its root, never
    /// individually.
    case notARootSession(ULID)

    /// The calling handle's router has no durable transcripts root
    /// (recording to memory/none), so there is nothing on disk to restore.
    case noDurableRecordingsRoot

    /// `session`'s recorded ``SessionSidecar/slot`` has no corresponding
    /// generation handle on the restoring profile — today, only
    /// ``ModelSlot/embedding``, since a session is only ever vended from a
    /// ``ModelSlot/standard``/``ModelSlot/flash`` generation handle.
    case slotNotInProfile(session: ULID, slot: ModelSlot)

    /// `session`'s recorded ``SessionSidecar/model`` does not match the
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
    /// Each node's model/slot is resolved from its own ``SessionSidecar``
    /// against *this call's* owning profile — not necessarily this handle's own
    /// slot, since a tree's nodes may in principle be recorded against either
    /// generation slot: `.standard` records resolve through the owning
    /// profile's ``LanguageModelProfile/standard``, `.flash` through
    /// ``LanguageModelProfile/flash``. A slot with no generation handle, or a
    /// resident model that does not match the recorded one, is a typed error
    /// naming the offending session — never a crash. Each restored session's `persistedEntryCount` starts at its
    /// reconstructed effective-transcript entry count, so its first live turn
    /// persists only what is genuinely new. `instructions`/``Grammar`` are
    /// rehydrated from the node's own ``SessionSidecar``, so a restored
    /// guided session constrains its next turn as the original did — for
    /// ``Grammar/jsonSchema(_:)``.
    ///
    /// **Known limitation: the `.ebnf` grammar case.**
    /// ``SessionSidecar/grammar`` persists only the grammar's `source`
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
    /// **No sidecar rewrite.** This never writes a ``SessionSidecar`` — every
    /// node's sidecar was written when the tree was originally created (root
    /// vend and each fork), it is write-once, and restoration only *reads* it.
    /// Each restored node is built with ``SessionSidecarOrigin/restored(_:)``,
    /// which is what says so: unlike a new session, a restored one lands no
    /// sidecar of its own at init, and the writer it carries travels only for
    /// the forks taken from it afterward, which write theirs normally.
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
    ///     need to rebuild. Defaults to ``CustomSegmentRegistry/routerDefault``
    ///     (pre-seeded with ``CompactionSegment``), so a tree containing a
    ///     compacted session restores with no caller setup.
    /// - Returns: The restored tree, rooted at the session named by `rootId`.
    /// - Throws: ``SessionTreeRestorationError`` for every documented
    ///   restoration-specific failure; ``TranscriptTreeError`` /
    ///   ``TranscriptReconstructionError`` for anything
    ///   ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:registry:)`` throws.
    public func restoreSessionTree(
        root rootId: ULID,
        registry: CustomSegmentRegistry = .routerDefault
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

        let routerDirectory = recordingsRoot.appendingPathComponent(
            routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        guard let rootNode = tree.session(rootId) else {
            throw TranscriptTreeError.sessionNotFound(rootId)
        }
        guard rootNode.parentId == nil else {
            throw SessionTreeRestorationError.notARootSession(rootId)
        }

        var sessionsById: [ULID: RoutedSession] = [:]
        func restore(_ node: SessionNode) throws -> RoutedSession {
            let slot = node.sidecar.slot
            let model = node.sidecar.model
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
            // `SessionSidecar.grammar` is only the grammar's `source`
            // string — it does not distinguish `.jsonSchema(_:)` from
            // `.ebnf(_:)`, which share that representation — so a session
            // originally guided by `.ebnf(_:)` restores under the
            // `.jsonSchema` case instead (see this function's doc comment,
            // "Known limitation: `.ebnf` grammar case").
            let grammar = node.sidecar.grammar.map(Grammar.jsonSchema)

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
                instructions: node.sidecar.instructions,
                grammar: grammar,
                // Restoration has no live tool list to thread — mirrors
                // `LoadedLLMContainer.makeSession(transcript:)`'s own
                // hardcoded `tools: []` a few lines above; see its doc
                // comment ("this handle wraps `container.languageModel`
                // directly, so the *caller* supplies real tools" for the
                // resuming-handle path that actually can).
                tools: [],
                serialGate: routedLLM.serialGate,
                forkAdmissionGate: routedLLM.forkAdmissionGate,
                holdsAdmissionPermit: false,
                persistedEntryCount: transcript.count,
                // Restored, not new: this node's sidecar is the write-once one
                // read from disk just above, never rewritten. The writer travels
                // only for forks taken from the restored session.
                sidecarOrigin: SessionSidecarOrigin.restored(under: routedLLM.durableRecording)
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
