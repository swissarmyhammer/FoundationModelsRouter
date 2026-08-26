import Foundation
import FoundationModels

/// A failure to restore a session tree from disk via
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``.
public enum SessionTreeRestorationError: Error, Equatable, LocalizedError {
    /// The id names a session in the loaded tree that is not a root. Only a
    /// whole tree is restored, from its root id.
    case notARootSession(ULID)

    /// The router has no durable transcripts root, so there is nothing on
    /// disk to restore.
    case noDurableRecordingsRoot

    /// The recorded ``SessionSidecar/slot`` of `session` has no generation
    /// handle on the restoring profile.
    case slotNotInProfile(session: ULID, slot: ModelSlot)

    /// The recorded ``SessionSidecar/model`` of `session` does not match the
    /// model resident in `slot` on the restoring profile.
    case modelMismatch(session: ULID, slot: ModelSlot, recorded: ModelRef, resident: ModelRef)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .notARootSession(let id):
            return """
                Session \(id.description) is not a root session; restoreSessionTree(root:) \
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

/// What ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``
/// could not re-apply from the recorded configuration envelopes. A recording
/// carries tool names, not tool instances. Every recorded name that no
/// supplied tool matches is listed in ``missingTools``.
public struct SessionConfigurationRestorationReport: Sendable, Equatable {
    /// One recorded tool name that no supplied tool matched, on one restored
    /// session.
    public struct MissingTool: Sendable, Equatable {
        /// The restored session whose envelope recorded the name.
        public let session: ULID

        /// The recorded ``FoundationModels/Tool/name`` with no supplied instance.
        public let toolName: String
    }

    /// Every recorded tool name that no supplied tool matched, in walk order
    /// (each parent before its children), or empty.
    public let missingTools: [MissingTool]

    /// `true` when ``missingTools`` is empty.
    public var isComplete: Bool { missingTools.isEmpty }
}

/// A restored fork tree: every session under a router's recorded root,
/// reconstructed as live ``RoutedSession``s synced with what is on disk.
public struct RestoredSessionTree: Sendable {
    /// One restored session whose recorded working context differs from the
    /// context the restoring profile resolved. The session runs against
    /// ``resolved``. This is a warning, not an error, because the same model
    /// can resolve a different context on a different machine.
    public struct ContextMismatch: Sendable, Equatable {
        /// The restored session whose ``SessionSidecar/context`` differs.
        public let session: ULID

        /// The working context, in tokens, the session was recorded at.
        public let recorded: Int

        /// The working context, in tokens, the restoring profile resolved.
        public let resolved: Int
    }

    /// The restored root session.
    public let root: RoutedSession

    /// What the restore could not re-apply from the recorded configuration
    /// envelopes.
    public let configurationReport: SessionConfigurationRestorationReport

    /// Every restored session whose recorded working context differs from
    /// the live resolution, in walk order, or empty.
    public let contextMismatches: [ContextMismatch]

    /// Every restored session, keyed by id.
    private let sessionsById: [ULID: RoutedSession]

    /// The loaded tree, used for its parent/child linkage.
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

    /// Looks up a restored session by its id.
    ///
    /// - Parameter id: The session's span id.
    /// - Returns: The restored session, or `nil` if `id` is not in the tree.
    public func session(_ id: ULID) -> RoutedSession? {
        sessionsById[id]
    }

    /// A restored session's direct forks, ordered by id.
    ///
    /// - Parameter id: The parent session's span id.
    /// - Returns: Its restored children, or empty if `id` is unknown or a leaf.
    public func children(of id: ULID) -> [RoutedSession] {
        tree.children(of: id).compactMap { sessionsById[$0.id] }
    }
}

extension RoutedModel {
    /// Loads the ``TranscriptTree`` recorded under this handle's recording
    /// root, without live sessions.
    ///
    /// - Parameter recordingRoot: The exact directory to load the tree from,
    ///   or `nil` for the nested `<recordingsRoot>/<routerId>/` layout.
    /// - Returns: The loaded tree.
    /// - Throws: ``SessionTreeRestorationError/noDurableRecordingsRoot`` when
    ///   `recordingRoot` is `nil` and this handle has no durable root;
    ///   ``TranscriptTreeError`` for what ``TranscriptTree/load(under:)`` throws.
    public func transcriptTree(recordingRoot: URL? = nil) throws -> TranscriptTree {
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
        return try TranscriptTree.load(under: treeDirectory)
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// Restores a whole session tree from disk, rooted at a root session's id.
    ///
    /// Each node keeps its original id, parent id, and recording directory,
    /// so a turn on a restored node appends to its existing transcript.
    /// Each node's model and slot resolve from its ``SessionSidecar`` against
    /// this call's owning profile. A mismatch is a typed error.
    /// `instructions`, ``Grammar``, and the recorded configuration envelope
    /// are re-applied. A recorded grammar always restores as
    /// ``Grammar/jsonSchema(_:)``. ``SessionSidecar/agentSpawn`` is not
    /// re-applied. A recorded context that differs from the live one is
    /// reported in ``RestoredSessionTree/contextMismatches``.
    ///
    /// No sidecar is written. No fork-admission permit is consumed. For each
    /// node, one terminal `.completed` event with outcome
    /// ``OperationOutcome/lost`` is posted to the node's outbox per orphaned
    /// journaled run. See ``TranscriptTree/lostRunTerminalEvents(in:)``.
    ///
    /// - Parameters:
    ///   - rootId: The root session's span id.
    ///   - tools: The tools every restored node's model can call. Each node
    ///     gets its own per-session tool instances. Every recorded tool name
    ///     with no supplied instance is reported in
    ///     ``RestoredSessionTree/configurationReport``.
    ///   - recordingRoot: The exact directory to load the tree from, or `nil`
    ///     for the nested `<recordingsRoot>/<routerId>/` layout. Pass the
    ///     same root a session was vended with.
    /// - Returns: The restored tree, rooted at the session named by `rootId`.
    /// - Throws: ``SessionTreeRestorationError`` for a restoration-specific
    ///   failure; ``TranscriptTreeError`` or ``TranscriptReconstructionError``
    ///   for what ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:view:)`` throws.
    public func restoreSessionTree(
        root rootId: ULID,
        recordingRoot: URL? = nil,
        tools: [any Tool] = []
    ) async throws -> RestoredSessionTree {
        // The handle references its profile weakly, mirroring
        // `makeSession(instructions:workingDirectory:)`'s own invariant: a
        // session (restored or not) is what retains the profile, so the
        // profile must still be alive when this is called.
        let owningProfile = requireOwningProfile(apiName: "restoreSessionTree")

        // `transcriptTree(recordingRoot:)` owns the directory choice:
        // `recordingRoot` supplied loads that flat layout directly, omitted
        // loads the nested `<recordingsRoot>/<routerId>/` layout — see that
        // call's own documentation.
        let tree = try transcriptTree(recordingRoot: recordingRoot)
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

            let transcript = try tree.effectiveTranscript(forSession: node.id)

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
            // own outbox rather than a sibling or ancestor's, and background
            // runs and pending elicitations never survive a restore (see
            // ``RoutedSessionActor/mailbox``).
            // This site's chain is mount only, plus capping when the
            // node's recorded budget carries a `toolOutputLimit` —
            // deliberately no fork (restoration re-instances from the
            // caller's originals, it never derives one live session from
            // another) — mirroring the root site's mount → cap; the fork
            // site is fork → mount → cap (task ^k4nygqa; see
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

            // Crash-edge run-outcome durability: a journaled run with a non-terminal recorded event (`.progress`
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
                await outbox.post(event: lostEvent)
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
                // build its own fork-then-mount composed tool list, exactly
                // as it would from a freshly vended root session.
                tools: instancedTools,
                originalTools: tools,
                outbox: outbox,
                mailbox: mailbox,
                generationGate: routedLLM.generationGate,
                forkAdmissionGate: routedLLM.forkAdmissionGate,
                holdsAdmissionPermit: false,
                persistedEntryCount: transcript.count,
                // The restored session's position in its own append-only
                // recorded history: the raw effective entry-event count —
                // NOT `transcript.count`, which the checkpoint filter may
                // have shrunk to the fold's live window (see
                // ``RoutedSessionActor/historyOrdinal``).
                historyOrdinal: effectiveEvents.count,
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
    /// The identity of one journaled operation run: the tool's name plus its
    /// tool-assigned `correlationID`. A correlation id is unique only within
    /// one tool.
    private struct RunKey: Hashable {
        let tool: String
        let correlationID: String
    }

    /// Orphan-detection state over a recorded stream: which runs completed,
    /// each run's newest non-terminal event, and the order of first
    /// non-terminal appearance.
    private struct OrphanRunScan {
        var completedRuns: Set<RunKey> = []
        var newestNonTerminalByRun: [RunKey: OperationEvent] = [:]
        var orphanCandidateOrder: [RunKey] = []

        /// Folds one journaled event into the scan.
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

    /// The terminal `.completed` events with outcome ``OperationOutcome/lost``
    /// that a restore manufactures for the orphaned journaled runs in
    /// `events`. A run is orphaned when the stream carries a non-terminal
    /// event for its `(tool, correlationID)` pair but no `.completed` event
    /// for that pair. One event is made per orphaned run, in order of first
    /// appearance. Its `detail` is the elicitation message, or the newest
    /// event's `detail`, cut to ``SessionMailbox/terminalDetailTailLimit``.
    ///
    /// - Parameter events: A session's effective recorded events, in order.
    /// - Returns: The manufactured terminal events, or empty.
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
                detail: String(detail.suffix(ToolContext.terminalDetailTailLimit)),
                outcome: .lost
            )
        }
    }

    /// Decodes every journaled ``OperationEvent`` that `event` carries as an
    /// ``OperationEventSegment``. A stripped or undecodable segment yields
    /// nothing. Transcript reconstruction runs first and throws for a corrupt
    /// segment, so this `try?` hides no corruption on the restore path.
    private static func operationEvents(in event: TranscriptEvent) -> [OperationEvent] {
        (event.entry?.segments ?? []).compactMap { segment in
            guard let structure = segment.persistedStructure,
                structure.schemaName == OperationEventSegment.schemaName
            else { return nil }
            return try? JSONDecoder().decode(OperationEvent.self, from: Data(structure.contentJSON.utf8))
        }
    }
}
