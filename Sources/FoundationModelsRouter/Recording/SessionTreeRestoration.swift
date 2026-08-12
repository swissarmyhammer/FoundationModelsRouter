import Foundation
import FoundationModels

/// A failure restoring a session tree from disk via
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``.
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

/// What ``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``
/// could not re-apply from the recorded configuration envelopes (task
/// ^ne5g9jn) — the typed report that replaces silence about a restored
/// tree's missing parts.
///
/// The value-typed configuration a ``SessionSidecar/configuration`` envelope
/// records — the auto-compaction budget and prompt, the summarization stage,
/// and the discovery-priming opt-in — always re-applies, so it never appears
/// here. The tool instances are the one part a recording cannot carry: the
/// envelope records their names, the caller supplies live instances through
/// the restore call's `tools:` parameter, and every recorded name no
/// supplied tool answers to lands in ``missingTools`` — one row per session
/// and name, so the caller learns exactly what to re-supply. A recording
/// made before the envelope existed records no names, so it reports nothing
/// (today's behavior, unchanged).
public struct SessionConfigurationRestorationReport: Sendable, Equatable {
    /// One recorded tool name no supplied tool answered to, on one restored
    /// session.
    public struct MissingTool: Sendable, Equatable {
        /// The restored session whose envelope recorded the name.
        public let session: ULID

        /// The recorded ``FoundationModels/Tool/name`` the caller did not
        /// supply an instance for.
        public let toolName: String
    }

    /// Every recorded tool name that no supplied tool answered to, in
    /// restoration walk order (each parent before its children), or empty
    /// when every recorded name matched — including when nothing was
    /// recorded at all.
    public let missingTools: [MissingTool]

    /// Whether every recorded configuration item came back — `true` exactly
    /// when ``missingTools`` is empty.
    public var isComplete: Bool { missingTools.isEmpty }
}

/// A restored fork tree: every session that was live under a router's
/// recorded root, reconstructed by ``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``
/// as live, usable ``RoutedSession``s synced with what is on disk.
///
/// Mirrors ``TranscriptTree``'s own shape (``session(_:)``, ``children(of:)``),
/// but over live, driveable sessions instead of value-typed nodes.
public struct RestoredSessionTree: Sendable {
    /// One restored session whose recorded working context differs from the
    /// context the restoring profile resolved (task ^xky3j8w).
    ///
    /// A restored session always runs against ``resolved`` — the physical
    /// window the live backend was actually loaded with — so
    /// ``RoutedSession/contextFill``'s denominator is the live figure, not
    /// the recorded one. This row is the typed warning that the denominator
    /// changed across the restore: a session recorded near-full against a
    /// larger window may overflow (or fold) sooner than it did originally.
    /// It is deliberately a report row rather than an error like
    /// ``SessionTreeRestorationError/modelMismatch(session:slot:recorded:resident:)``:
    /// the same model legitimately resolves a different context on a machine
    /// whose RAM ladder settled on another rung, and refusing the restore
    /// would block a session that still works.
    public struct ContextMismatch: Sendable, Equatable {
        /// The restored session whose ``SessionSidecar/context`` differs.
        public let session: ULID

        /// The working context, in tokens, the session was recorded at.
        public let recorded: Int

        /// The working context, in tokens, the restoring profile resolved —
        /// the figure the restored session actually runs against.
        public let resolved: Int
    }

    /// The restored root session.
    public let root: RoutedSession

    /// What the restore could not re-apply from the recorded configuration
    /// envelopes — see ``SessionConfigurationRestorationReport``.
    public let configurationReport: SessionConfigurationRestorationReport

    /// Every restored session whose recorded working context differs from
    /// the live resolution's, in restoration walk order (each parent before
    /// its children) — or empty when every node's recorded context matches.
    /// See ``ContextMismatch`` for why this is a warning, not an error.
    public let contextMismatches: [ContextMismatch]

    /// Every restored session (the root and all its descendants), keyed by id.
    private let sessionsById: [ULID: RoutedSession]

    /// The loaded tree structure restoration walked, reused here only for
    /// its parent/child linkage.
    private let tree: TranscriptTree

