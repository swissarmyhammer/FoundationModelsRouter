import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsHooks

/// A failure to restore recorded sessions from disk, through
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)`` or
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``.
///
/// A session that is not on disk at all raises
/// ``TranscriptTreeError/sessionNotFound(_:)`` instead, because the tree read
/// happens before any restoration-specific check. Catch both types to tell a
/// deleted session from every other restore failure.
public enum SessionTreeRestorationError: Error, Equatable, LocalizedError {
    /// The router has no durable transcripts root, so there is nothing on
    /// disk to restore.
    case noDurableRecordingsRoot

    /// The recorded ``SessionRecord/slot`` of `session` has no generation
    /// handle on the restoring profile.
    case slotNotInProfile(session: ULID, slot: ModelSlot)

    /// The recorded ``SessionRecord/model`` of `session` does not match the
    /// model resident in `slot` on the restoring profile. A restore with
    /// `switchingModel` never throws it.
    case modelMismatch(session: ULID, slot: ModelSlot, recorded: ModelRef, resident: ModelRef)

    /// The host claimed a run that is not claimable in any restored session:
    /// the journal holds a `.completed` event for it, or holds no event of it
    /// and no unended child of a restored session holds its token. Only a run
    /// with ``RunStatus/orphaned``, or a run with no event whose token an
    /// unended recorded child holds
    /// (``SessionRecord/AgentSpawn/parentToolCallId``), can be claimed.
    case runNotClaimable(RunKey)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
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
        case .runNotClaimable(let key):
            return """
                The run \(key.correlationID) of the tool \(key.tool) is not an orphan run of the recorded \
                sessions, and no unended child holds its token, so a restore cannot claim it.
                """
        }
    }
}

/// What a restore could not re-apply from the recorded configuration
/// envelopes. A recording carries tool names, not tool instances. Every
/// recorded name that no supplied tool matches is listed in ``missingTools``.
///
/// Resume is the point where the live tool roster can differ from the
/// recorded one. A transcript that names a tool the process never connected
/// is a silent divergence, and this report is the fact that names it.
public struct SessionConfigurationRestorationReport: Sendable, Equatable {
    /// One recorded tool name that no supplied tool matched, on one restored
    /// session.
    public struct MissingTool: Sendable, Equatable {
        /// The restored session whose envelope recorded the name.
        public let session: ULID

        /// The recorded ``FoundationModels/Tool/name`` with no supplied instance.
        public let toolName: String
    }

    /// Every recorded tool name that no supplied tool matched, in the order
    /// of the recorded envelope, or empty.
    public let missingTools: [MissingTool]

    /// `true` when ``missingTools`` is empty.
    public var isComplete: Bool { missingTools.isEmpty }
}

/// One restored session, a root session or a recorded fork, reconstructed
/// as a live ``RoutedSession`` synced with what is on disk, and the two
/// restore reports.
///
/// This type stays internal.
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``
/// is the published surface.
struct RestoredSessionTree: Sendable {
    /// The restored session, a root session or a recorded fork.
    let root: any RoutedSession

    /// What the restore could not re-apply from the recorded configuration
    /// envelopes.
    let configurationReport: SessionConfigurationRestorationReport