    /// Creates a restored session tree.
    init(
        root: RoutedSession,
        sessionsById: [ULID: RoutedSession],
        tree: TranscriptTree,
        configurationReport: SessionConfigurationRestorationReport,
        contextMismatches: [ContextMismatch]
    ) {
        self.root = root
        self.sessionsById = sessionsById
        self.tree = tree
        self.configurationReport = configurationReport
        self.contextMismatches = contextMismatches
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
    /// every node's ``TranscriptTree/effectiveTranscript(forSession:registry:view:)``,
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
    /// per-model `generationGate`/`forkAdmissionGate` — restoring does not consume
    /// a fork-admission permit, because admission bounds in-flight *new* forks,
    /// and a restored session is a reconstruction of one that was already
    /// admitted (and, for a root, never needed admission at all).
    ///
    /// **Orphaned journaled runs come back `.lost`.** For each restored
    /// node, the effective recorded stream is scanned for journaled runs
    /// that carry a non-terminal ``OperationEventSegment`` (`.progress` or
    /// `.elicitation`) with no `.completed` for the same
    /// `(tool, correlationID)` pair anywhere in that stream: those runs died
    /// with the crashed process (their memory-only ``SessionMailbox`` gone
    /// before ``RoutedSessionActor/close()``'s sweep could journal a
    /// terminal), so exactly one terminal `.completed` event with outcome
    /// ``OperationOutcome/lost`` per orphaned run is manufactured and posted
    /// to that node's fresh outbox — the next turn's drain journals it
    /// durably, so the record has no holes and the model learns the run's
    /// outcome is unknowable. The scan is deliberately *per node*, over that
    /// node's own effective view (the same span its model sees): an
    /// ancestor's orphaned run therefore manufactures one `.lost` on every
    /// restored node whose inherited prefix carries the dangling
    /// non-terminal — each node's model needs its own closure — and a run
    /// whose `.completed` the parent journaled only after this node's fork
    /// cut point is `.lost` from this node's view, because the completion
    /// never entered its conversation. See
    /// ``TranscriptTree/lostRunTerminalEvents(in:)``.
    ///
    /// **Decided restore losses and loud failures (task ^xky3j8w).** Each of
    /// these was examined and decided, so none of them is silent by
    /// accident:
    ///
    /// - ``SessionSidecar/agentSpawn`` is **not re-applied**, because there
    ///   is nothing to re-apply it to: the spawn context is write-once
    ///   creation metadata that ``RoutedSessionActor``'s initializer
    ///   consumes for the sidecar write and never stores, and
    ///   ``RoutedSession`` exposes no such live state. The recorded fact
    ///   stays on disk and stays readable from the loaded tree
    ///   (``SessionNode/sidecar``).
    /// - ``SessionSidecar/context`` is compared against the live
    ///   resolution's context and every difference is reported in
    ///   ``RestoredSessionTree/contextMismatches`` — see
    ///   ``RestoredSessionTree/ContextMismatch`` for why the live figure
    ///   always wins and why a difference is a warning, not an error.
    /// - A **deleted child directory** cannot be detected: the layout is the
    ///   only structure on disk, so a deleted child is byte-identical to a
    ///   child that never existed. The tree loads clean without it (a
    ///   missing *parent* is loud — see ``TranscriptTree/load(under:)``).
    /// - A **corrupt custom segment** — a ``CompactionSegment`` checkpoint
    ///   or an ``OperationEventSegment`` whose recorded content no longer
    ///   decodes — fails the restore loudly with
    ///   ``TranscriptReconstructionError/entryReconstructionFailed(session:seq:underlying:)``
    ///   from the entry mapping, never a silent partial restore: the
    ///   nil-not-throw fallbacks in `compactionSegmentContent(in:)` and
    ///   `operationEvents(in:)` only affect pre-mapping filtering and the
    ///   orphan scan, both of which run at or after the mapping that
    ///   throws.
    /// - A **corrupt transcript line** before the file's last is the typed
    ///   ``TranscriptTreeError/transcriptLineCorrupt(session:file:)``,
    ///   naming the session and file; a torn FINAL line — the expected
    ///   crash artifact — is dropped with a logged warning instead (see
    ///   `TranscriptLineDecoding`).
    ///
    /// - Parameters:
    ///   - rootId: The root session's span id to restore the whole tree from.
    ///   - registry: The registered ``PersistableCustomSegment`` types a
    ///     `.custom` segment anywhere in the tree's recorded transcripts may
    ///     need to rebuild. Defaults to ``CustomSegmentRegistry/routerDefault``
    ///     (pre-seeded with ``CompactionSegment``), so a tree containing a
    ///     compacted session restores with no caller setup.
    ///   - tools: The tools every restored node's model can call, applied
    ///     uniformly across the whole tree — a tool instance cannot be
    ///     recorded, so this is how the caller re-supplies the live tool
    ///     package the original conversation ran with. Each node's recorded
    ///     ``SessionConfiguration/Persistable/toolNames`` (task ^ne5g9jn)
    ///     are matched against these instances' ``FoundationModels/Tool/name``s,
    ///     and every recorded name with no supplied instance is reported in
    ///     ``RestoredSessionTree/configurationReport`` — so a missing tool is
    ///     named, never silent. Each restored node gets its own fresh
    ///     ``RoutedSession/outbox``, with every String-output tool wrapped
    ///     in its own per-node detachment layer posting there (a
    ///     non-String-output tool gets the binding-only
    ///     ``ContextBindingTool``, posting there too) — exactly the
    ///     per-session instancing
    ///     ``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    ///     performs for a fresh session — so a node's tool never posts to a
    ///     sibling or ancestor's outbox. Defaults to no tools.
    ///   - recordingRoot: The exact directory to load the tree from, or `nil`
    ///     for this handle's router-level default (task ke41yth). Mirrors
    ///     ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``:
    ///     pass the same root a session was vended with to restore it.
    ///     Omitted (`nil`), this loads today's nested
    ///     `<recordingsRoot>/<routerId>/` layout, throwing
    ///     ``SessionTreeRestorationError/noDurableRecordingsRoot`` when this
    ///     handle has no durable transcripts root — reproducing every
    ///     existing caller's behavior byte-for-byte. Supplied, this loads
    ///     `recordingRoot` directly — the flat, no-routerId-segment layout a
    ///     caller-supplied `recordingRoot` at session-creation time
    ///     produces — with no dependency on this handle's own recordings
    ///     root at all.
    ///
    /// **Configuration re-application (task ^ne5g9jn).** Each node's recorded
    /// ``SessionSidecar/configuration`` envelope is re-applied onto its
    /// restored actor: ``RoutedSessionActor/autoCompactionBudget`` and
    /// ``RoutedSessionActor/autoCompactionPrompt`` (task 8213x39) come back
    /// as recorded — a budget also re-wires its
    /// ``TokenBudget/toolOutputLimit`` capping into the node's instanced
    /// tool chain, exactly as at vend time — and
    /// ``RoutedSessionActor/summarization`` and
    /// ``RoutedSessionActor/discoveryPriming`` (`^s4405wc`) come back as
    /// recorded too, so a session saved with a budget folds where the
    /// original folded instead of overflowing. Auto-compaction needs no
    /// re-supplied summarizer: its folds pick one at fold time (the
    /// profile's flash slot, then the node's own model, then the
    /// deterministic stages). The recorded tool *names* are matched against
    /// the supplied `tools` and the misses reported — see `tools` above.
    /// A recording made before the envelope existed carries none, and
    /// restores exactly as it always has: `nil` budget,
    /// ``CompactionPrompt/default``, `Summarization()`, `nil` priming, and
    /// an empty report.
    /// - Returns: The restored tree, rooted at the session named by `rootId`,
    ///   carrying ``RestoredSessionTree/configurationReport`` and
    ///   ``RestoredSessionTree/contextMismatches``.
    /// - Throws: ``SessionTreeRestorationError`` for every documented
    ///   restoration-specific failure; ``TranscriptTreeError`` /
    ///   ``TranscriptReconstructionError`` for anything
    ///   ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:registry:view:)`` throws.
    public func restoreSessionTree(
        root rootId: ULID,
        recordingRoot: URL? = nil,
        registry: CustomSegmentRegistry = .routerDefault,
        tools: [any Tool] = []
    ) async throws -> RestoredSessionTree {
        // The handle references its profile weakly, mirroring
        // `makeSession(instructions:workingDirectory:)`'s own invariant: a
        // session (restored or not) is what retains the profile, so the
        // profile must still be alive when this is called.
        let owningProfile = requireOwningProfile(apiName: "restoreSessionTree")

        // `recordingRoot` supplied: that directory itself holds the tree's
        // session directories directly — the flat, no-routerId-segment
        // layout `makeSession(recordingRoot:)` writes (task ke41yth) — so it
        // is loaded as-is, with no dependency on this handle's own
        // `recordingsRoot`. Omitted: today's nested
        // `<recordingsRoot>/<routerId>/` layout, unchanged.
        let treeDirectory: URL
        if let recordingRoot {
            treeDirectory = recordingRoot
        } else {
            guard let recordingsRoot else {
                throw SessionTreeRestorationError.noDurableRecordingsRoot
            }
            treeDirectory = recordingsRoot.appendingPathComponent(
                routerId.description, isDirectory: true)
        }
        let tree = try TranscriptTree.load(under: treeDirectory)
        guard let rootNode = tree.session(rootId) else {
            throw TranscriptTreeError.sessionNotFound(rootId)
        }
        guard rootNode.parentId == nil else {
            throw SessionTreeRestorationError.notARootSession(rootId)
        }

        var sessionsById: [ULID: RoutedSession] = [:]
        // The rehydration match (task ^ne5g9jn): each node's recorded tool
        // names are checked against the supplied instances' names, and every
        // recorded name with no supplied instance is collected here — one
        // row per node and name, in walk order — for the returned
        // ``SessionConfigurationRestorationReport``.
        let suppliedToolNames = Set(tools.map(\.name))
        var missingTools: [SessionConfigurationRestorationReport.MissingTool] = []
        // The recorded-context check (task ^xky3j8w): a node whose recorded
        // ``SessionSidecar/context`` differs from the live resolution's is
        // collected here — one row per node, in walk order — for the
        // returned ``RestoredSessionTree/contextMismatches``. See
        // ``RestoredSessionTree/ContextMismatch`` for why this is a typed
        // warning rather than a `modelMismatch`-style error.
        var contextMismatches: [RestoredSessionTree.ContextMismatch] = []
        func restore(_ node: SessionNode) async throws -> RoutedSession {
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

            // The restored session runs against the live resolution's
            // context — the physical window `routedLLM`'s backend was
            // actually loaded with — never the recorded figure. A recorded
            // context the live figure no longer matches is reported, not
            // silently adopted and not an error (task ^xky3j8w; see
            // ``RestoredSessionTree/ContextMismatch``).
            let resolvedContextTokens = routedLLM.resolution.contextTokens
            if node.sidecar.context != resolvedContextTokens {
                contextMismatches.append(
                    RestoredSessionTree.ContextMismatch(
                        session: node.id,
                        recorded: node.sidecar.context,
                        resolved: resolvedContextTokens
                    ))
            }

            let transcript = try tree.effectiveTranscript(forSession: node.id, registry: registry)

            // The node's recorded configuration envelope (task ^ne5g9jn),
            // or `nil` for a recording made before the envelope existed —
            // which restores with the pre-envelope defaults below, exactly
            // as it always has (see ``SessionSidecar/configuration``).
            let configuration = node.sidecar.configuration
            // The rehydration match: every recorded tool name with no
            // supplied instance is reported, never silently dropped.
            for toolName in configuration?.toolNames ?? []
            where !suppliedToolNames.contains(toolName) {
                missingTools.append(
                    SessionConfigurationRestorationReport.MissingTool(
                        session: node.id, toolName: toolName))
            }

            // Per-node event wiring plus per-session tool instancing —
            // the shared helper mints every restored node its own fresh
            // outbox and mailbox, so a tool's events post to *this* node's
            // own outbox rather than a sibling or ancestor's, and parked
            // runs and pending elicitations never survive a restore (see
            // ``RoutedSession/mailbox``).
            // This site's chain is detach only, plus capping when the
            // node's recorded budget carries a `toolOutputLimit` —
            // deliberately no fork (restoration re-instances from the
            // caller's originals, it never derives one live session from
            // another) — mirroring the root site's detach → cap; the fork
            // site is fork → detach → cap (task ^k4nygqa; see
            // ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
            // and ``RoutedSessionActor/fork(workingDirectory:)``).
            let (outbox, mailbox, instancedTools) = makeSessionToolWiring(
                tools,
                sessionID: node.id,
                cappedToTokenLimit: configuration?.budget?.toolOutputLimit
            )
            let backend = routedLLM.container.makeSession(transcript: transcript, tools: instancedTools)
            // ``RoutedSession/contextFill``'s restored numerator
            // (compaction_plan.md §1.5, checkpoint-aware restore
            // precedence): the newest stamped `.response` event's usage
            // recorded *after* the newest ``CompactionSegment`` checkpoint
            // among this session's *effective* recorded events (its own
            // file plus, for a fork, the inherited prefix of its
            // ancestors' — the same span `effectiveTranscript` above
            // reconstructs); when that checkpoint is itself the newest
            // thing, its own ``CompactionSegment/Content/tokensAfter``; when
            // there is no checkpoint at all, the newest stamp anywhere in
            // the effective stream (the pre-compaction behavior,
            // unchanged); else unknown — never a guess. See
            // ``TranscriptTree/restoredUsageState(in:)``.
            //
            // Deliberately ancestor-inclusive, not scoped to this node's own
            // file alone: a freshly restored fork with no turns of its own
            // yet should inherit its parent's last known fill rather than
            // report unknown, mirroring live `fork()`'s own choice to
            // inherit `usageState` from the session it forked from (see
            // ``RoutedSessionActor/fork(workingDirectory:)``).
            let effectiveEvents = try tree.effectiveEntryEvents(forSession: node.id)
            let usageState = TranscriptTree.restoredUsageState(in: effectiveEvents)
            // `SessionSidecar.grammar` is only the grammar's `source`
            // string — it does not distinguish `.jsonSchema(_:)` from
            // `.ebnf(_:)`, which share that representation — so a session
            // originally guided by `.ebnf(_:)` restores under the
            // `.jsonSchema` case instead (see this function's doc comment,
            // "Known limitation: `.ebnf` grammar case").
            let grammar = node.sidecar.grammar.map(Grammar.jsonSchema)

            // Crash-edge run-outcome durability (eventplan.md §"Elevation",
            // that plan's name for detachment):
            // a journaled run with a non-terminal recorded event (`.progress`
            // or `.elicitation`) and no `.completed` for the same
            // `(tool, correlationID)` pair anywhere in this node's effective
            // stream died with the crashed process — its memory-only mailbox
            // is gone, so no teardown sweep ever journaled a terminal event
            // for it (the orderly-shutdown case is
            // ``RoutedSessionActor/close()``'s ``SessionMailbox/sweep()``).
            // Manufacture exactly one terminal `.completed` with outcome
            // ``OperationOutcome/lost`` per orphaned run and post it to this
            // node's fresh outbox: the next turn's drain journals it durably,
            // so the record has no holes and the model learns the run died.
            // This is the only place `.lost` is manufactured outside an MCP
            // transport drop.
            for lostEvent in TranscriptTree.lostRunTerminalEvents(in: effectiveEvents) {
                await outbox.post(lostEvent)
            }

            let session = makeRoutedSessionActor(
                profile: owningProfile,
                routerId: routedLLM.routerId,
                id: node.id,
                parentId: node.parentId,
                recordingDirectory: node.directory,
                // Restored from the node's own sidecar (task 6j4bven
                // creation-metadata ask, task 6j4bven) rather than defaulted
                // to `node.directory`: a session vended with an overridden
                // working directory must reassemble against that same
                // directory, not silently fall back to its recording
                // directory, or a restored session's tools would resolve
                // files from the wrong place.
                workingDirectory: node.sidecar.workingDirectory,
                backend: backend,
                slot: slot,
                model: model,
                recorder: routedLLM.recorder,
                instructions: node.sidecar.instructions,
                grammar: grammar,
                // The per-node instanced tool list threaded to `backend`
                // above; `originalTools` retains the true, un-instanced
                // originals (this call's own `tools` parameter) so a later
                // `fork(workingDirectory:)` off this restored node can still
                // build its own fork-then-detach composed tool list, exactly
                // as it would from a freshly vended root session.
                tools: instancedTools,
                originalTools: tools,
                outbox: outbox,
                mailbox: mailbox,
                generationGate: routedLLM.generationGate,
                forkAdmissionGate: routedLLM.forkAdmissionGate,
                holdsAdmissionPermit: false,
                persistedEntryCount: transcript.count,
                // Restored, not new: this node's sidecar is the write-once one
                // read from disk just above, never rewritten. The writer travels
                // only for forks taken from the restored session.
                sidecarOrigin: SessionSidecarOrigin.restored(under: routedLLM.durableRecording),
                contextTokens: resolvedContextTokens,
                usageState: usageState,
                // The recorded configuration envelope re-applied (task
                // ^ne5g9jn): the budget, its prompt, the summarization
                // stage, and the priming opt-in come back as the node was
                // vended with them. A pre-envelope recording carries `nil`
                // and gets the same defaults it always restored with.
                autoCompactionBudget: configuration?.budget,
                autoCompactionPrompt: configuration?.compactionPrompt ?? .default,
                summarization: configuration?.summarization ?? Summarization(),
                discoveryPriming: configuration?.discoveryPriming
            )
            sessionsById[node.id] = session
            for child in node.children {
                _ = try await restore(child)
            }
            return session
        }

        let root = try await restore(rootNode)
        return RestoredSessionTree(
            root: root,
            sessionsById: sessionsById,
            tree: tree,
            configurationReport: SessionConfigurationRestorationReport(missingTools: missingTools),
            contextMismatches: contextMismatches
        )
    }
}

extension TranscriptTree {
    /// The identity of one journaled operation run: the emitting tool's name
    /// plus its tool-assigned `correlationID`. Correlation ids are opaque
    /// and tool-assigned, so they are only unique *within* one tool — this
    /// is the same pair identity ``SessionOutbox/post(_:)`` coalesces
    /// `.progress` events on, and keying orphan detection on anything less
    /// would let one tool's `.completed` suppress another tool's orphan.
    private struct RunKey: Hashable {
        let tool: String
        let correlationID: String
    }

    /// One pass of orphan-detection state over a recorded stream: which
    /// runs completed, each run's newest non-terminal event, and the
    /// first-non-terminal-appearance order manufactured terminals report
    /// in. Extracted so ``lostRunTerminalEvents(in:)``'s scan loop stays
    /// flat — folding one event into the state is this type's job, not an
    /// arm of a switch nested inside that loop.
    private struct OrphanRunScan {
        var completedRuns: Set<RunKey> = []
        var newestNonTerminalByRun: [RunKey: OperationEvent] = [:]
        var orphanCandidateOrder: [RunKey] = []

        /// Folds one journaled event into the scan: a `.completed` marks
        /// its run terminated; a `.progress`/`.elicitation` becomes the
        /// run's newest non-terminal event, entering the candidate order
        /// on the run's first non-terminal sighting.
        mutating func observe(_ event: OperationEvent) {
            let run = RunKey(tool: event.tool, correlationID: event.correlationID)
            switch event.kind {
            case .completed:
                completedRuns.insert(run)
            case .progress, .elicitation:
                if newestNonTerminalByRun.updateValue(event, forKey: run) == nil {
                    orphanCandidateOrder.append(run)
                }
            }
        }
    }

    /// The terminal `.completed`/``OperationOutcome/lost`` events a restore
    /// must manufacture for `events`' orphaned journaled runs — the crash
    /// edge of run-outcome durability (the orderly-shutdown edge is
    /// ``RoutedSessionActor/close()``'s ``SessionMailbox/sweep()``).
    ///
    /// A run is *orphaned* when the effective recorded stream carries a
    /// non-terminal journaled event for its `(tool, correlationID)` pair (an
    /// ``OperationEventKind/progress`` or ``OperationEventKind/elicitation``
    /// ``OperationEventSegment``) but no ``OperationEventKind/completed``
    /// one for that same pair anywhere in the stream, regardless of order:
    /// the run was still in flight when the recording process died, its
    /// memory-only ``SessionMailbox`` died with it, and nothing will ever
    /// journal its true ending. `.lost` is the honest outcome — "we do not
    /// know how this ended" — exactly the authority distinction
    /// ``OperationOutcome`` documents.
    ///
    /// Exactly one event is manufactured per orphaned run, in
    /// first-orphaned-appearance order, carrying the newest non-terminal
    /// event's own `tool`/`op`; its `detail` is the elicitation's `message`
    /// for an orphaned elicitation (the question lives there, never in
    /// `detail` — see `ToolContext.elicit(_:)`), else the newest event's own
    /// `detail`, and is bounded to its trailing
    /// ``SessionMailbox/terminalDetailTailLimit`` characters — the same cap
    /// ``SessionMailbox/sweep()`` applies to its synthesized terminal, so a
    /// manufactured terminal never exceeds what any other journaled terminal
    /// may carry. A stripped or undecodable segment
    /// (``RecordingLevel/metadataOnly``) is skipped rather than guessed at —
    /// the same nil-not-throw stance `compactionSegmentContent(in:)` takes.
    ///
    /// - Parameter events: A session's effective recorded events, in order
    ///   (as ``effectiveEntryEvents(forSession:)`` returns them).
    /// - Returns: The manufactured terminal events, or empty when every
    ///   journaled run completed.
    static func lostRunTerminalEvents(in events: [TranscriptEvent]) -> [OperationEvent] {
        var scan = OrphanRunScan()
        for event in events {
            for operationEvent in operationEvents(in: event) {
                scan.observe(operationEvent)
            }
        }
        return scan.orphanCandidateOrder.compactMap { run in
            guard !scan.completedRuns.contains(run), let newest = scan.newestNonTerminalByRun[run] else {
                return nil
            }
            let detail = newest.elicitation?.message ?? newest.detail
            return OperationEvent(
                tool: run.tool,
                op: newest.op,
                correlationID: run.correlationID,
                kind: .completed,
                detail: String(detail.suffix(SessionMailbox.terminalDetailTailLimit)),
                outcome: .lost
            )
        }
    }