    /// The restored session when its recorded working context differs from
    /// the live resolution, or empty.
    let contextMismatches: [RestoredSession.ContextMismatch]
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
    func transcriptTree(recordingRoot: URL? = nil) throws -> TranscriptTree {
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
    /// Restores one recorded session from disk, by its id: a root session or
    /// a recorded fork (D205).
    ///
    /// The restore restores the named session alone. It makes no session of
    /// a recorded fork under it (^1vesqjj), and for a recorded fork it makes
    /// no session of the chain of sources of the fork. It starts, registers
    /// and ends no hooks of another session. The history of a recorded fork
    /// comes from the recordings of its sources on disk.
    ///
    /// The session keeps its original id, parent id, and recording
    /// directory, so a submission on it appends to its existing transcript.
    /// Its model and slot resolve from its ``SessionRecord``, as its
    /// `index.md` holds it, against this call's owning profile. A mismatch is
    /// a typed error. `instructions`, ``Grammar``, and the recorded
    /// configuration envelope are re-applied. A recorded grammar always
    /// restores as ``Grammar/jsonSchema(_:)``. ``SessionRecord/agentSpawn`` is
    /// re-applied: the tools of a restored sub-agent session see the recorded
    /// parent session and root session, also when the parent is not
    /// restored. A recorded context that differs from the live one is
    /// reported in ``RestoredSessionTree/contextMismatches``.
    ///
    /// The restore writes no `index.md`, except for a move with
    /// `switchingModel`: the restored session holds the record read from its
    /// own, and a later change of the restored session (its facts, its
    /// activity, its compactions) rewrites that `index.md`, keeping its
    /// body. One terminal `.completed` event with outcome
    /// ``OperationOutcome/lost`` is posted to the outbox of the session per
    /// orphaned journaled run. See ``TranscriptTree/lostRunTerminalEvents(in:)``.
    ///
    /// The restored session registers in the session directory of the router
    /// of its handle (``SessionNode/directoryLineage``): a root session as a
    /// root, or as a subagent when its record holds an agent spawn, and a
    /// recorded fork as a fork of its source. The directory holds the session
    /// weakly, so a session that no caller keeps leaves the live list.
    ///
    /// - Parameters:
    ///   - rootId: The span id of the recorded session: a root session or a
    ///     recorded fork.
    ///   - recordingRoot: The exact directory to load the tree from, or `nil`
    ///     for the nested `<recordingsRoot>/<routerId>/` layout. Pass the
    ///     same root a session was vended with.
    ///   - instructions: Instructions that replace the recorded ones, or
    ///     `nil` (the default) to keep the recorded string. The override
    ///     reaches the backend of the session, because it replaces the
    ///     leading `.instructions` entry of the transcript that backend is
    ///     seeded from. The recorded `transcript.jsonl` on disk keeps the
    ///     entry it already holds. A supplied string that differs from the
    ///     recorded one appends one ``TranscriptEvent/Kind/divergence`` event
    ///     to the transcript of the session. See
    ///     ``RestoredSession/instructionsDivergenceText(recorded:supplied:)``
    ///     and this function's own `applyInstructionsOverride(to:transcript:on:)`.
    ///   - tools: The tools the model of the restored session can call. The
    ///     session gets its own per-session tool instances. Every recorded
    ///     tool name with no supplied instance is reported in
    ///     ``RestoredSessionTree/configurationReport``.
    ///   - toolOutputProtection: The host rule whose protected tool outputs
    ///     every compaction on the restored session keeps word for word, or
    ///     `nil` (the default) to protect nothing. No recording holds it,
    ///     because it is a closure; the host gives it here, as it gives the
    ///     tools.
    ///   - isNoOpToolCall: The host check that marks a tool call of the
    ///     restored session as a no-op, or
    ///     ``SessionConfiguration/defaultIsNoOpToolCall`` (the default) to
    ///     mark no call. No recording holds it, because it is a closure; the
    ///     host gives it here, as it gives the tools.
    ///   - userPresence: The user presence of the restored session, or `nil`
    ///     (the default) to give it its recorded value. A record with no
    ///     recorded value restores ``UserPresence/interactive``. The user
    ///     presence belongs to the current client, not to the recording, so a
    ///     supplied value replaces the recorded value. The recorded
    ///     `index.md` on disk does not change.
    ///   - hookSessionKey: The key of the hook lineage of the restored
    ///     session, or `nil` (the default) to let its lineage give the key:
    ///     its recorded id for a root session. A recorded fork with no key
    ///     follows the fork rule against the hook session of its source: the
    ///     open session in this router when the source is live, else the
    ///     lineage that the record of the source gives. Thus a live source
    ///     keeps its hooks and its entry in the session directory. A
    ///     sub-agent that starts from the restored session gets its key while
    ///     it is open. The recording does not hold the key, because it is for
    ///     the hooks only, so a host gives it again here. See
    ///     ``SessionConfiguration/hookSessionKey``.
    ///   - claimingRuns: The orphan runs that the host takes, or empty (the
    ///     default) to take none. The restore posts no `.lost` terminal for a
    ///     claimed run. The restored session keeps the claim open: it is work
    ///     (``RoutedSession/awaitIdle()``) until the host completes the run
    ///     (``RoutedSession/completeClaimedRun(_:outcome:detail:)``), or the
    ///     session closes and ends the run as `.lost`. A host finds the keys
    ///     with ``RouterSessionDirectory/runStatuses(of:)``. A claimed key
    ///     that is not an orphan run of the restored session throws
    ///     ``SessionTreeRestorationError/runNotClaimable(_:)`` before the
    ///     session is restored. A run of a recorded fork is claimed by a
    ///     restore of that fork by its id. A run with no journal event is
    ///     also claimable when an unended recorded child of the session holds
    ///     its token (``RecordedChild/parentToolCallId``): a crash can come
    ///     after the write-ahead record of the call and before the first
    ///     event of the run. The open tool call of a claimed run gets the
    ///     placeholder output ``OpenToolCalls/runningOutput``, and the real
    ///     result arrives as run mail with the same run key. The open call of
    ///     an orphan run that is not claimed gets ``OpenToolCalls/lostOutput``,
    ///     and an open call with no run in the journal gets
    ///     ``OpenToolCalls/unrecordedOutput``.
    ///   - transcriptReader: The reader of the recorded transcripts of
    ///     sessions, or `nil` (the default) for no reader. The restored
    ///     session gets it. The recording does not hold the reader, because
    ///     it is a live object, so a host gives it again here, as it gives the
    ///     tools. See ``SessionConfiguration/transcriptReader``.
    ///   - switchingModel: `false` (the default) to restore the session onto
    ///     the model of its recorded slot. `true` to restore it onto THIS
    ///     handle, also when the recorded model or slot is another one. A
    ///     moved session appends one ``TranscriptEvent/Kind/modelChanged``
    ///     event and rewrites the slot, the model and the context of its
    ///     `index.md`. It keeps its id, its folder and its lineage. A session
    ///     that is on this slot and this model already changes nothing. The
    ///     restore calls no compaction, and it moves no recorded fork under
    ///     the session. See
    ///     ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``.
    /// - Returns: The restored session and the two restore reports.
    /// - Throws: ``SessionTreeRestorationError`` for a restoration-specific
    ///   failure; ``TranscriptTreeError`` or ``TranscriptReconstructionError``
    ///   for what ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:view:)`` throw.
    func restoreSessionTree(
        root rootId: ULID,
        recordingRoot: URL? = nil,
        instructions: String? = nil,
        tools: [any Tool] = [],
        toolOutputProtection: ToolOutputProtection? = nil,
        isNoOpToolCall: @escaping NoOpToolCallCheck = SessionConfiguration.defaultIsNoOpToolCall,
        userPresence: UserPresence? = nil,
        hookSessionKey: String? = nil,
        claimingRuns: Set<RunKey> = [],
        transcriptReader: (any SessionTranscriptReader)? = nil,
        switchingModel: Bool = false
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
        try Self.requireClaimable(claimingRuns, in: rootNode, of: tree)
        // The claimed runs whose open claim the restored session does not
        // hold yet, so that the lost terminal and the eventless scan place
        // each claim one time only.
        var unplacedClaims = claimingRuns

        // The rehydration match (task ^ne5g9jn): the recorded tool names of
        // the session are checked against the supplied instances' names, and
        // every recorded name with no supplied instance is collected here —
        // one row per name — for the returned
        // ``SessionConfigurationRestorationReport``.
        let suppliedToolNames = Set(tools.map(\.name))
        var missingTools: [SessionConfigurationRestorationReport.MissingTool] = []
        // The recorded-context check (task ^xky3j8w): a session whose
        // recorded ``SessionRecord/context`` differs from the live
        // resolution's is collected here — one row — for the returned
        // ``RestoredSessionTree/contextMismatches``. See
        // ``RestoredSession/ContextMismatch`` for why this is a typed
        // warning rather than a `modelMismatch`-style error.
        var contextMismatches: [RestoredSession.ContextMismatch] = []

        /// The hooks of the restored session, or `nil` when the router has no
        /// hook dispatcher. The origin is `.resumed`. The parent is
        /// ``hookParent(of:in:)``. The key is this call's `hookSessionKey`,
        /// else its lineage gives it: its recorded id for a root, the same
        /// key as before the restore.
        ///
        /// - Parameters:
        ///   - node: The loaded node.
        ///   - routedLLM: The generation handle its recorded slot resolved to.
        /// - Returns: The hooks of the node, or `nil`.
        func restoredHooks(for node: SessionNode, on routedLLM: RoutedLLM) -> SessionHooks? {
            guard let routerHooks = routedLLM.hooks else { return nil }
            let hooks = routerHooks.makeSessionHooks(
                sessionID: node.id, workingDirectory: node.record.workingDirectory,
                parent: hookParent(of: node, in: routerHooks),
                requestedKey: hookSessionKey, isRestored: true)
            return hooks
        }

        /// The hook parent of one node: a recorded fork follows the fork rule
        /// against the hook session of its source
        /// (``sourceHookSession(_:in:)``), and a node with a recorded spawn
        /// parent follows the sub-agent rule.
        ///
        /// - Parameters:
        ///   - node: The loaded node.
        ///   - routerHooks: The hooks of the router of the restore.
        /// - Returns: The hook parent, or `nil` for a root with no spawn.
        func hookParent(of node: SessionNode, in routerHooks: RouterHooks) -> HookParent? {
            node.parentId.flatMap { sourceHookSession($0, in: routerHooks) }.map(HookParent.fork(of:))
                ?? node.record.agentSpawn.map {
                    routerHooks.subagentParent(of: $0.parentSessionId, rootSessionID: $0.rootSessionId)
                }
        }

        /// The hook session of the source of a recorded fork. A source that
        /// is open in this router gives its open hook session, so that the
        /// restored fork takes the key of its live source. Else the lineage
        /// of the record of the source gives it, with the same rules as a
        /// restore of that source, and nothing starts.
        ///
        /// - Parameters:
        ///   - id: The id of the source.
        ///   - routerHooks: The hooks of the router of the restore.
        /// - Returns: The hook session of the source, or `nil` when the
        ///   loaded tree holds no source with this id.
        func sourceHookSession(_ id: ULID, in routerHooks: RouterHooks) -> HookSession? {
            if let open = routerHooks.openSession(id) { return open }
            guard let source = tree.session(id) else { return nil }
            return HookLineage.make(
                sessionID: source.id, workingDirectory: source.record.workingDirectory,
                dataDirectory: routerHooks.dispatcher.dataDirectory, parent: hookParent(of: source, in: routerHooks),
                requestedKey: nil, requestedOrigin: nil, isRestored: true
            ).session
        }

        /// The generation handle one node restores onto, when the restore
        /// keeps the recorded model: the handle that the recorded slot names
        /// on the owning profile. Its resident model must be the recorded one.
        ///
        /// - Parameter node: The loaded node.
        /// - Returns: The generation handle of the recorded slot.
        /// - Throws: ``SessionTreeRestorationError/slotNotInProfile(session:slot:)``
        ///   or ``SessionTreeRestorationError/modelMismatch(session:slot:recorded:resident:)``.
        func recordedHandle(for node: SessionNode) throws -> RoutedLLM {
            let slot = node.record.slot
            let routedLLM: RoutedLLM
            switch slot {
            case .standard:
                routedLLM = owningProfile.standard
            case .flash:
                routedLLM = owningProfile.flash
            case .embedding, .decision:
                throw SessionTreeRestorationError.slotNotInProfile(session: node.id, slot: slot)
            }
            guard routedLLM.chosen == node.record.model else {
                throw SessionTreeRestorationError.modelMismatch(
                    session: node.id,
                    slot: slot,
                    recorded: node.record.model,
                    resident: routedLLM.chosen
                )
            }
            return routedLLM
        }

        func restore(_ node: SessionNode) async throws -> any RoutedSession {
            // With the switch, every node restores onto this handle. Without
            // it, each node restores onto the handle of its recorded slot.
            let routedLLM = try switchingModel ? self : recordedHandle(for: node)
            let model = routedLLM.chosen

            // This node's span opens here, before the transcript read below,
            // rather than around the construction alone: `effectiveTranscript`
            // and `effectiveEntryEvents` re-read this node's own and every
            // ancestor's `transcript.jsonl` from disk, and that read is what a
            // restore really costs. `withSessionSpan` is the one helper all
            // shapes open their span through, and its own doc comment
            // says why the factory below opens no span here.
            let session = try await withSessionSpan(
                routerId: routedLLM.routerId,
                sessionId: node.id,
                parentId: node.parentId,
                model: model,
                origin: .restored,
                tracer: routedLLM.tracer
            ) {
                try await rebuild(node, on: routedLLM)
            }
            // Before the restore returns, so a query right after it finds
            // the session, in the directory of the router of its handle.
            let lineage = node.directoryLineage
            routedLLM.sessionDirectory?.register(session, kind: lineage.kind, parentID: lineage.parentID)
            return session
        }

        /// Rebuilds one restored node from what is on disk, inside the span
        /// ``restore(_:)`` opened around it.
        ///
        /// - Parameters:
        ///   - node: The loaded node to rebuild.
        ///   - routedLLM: The generation handle its recorded slot resolved to.
        /// - Returns: The restored session.
        /// - Throws: ``TranscriptTreeError`` or ``TranscriptReconstructionError``
        ///   for what the transcript read throws.
        func rebuild(_ node: SessionNode, on routedLLM: RoutedLLM) async throws -> any RoutedSession {
            // The slot and the model of the handle this node restores onto.
            // Without the switch, `restore(_:)` checked that they are the
            // recorded ones. With the switch, they can differ from the
            // recorded ones, and the node moves (see `recordModelChange` and
            // ``SessionRecord/moveModel(to:)``).
            let slot = routedLLM.slot
            let model = routedLLM.chosen
            let movesModel = node.record.movesModel(to: routedLLM)

            // The restored session runs against the live resolution's
            // context — the physical window `routedLLM`'s backend was
            // actually loaded with — never the recorded figure. A recorded
            // context the live figure no longer matches is reported, not
            // silently adopted and not an error (task ^xky3j8w; see
            // ``RestoredSession/ContextMismatch``).
            let resolvedContextTokens = routedLLM.resolution.contextTokens
            if node.record.context != resolvedContextTokens {
                contextMismatches.append(
                    RestoredSession.ContextMismatch(
                        session: node.id,
                        recorded: node.record.context,
                        resolved: resolvedContextTokens
                    ))
            }

            let transcript = try tree.effectiveTranscript(forSession: node.id, claimedRuns: claimingRuns)

            // The caller's instructions override (task ^w30hzsy), applied to
            // this node's own transcript before the backend reads it. See
            // `applyInstructionsOverride(to:transcript:on:)` for why the
            // transcript is the only place that reaches the model.
            let (effectiveInstructions, seedTranscript) = await applyInstructionsOverride(
                to: node, transcript: transcript, on: routedLLM)

            if movesModel {
                await Self.recordModelChange(of: node, to: routedLLM)
            }

            // The node's recorded configuration envelope (task ^ne5g9jn),
            // or `nil` when its record holds none, which restores with the
            // defaults below (see ``SessionRecord/configuration``).
            let configuration = node.record.configuration
            // The recorded budget and prompt, grouped again with the rule
            // this call's host supplied. A pre-envelope recording gets the
            // default settings with that rule.
            let compaction = configuration?.compaction(toolOutputProtection: toolOutputProtection)
                ?? CompactionSettings(toolOutputProtection: toolOutputProtection)
            // The rehydration match: every recorded tool name with no
            // supplied instance is reported, never silently dropped.
            for toolName in configuration?.toolNames ?? []
            where !suppliedToolNames.contains(toolName) {
                missingTools.append(
                    SessionConfigurationRestorationReport.MissingTool(
                        session: node.id, toolName: toolName))
            }

            // In the envelope with the settle period setting. A record whose
            // envelope holds none gets the default.
            let inlineSettleGrace = configuration?.inlineSettleGrace ?? ToolMount.defaultInlineSettleGrace

            // Per-session event wiring plus per-session tool instancing —
            // the shared helper mints the restored session its own fresh
            // outbox and run plane, so a tool's events post to *this*
            // session's own outbox rather than another session's, and background
            // runs and pending elicitations never survive a restore (see
            // ``RoutedSessionActor/runPlane``).
            // This site's chain is mount only, plus capping when the
            // node's recorded budget carries a `toolOutputLimit` —
            // restoration re-instances from the caller's originals, and it
            // never derives one live session from another. This mirrors the
            // root site's mount → cap (task ^k4nygqa; see
            // ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:tokenCounter:inlineSettleGrace:userPresence:)``).
            // The run plane gets the user presence that this call supplies
            // (task ^58gn0mt), because the client that restores the session
            // owns it. With no supplied value, the run plane
            // gets the recorded user presence (task ^0hps8jg), so a restored
            // headless session stays headless. A record with no envelope,
            // with no presence, or with a presence that this version does
            // not know restores interactive, the default.
            let (outbox, runPlane, instancedTools, resultWitness) = routedLLM.wireSessionTools(
                tools,
                sessionID: node.id,
                cappedToTokenLimit: compaction.budget?.toolOutputLimit,
                inlineSettleGrace: inlineSettleGrace,
                userPresence: userPresence ?? configuration?.restoredUserPresence ?? .interactive,
                parentCall: nil,
                recordedSpawn: node.record.agentSpawn,
                delegationAdvisor: nil,
                transcriptReader: transcriptReader
            )
            let backend = routedLLM.container.makeSession(
                transcript: seedTranscript, tools: instancedTools, samplingMode: routedLLM.samplingMode)
            // ``RoutedSession/contextFill``'s restored numerator: the counter
            // the live session had at the end of its recording (task
            // ^tcep2pc). It is the size of the render after the newest submission
            // that recorded a stamped `.response` after the newest
            // ``CompactionSegment`` checkpoint: the fed and generated tokens
            // of the `.generationCall` event that closed that submission, not the
            // sum on the `.response` stamp (task ^tpsc0nf). When no such submission
            // follows the checkpoint, the checkpoint's own
            // ``CompactionSegment/Content/tokensAfter``. With no checkpoint at
            // all, the same submission anywhere in the stream; else unknown, never
            // a guess. An old journal with no `.generationCall` event gives
            // the `.response` stamp. See
            // ``TranscriptTree/restoredUsageState(in:)``.
            //
            // The events are this session's *effective* ones (its own file
            // plus, for a fork, the inherited prefix of its ancestors'), with
            // the `.generationCall` events kept. Deliberately
            // ancestor-inclusive, not scoped to this node's own file alone: a
            // freshly restored fork with no submissions of its own yet should
            // inherit its parent's last known fill rather than report
            // unknown.
            let usageState = TranscriptTree.restoredUsageState(
                in: try tree.effectiveEntryEvents(forSession: node.id, alongWith: [.generationCall]))
            let effectiveEvents = try tree.effectiveEntryEvents(forSession: node.id)
            // `SessionRecord.grammar` is only the grammar's `source`
            // string — it does not distinguish `.jsonSchema(_:)` from
            // `.ebnf(_:)`, which share that representation — so a session
            // originally guided by `.ebnf(_:)` restores under the
            // `.jsonSchema` case instead (see this function's doc comment,
            // "Known limitation: `.ebnf` grammar case").
            let grammar = node.record.grammar.map(Grammar.jsonSchema)

            // Crash-edge run-outcome durability: a journaled run with a non-terminal recorded event (`.progress`,
            // `.elicitation` or `.message`) and no `.completed` for the same
            // `(tool, correlationID)` pair anywhere in this node's effective
            // stream died with the crashed process — its memory-only run plane
            // is gone, so no teardown sweep ever journaled a terminal event
            // for it (the orderly-shutdown case is
            // ``RoutedSessionActor/close()``'s `RunPlane.sweep()`).
            // Manufacture exactly one terminal `.completed` with outcome
            // ``OperationOutcome/lost`` per orphaned run and post it to this
            // node's fresh outbox: the drain of the next submission journals it durably,
            // so the record has no holes and the model learns the run died.
            // This is the only place `.lost` is manufactured outside an MCP
            // transport drop.
            // A run that the host claimed gets no lost terminal. The first
            // node that holds the run keeps the open claim.
            var claimedTerminals: [OperationEvent] = []
            for lostEvent in TranscriptTree.lostRunTerminalEvents(in: effectiveEvents) {
                let run = RunKey(tool: lostEvent.tool, correlationID: lostEvent.correlationID)
                guard claimingRuns.contains(run) else {
                    await outbox.post(event: lostEvent)
                    continue
                }
                if unplacedClaims.remove(run) != nil {
                    claimedTerminals.append(lostEvent)
                }
            }
            // A claimed run that wrote no event has no lost terminal to hold.
            // The node that spawned an unended child with the token of the
            // run keeps its claim, with a terminal made for it.
            let eventlessRuns = Self.eventlessClaims(
                unplacedClaims, in: effectiveEvents, spawnTokens: tree.unendedSpawnTokens(of: node.id))
            for run in eventlessRuns {
                unplacedClaims.remove(run)
                claimedTerminals.append(OrphanRunScan.lostTerminal(withoutEventOf: run))
            }

            let session = makeRoutedSessionActor(
                profile: owningProfile,
                routerId: routedLLM.routerId,
                id: node.id,
                parentId: node.parentId,
                recordingDirectory: node.directory,
                // Restored from the node's own record (task 6j4bven
                // creation-metadata ask, task 6j4bven) rather than defaulted
                // to `node.directory`: a session vended with an overridden
                // working directory must reassemble against that same
                // directory, not silently fall back to its recording
                // directory, or a restored session's tools would resolve
                // files from the wrong place.
                workingDirectory: node.record.workingDirectory,
                backend: backend,
                slot: slot,
                model: model,
                recorder: routedLLM.recorder,
                instructions: effectiveInstructions,
                grammar: grammar,
                // The per-node instanced tool list threaded to `backend`
                // above; `originalTools` retains the true, un-instanced
                // originals (this call's own `tools` parameter). The record
                // of the session names its tools from them, as a freshly
                // vended root session does.
                tools: instancedTools,
                originalTools: tools,
                outbox: outbox,
                runPlane: runPlane,
                // The transcript the backend really holds, which an
                // instructions override can make one entry longer, and which
                // the backend can start with an instructions entry for its
                // tools when the recording holds none: a crash in the first
                // submission leaves only the write-ahead markers, which the
                // seed folds into a call and a placeholder output. The next
                // submission diff must treat every entry of it as persisted,
                // or it records a substituted entry, or a placeholder
                // output, as new.
                persistedEntryCount: backend.transcriptEntries().count,
                // The restored session's position in its own append-only
                // recorded history: the effective entry-event count, with
                // the entries that the fold of the open markers makes —
                // NOT `seedTranscript.count`, which the checkpoint filter may
                // have shrunk to the compaction's live window (see
                // ``RoutedSessionActor/historyOrdinal``).
                historyOrdinal: try tree.restoredHistoryOrdinal(forSession: node.id),
                // The run-level writer of the restoring handle: a later
                // change of this session rewrites its `index.md`.
                indexWriter: routedLLM.durableRecording?.indexWriter,
                // Rebuilt from disk, so this node's span is the one
                // `restore(_:)` opened around the read above rather than one
                // this factory opens. See `withSessionSpan`.
                origin: .restored,
                contextTokens: resolvedContextTokens,
                usageState: usageState,
                // The recorded configuration envelope re-applied (task
                // ^ne5g9jn): the budget, its prompt and the priming opt-in
                // come back as the node was vended with them. A record with
                // no envelope gets the defaults.
                autoCompactionBudget: compaction.budget,
                autoCompactionPrompt: compaction.prompt,
                // The recorded spawn re-applied: the tools of the node see the
                // recorded parent and root, and the session meta event keeps it.
                agentSpawn: node.record.agentSpawn,
                discoveryPriming: configuration?.discoveryPriming,
                // Not in the envelope, because it is a closure: the rule this
                // call's host supplied, for every node, as `tools` is.
                toolOutputProtection: compaction.toolOutputProtection,
                // In the envelope since task ^1hcwaqy. An envelope that holds
                // none gets the default.
                repetitionDetection: configuration?.repetitionDetection ?? RepetitionDetection(),
                // In the envelope since task ^9bxas0w. An envelope that holds
                // none gets the default.
                mailOnlyAnswerLimit: configuration?.mailOnlyAnswerLimit
                    ?? SessionConfiguration.defaultMailOnlyAnswerLimit,
                inlineSettleGrace: inlineSettleGrace,
                // Not in the envelope, because it is a closure: the check
                // this call's host supplied, for every node, as `tools` is.
                isNoOpToolCall: isNoOpToolCall,
                // Not in the envelope either: the counter comes from the
                // container the node is restored over, as a vended session
                // takes it.
                tokenCounter: routedLLM.container.tokenCounter,
                // The restoring handle's own tracer, exactly as a freshly
                // vended session takes it: a restored node reports where the
                // live router reports.
                tracer: routedLLM.tracer,
                // The hooks of the restoring router: a `.resumed` start with
                // the recorded id, and the fork or sub-agent lineage.
                hooks: restoredHooks(for: node, on: routedLLM),
                // The reader that the mount site of each tool holds, so a fork
                // of this node mounts its tools with the same reader.
                transcriptReader: transcriptReader,
                // Restored, not new: the record read from the node's own
                // `index.md`. Construction writes nothing.
                record: .restored(node.record)
            )
            session.bind(resultWitness: resultWitness)
            if movesModel {
                // The `index.md` follows the event: the slot, the model and
                // the context that the node runs against now.
                session.updateRecord { $0.moveModel(to: routedLLM) }
            }
            // Crash-edge mail durability (`mailbox.md`, section 5, problem
            // 14): each mail of this node that the transcript holds as queued
            // or delivered, with no terminal record, was cut off with the
            // crashed process. It gets exactly one terminal event `lost`, and
            // the transcript records it, so a later restore sends no second
            // one. The mail does not go back to the queue: no tool side
            // effect runs again.
            await session.holdClaims(for: claimedTerminals)
            await session.reportLostMail(
                TranscriptTree.lostMail(
                    in: try tree.effectiveEntryEvents(forSession: node.id, alongWith: [.mail]), ofSession: node.id))
            return session
        }

        /// Applies this call's `instructions` override to one node.
        ///
        /// A caller resumes one session by the id it holds, and the restore
        /// restores that session alone, so the override reaches it alone.
        ///
        /// The model reads its instructions from the leading `.instructions`
        /// entry of the transcript its backend is seeded with.
        /// ``LoadedLLMContainer/makeSession(transcript:tools:)`` takes no
        /// instructions argument, and no generation path reads
        /// ``RoutedSessionActor/instructions``. So the override must enter
        /// that entry, or fresh instructions never reach the model. The
        /// substitution builds a new in-memory value through
        /// ``TranscriptDiffer/replacingLeadingInstructions(of:with:)``. The
        /// recorded `transcript.jsonl` keeps the entry it already holds.
        ///
        /// An override equal to the recorded string changes nothing. It
        /// substitutes no entry, and it writes no event.
        ///
        /// - Parameters:
        ///   - node: The node being rebuilt.
        ///   - transcript: That node's reconstructed transcript.
        ///   - routedLLM: The generation handle its recorded slot resolved to.
        /// - Returns: The instructions the restored session holds, and the
        ///   transcript to seed its backend with.
        func applyInstructionsOverride(
            to node: SessionNode, transcript: Transcript, on routedLLM: RoutedLLM
        ) async -> (instructions: String?, seedTranscript: Transcript) {
            let recorded = node.record.instructions
            guard let supplied = instructions, supplied != recorded else {
                return (instructions ?? recorded, transcript)
            }
            // The divergence goes into the journal rather than into the return
            // value, because the reader who needs it is not the caller. A
            // caller that supplied the string already knows. The person who
            // reads the committed transcript next month does not, and that
            // file still holds the recorded instructions. One `.divergence`
            // marker states the condition in the record itself. The write path
            // is the one ``RoutedSessionActor`` uses for its own
            // transcript-divergence markers.
            await Self.appendRestoreEvent(
                kind: .divergence,
                text: RestoredSession.instructionsDivergenceText(
                    recorded: recorded, supplied: supplied),
                of: node, on: routedLLM, slot: node.record.slot, model: node.record.model)
            return (
                supplied,
                TranscriptDiffer.replacingLeadingInstructions(of: transcript, with: supplied)
            )
        }

        let root = try await restore(rootNode)
        return RestoredSessionTree(
            root: root,
            configurationReport: SessionConfigurationRestorationReport(missingTools: missingTools),
            contextMismatches: contextMismatches
        )
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// Moves recorded forks onto this handle on disk, with no session for
    /// them (^1vesqjj). A restore of a root session by its id with
    /// `switchingModel` calls this for the forks under the root, because a
    /// fork is a part of the same conversation and the restore does not
    /// restore it.
    ///
    /// A fork that has a session in the session directory of the router of
    /// this handle does not move, also when the host suspended it: its
    /// session holds its record in memory and owns its `index.md`. A later
    /// write of that session would put the old slot, model and context back,
    /// and its later events would name the old model after a
    /// `modelChanged` event that names the new one. The move also makes no
    /// second instance of it. A host moves such a fork by its own restore. A
    /// fork that is on this slot and this model already changes nothing.
    ///
    /// Each moved fork gets the same writes as a fork that a restore moves:
    /// one ``TranscriptEvent/Kind/modelChanged`` event, and the slot, the
    /// model and the context of this handle in its `index.md`. The restore
    /// starts, registers and ends no hooks for it.
    ///
    /// - Parameter forks: The recorded forks, as the tree loaded them.
    func moveRecordedForks(_ forks: [SessionNode]) async {
        for fork in forks where !hasSession(fork.id) && fork.record.movesModel(to: self) {
            await Self.recordModelChange(of: fork, to: self)
            guard durableRecording?.indexWriter.writes == true else { continue }
            var record = fork.record
            record.moveModel(to: self)
            SessionIndexFile.saveLoggingFailure(record, in: fork.directory)
        }
    }

    /// Tells if the session directory of the router of this handle holds a
    /// session with the id `id`, live or suspended.
    ///
    /// - Parameter id: The id of the session.
    /// - Returns: `true` when the directory holds the session.
    private func hasSession(_ id: ULID) -> Bool {
        sessionDirectory?.session(id: id) != nil
    }

    /// Appends the ``TranscriptEvent/Kind/modelChanged`` event of one node
    /// that restores or moves onto another model or slot. The event is
    /// stamped with the new slot and the new model, and its text names the
    /// old ones (``RestoredSession/modelChangedText(from:to:)``). The recorded
    /// events stay as they are, so the history keeps the model of each
    /// answer.
    ///
    /// - Parameters:
    ///   - node: The node that moves.
    ///   - routedLLM: The generation handle the node moves onto.
    fileprivate static func recordModelChange(of node: SessionNode, to routedLLM: RoutedLLM) async {
        await appendRestoreEvent(
            kind: .modelChanged,
            text: RestoredSession.modelChangedText(
                from: (node.record.slot, node.record.model),
                to: (routedLLM.slot, routedLLM.chosen)),
            of: node, on: routedLLM, slot: routedLLM.slot, model: routedLLM.chosen)
    }

    /// Appends one event of the restore path to the directory of a node.
    /// Every event the restore writes goes through here, so the event
    /// shape lives in one place.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - text: The text of the event.
    ///   - node: The node of the event. Its id, parent and directory address
    ///     the event.
    ///   - routedLLM: The generation handle whose recorder writes the event.
    ///   - slot: The slot stamped on the event.
    ///   - model: The model stamped on the event.
    fileprivate static func appendRestoreEvent(
        kind: TranscriptEvent.Kind, text: String, of node: SessionNode,
        on routedLLM: RoutedLLM, slot: ModelSlot, model: ModelRef
    ) async {
        await routedLLM.recorder.append(
            TranscriptEvent.Partial(
                routerId: routedLLM.routerId,
                sessionId: node.id,
                parentId: node.parentId,
                slot: slot,
                model: model,
                kind: kind,
                text: text
            ),
            to: node.directory
        )
    }
}

extension SessionNode {
    /// The recorded forks under this node: its children, and the forks
    /// under each child, in depth-first order.
    var forks: [SessionNode] {
        children.flatMap { [$0] + $0.forks }
    }

    /// The kind and the parent that a restored node registers with in the
    /// session directory. A recorded fork is a `fork` of its source. A node
    /// with no source is a `subagent` of the session its record's
    /// ``SessionRecord/agentSpawn`` names, else a `root` with no parent.
    var directoryLineage: (kind: SessionKind, parentID: ULID?) {
        SessionRecord.directoryLineage(forkSource: parentId, agentSpawn: record.agentSpawn)
    }
}

extension SessionRecord {
    /// Tells if a session with this record moves when it restores onto
    /// `routedLLM`: the slot or the model of the handle is not the recorded
    /// one.
    ///
    /// - Parameter routedLLM: The generation handle of the restore.
    /// - Returns: `true` when the recorded slot or model differs from the
    ///   handle.
    func movesModel(to routedLLM: RoutedLLM) -> Bool {
        slot != routedLLM.slot || model != routedLLM.chosen
    }

    /// Sets the slot, the model and the context of `routedLLM` in this
    /// record: the fields of the `index.md` of a session that moves onto
    /// the handle. A restored session writes them through its own record,
    /// and a recorded fork with no session writes them to its file.
    ///
    /// - Parameter routedLLM: The generation handle the session moves onto.
    mutating func moveModel(to routedLLM: RoutedLLM) {
        slot = routedLLM.slot
        model = routedLLM.chosen
        context = routedLLM.resolution.contextTokens
    }

    /// The kind and the parent of a session in the session directory, for a
    /// restored node and for a recorded summary (``RecordedSessions``). A
    /// session with a source is a `fork` of that source. A session with no
    /// source is a `subagent` of the session that `agentSpawn` names, else a
    /// `root` with no parent.
    ///
    /// - Parameters:
    ///   - forkSource: The source of the session when it is a fork, or `nil`.
    ///   - agentSpawn: The agent spawn of the record, or `nil`.
    /// - Returns: The kind and the parent.
    static func directoryLineage(
        forkSource: ULID?, agentSpawn: AgentSpawn?
    ) -> (kind: SessionKind, parentID: ULID?) {
        if let forkSource {
            return (.fork, forkSource)
        }
        if let agentSpawn {
            return (.subagent, agentSpawn.parentSessionId)
        }
        return (.root, nil)
    }
}

extension TranscriptTree {
    /// The terminal `.completed` events with outcome ``OperationOutcome/lost``
    /// that a restore manufactures for the orphaned journaled runs in
    /// `events`. A run is orphaned when the stream carries a non-terminal
    /// event for its `(tool, correlationID)` pair but no `.completed` event
    /// for that pair. One event is made per orphaned run, in order of first
    /// appearance. Its `detail` is the message of a question that the run
    /// asked itself, or the newest event's `detail`, as the journal holds it
    /// (``OrphanRunScan/lostTerminalEvents()``). A relayed question gives no
    /// detail (rule R5).
    ///
    /// The scan is ``OrphanRunScan``, which ``RouterSessionDirectory/runStatuses(of:)``
    /// shares. So the orphan set of a read and the lost set of a restore are
    /// one set.
    ///
    /// The journaled events are read through ``TranscriptEvent/operationEvents``,
    /// which passes over a stripped or undecodable segment. Transcript
    /// reconstruction runs first on the restore path and throws for a corrupt
    /// segment, so that tolerant read hides no corruption here.
    ///
    /// - Parameter events: A session's effective recorded events, in order.
    /// - Returns: The manufactured terminal events, or empty.
    static func lostRunTerminalEvents(in events: [TranscriptEvent]) -> [OperationEvent] {
        OrphanRunScan(scanning: events).lostTerminalEvents()
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// The claims that a node holds without a journal event: the runs of
    /// `claims` that `events` hold no event of, and whose completion token is
    /// the token of an unended child of the node.
    ///
    /// - Parameters:
    ///   - claims: The runs that the host claims.
    ///   - events: The effective events of the node.
    ///   - spawnTokens: The tokens of the unended children of the node
    ///     (``TranscriptTree/unendedSpawnTokens(of:)``).
    /// - Returns: The runs, in order of tool and `correlationID`.
    fileprivate static func eventlessClaims(
        _ claims: Set<RunKey>, in events: [TranscriptEvent], spawnTokens: Set<String>
    ) -> [RunKey] {
        guard !claims.isEmpty, !spawnTokens.isEmpty else { return [] }
        let statuses = OrphanRunScan(scanning: events).statuses
        return claims.filter { statuses[$0] == nil && spawnTokens.contains($0.correlationID) }.sorted {
            ($0.tool, $0.correlationID) < ($1.tool, $1.correlationID)
        }
    }

    /// Checks that each run of `claims` can be claimed: it is an orphan run
    /// in the recorded events of `node`, or it wrote no event there and an
    /// unended child of `node` holds its token. It reads the events and
    /// restores nothing, so a failed check leaves no restored session.
    ///
    /// - Parameters:
    ///   - claims: The runs that the host claims.
    ///   - node: The node of the session to restore.
    ///   - tree: The loaded tree.
    /// - Throws: ``SessionTreeRestorationError/runNotClaimable(_:)`` for the
    ///   first claimed run, in order of tool and `correlationID`, that can not
    ///   be claimed; the errors of
    ///   ``TranscriptTree/effectiveEntryEvents(forSession:)``.
    fileprivate static func requireClaimable(
        _ claims: Set<RunKey>, in node: SessionNode, of tree: TranscriptTree
    ) throws {
        guard !claims.isEmpty else { return }
        let events = try tree.effectiveEntryEvents(forSession: node.id)
        let claimable = Set(OrphanRunScan(scanning: events).orphanedRuns).union(
            eventlessClaims(claims, in: events, spawnTokens: tree.unendedSpawnTokens(of: node.id)))
        let unclaimable = claims.subtracting(claimable).sorted {
            ($0.tool, $0.correlationID) < ($1.tool, $1.correlationID)
        }
        if let key = unclaimable.first {
            throw SessionTreeRestorationError.runNotClaimable(key)
        }
    }
}