    /// Decodes every journaled ``OperationEvent`` `event` carries as an
    /// ``OperationEventSegment`` — turn-drained events ride recorded
    /// `.prompt` entries, close-journaled terminals ride `.toolOutput` ones,
    /// so no entry-kind filter is applied; the segment discriminator alone
    /// identifies them. A stripped or undecodable segment yields nothing
    /// rather than throwing, mirroring `compactionSegmentContent(in:)`.
    ///
    /// The `try?` below is a decided behavior, not a swallowed error (task
    /// ^xky3j8w): on the restore path it can never silently hide a corrupt
    /// segment, because ``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``
    /// maps every node's transcript — rebuilding the very same segments
    /// through ``CustomSegmentRegistry`` (which registers
    /// ``OperationEventSegment`` in its `routerDefault`) — *before* this
    /// orphan scan ever runs, and a corrupt segment throws
    /// ``TranscriptReconstructionError/entryReconstructionFailed(session:seq:underlying:)``
    /// there. What remains for the `nil` branch is the stripped
    /// ``RecordingLevel/metadataOnly`` segment, which reconstruction also
    /// refuses first (``TranscriptReconstructionError/contentRemoved(session:seq:)``),
    /// so an orphaned run can never silently miss its manufactured `.lost`
    /// event.
    private static func operationEvents(in event: TranscriptEvent) -> [OperationEvent] {
        (event.entry?.segments ?? []).compactMap { segment in
            guard case .custom(_, let discriminator, let contentJSON, _) = segment,
                discriminator == OperationEventSegment.typeDiscriminator
            else { return nil }
            return try? JSONDecoder().decode(OperationEvent.self, from: Data(contentJSON.utf8))
        }
    }
}
