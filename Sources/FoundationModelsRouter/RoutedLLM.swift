import Foundation
import FoundationModels

/// A failure producing text from a resident generation model.
public enum GenerationError: Error, Equatable {
    /// The live `ModelContainer` generation pipeline is not wired yet.
    case notWiredForLiveInference
}

/// The shared suffix of the trap message ``RoutedModel/requireOwningProfile(apiName:)``
/// emits when the owning profile is released.
private let missingOwningProfileMessageSuffix =
    "requires a live owning LanguageModelProfile; the handle holds it weakly and the profile was released before this call"

/// The session-creation surface on the generation handle ``RoutedLLM``.
///
/// A vended ``RoutedSession`` inherits this handle's ``RoutedModel/routerId``
/// and ``RoutedModel/recorder``, retains the owning ``LanguageModelProfile``,
/// and runs generation through the resident container.
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Returns the live owning profile, or traps if it is already released.
    ///
    /// A handle holds its profile weakly. A call after the profile is
    /// released is a programmer error.
    ///
    /// - Parameter apiName: The calling entry point's name for the trap message.
    /// - Returns: The live owning profile.
    func requireOwningProfile(apiName: String) -> LanguageModelProfile {
        guard let owningProfile = owningProfileBox.current else {
            preconditionFailure("\(apiName) \(missingOwningProfileMessageSuffix)")
        }
        return owningProfile
    }

    // sah:allow duplication a frozen public convenience (^pckk91c) whose body only forwards its nine parameters into a SessionConfiguration and on to makeSession(configuration:); makeGuidedSession forwards the same nine plus its grammar, and neither body holds logic that can drift
    /// Vends a new generation session over this resident model.
    ///
    /// When the router records durably, this writes the session's
    /// ``SessionSidecar`` synchronously before it returns.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` is still alive.
    ///   The handle holds it weakly; only the vended session retains it.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil` for the recording directory.
    ///   - recordingRoot: A per-session recording root, or `nil` for the router-level root.
    ///   - tools: The tools the model can call. Each is wrapped by ``makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``.
    ///   - budget: The auto-compaction opt-in, or `nil` for manual compaction only.
    ///   - compactionPrompt: The prompt automatic folds send to the summarizer.
    ///   - summarization: The model-assisted compaction stage every fold runs.
    ///   - agentSpawn: The parent session and tool call this session was spawned from, or `nil`.
    ///   - discoveryPriming: The pre-discovery seeding opt-in, or `nil` to leave it off.
    /// - Returns: A new ``RoutedSession`` over this model.
    public func makeSession(
        instructions: String? = nil,
        workingDirectory: URL? = nil,
        recordingRoot: URL? = nil,
        tools: [any Tool] = [],
        budget: TokenBudget? = nil,
        compactionPrompt: CompactionPrompt = .default,
        summarization: Summarization = Summarization(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil
    ) -> RoutedSession {
        makeSession(
            configuration: SessionConfiguration(
                instructions: instructions,
                workingDirectory: workingDirectory,
                recordingRoot: recordingRoot,
                tools: tools,
                budget: budget,
                compactionPrompt: compactionPrompt,
                summarization: summarization,
                agentSpawn: agentSpawn,
                discoveryPriming: discoveryPriming))
    }

    /// Vends a new session over this resident model, configured by one
    /// ``SessionConfiguration`` value.
    ///
    /// A configuration with a ``SessionConfiguration/grammar`` vends a guided
    /// session. The precondition of
    /// ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// applies.
    ///
    /// - Parameter configuration: The value that describes the session.
    /// - Returns: A new ``RoutedSession`` over this model.
    public func makeSession(configuration: SessionConfiguration) -> RoutedSession {
        makeSession(
            grammar: configuration.grammar,
            instructions: configuration.instructions,
            workingDirectory: configuration.workingDirectory,
            recordingRoot: configuration.recordingRoot,
            tools: configuration.tools,
            budget: configuration.budget,
            compactionPrompt: configuration.compactionPrompt,
            summarization: configuration.summarization,
            agentSpawn: configuration.agentSpawn,
            discoveryPriming: configuration.discoveryPriming)
    }

    /// The shared builder behind the plain and guided session surfaces.
    ///
    /// A non-`nil` `grammar` constrains every `respond` on the vended session
    /// and is stamped onto each recorded turn. The other parameters match
    /// ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///
    /// - Parameter grammar: The grammar that constrains the session, or `nil`.
    /// - Returns: A new ``RoutedSession`` over this model.
    func makeSession(
        grammar: Grammar?,
        instructions: String?,
        workingDirectory: URL?,
        recordingRoot: URL? = nil,
        tools: [any Tool] = [],
        budget: TokenBudget? = nil,
        compactionPrompt: CompactionPrompt = .default,
        summarization: Summarization = Summarization(),
        agentSpawn: SessionSidecar.AgentSpawn? = nil,
        discoveryPriming: DiscoveryPriming? = nil
    ) -> RoutedSession {
        let owningProfile = requireOwningProfile(apiName: "makeSession")

        let sessionId = ULID.generate()
        let recordingDirectory = self.recordingDirectory(forSessionId: sessionId, recordingRoot: recordingRoot)

        // Per-session event wiring plus pure per-session instancing, before
        // the backend is ever built — see
        // ``makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
        // for the fresh outbox/mailbox scope rule and the mount → cap
        // chain this site applies (task
        // ^k4nygqa; the fork and restore sites each have their own
        // deliberately distinct chain — see
        // ``RoutedSessionActor/fork(workingDirectory:)`` and
        // `restoreSessionTree`). Because this runs before
        // `container.makeSession` below, the model-facing tool list the
        // backend actually receives is these composed wrappers — each
        // String-output tool's mount layer, and each non-String-output
        // tool's binding-only `ContextBindingTool`, binding the ambient
        // `ToolContext` that posts the tool's events to this session's own
        // `outbox` — not the bare originals.
        let (outbox, mailbox, instancedTools) = makeSessionToolWiring(
            tools,
            sessionID: sessionId,
            cappedToTokenLimit: budget?.toolOutputLimit
        )

        // The container is only a factory: it manufactures the backend the
        // vended session owns and drives for its whole lifetime, born already
        // carrying `instructions` and `instancedTools` so generation calls
        // never pass them again and the model can call whatever `tools`
        // supplies, with events routed to this session's own `outbox`.
        let backend = container.makeSession(instructions: instructions, tools: instancedTools)

        return makeRoutedSessionActor(
            profile: owningProfile,
            routerId: routerId,
            id: sessionId,
            parentId: nil,
            recordingDirectory: recordingDirectory,
            workingDirectory: workingDirectory ?? recordingDirectory,
            backend: backend,
            slot: slot,
            model: chosen,
            recorder: recorder,
            instructions: instructions,
            grammar: grammar,
            tools: instancedTools,
            // The true originals, retained only so a fork can later build its
            // own tool list via fork-then-mount composition, sourced from
            // these rather than from `instancedTools` (see
            // ``RoutedSessionActor/fork(workingDirectory:)``'s doc comment).
            originalTools: tools,
            outbox: outbox,
            mailbox: mailbox,
            // The generation and fork-admission gates are the model handle's,
            // shared across all its sessions and forks — the session mints its
            // own per-session turn lock. A root session holds no fork-admission
            // permit.
            generationGate: generationGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: false,
            // A root session starts with nothing persisted: the first turn's
            // whole transcript diff (including any leading `.instructions`
            // entry) is new.
            persistedEntryCount: 0,
            // A vended root has recorded nothing yet, so its append-only
            // history position starts at zero too.
            historyOrdinal: 0,
            // The vended root lands its own write-once sidecar as it is
            // constructed — the vending handle does not write it on the
            // session's behalf, so a root actor built anywhere cannot come into
            // existence without one (see ``SessionSidecarOrigin``).
            sidecarOrigin: .new(under: durableRecording),
            // This slot's resolved working context — ``contextFill``'s
            // denominator (compaction_plan.md §1.5). A brand-new root has
            // sent nothing yet, so its fill state starts at ``.none``.
            contextTokens: resolution.contextTokens,
            usageState: .none,
            autoCompactionBudget: budget,
            autoCompactionPrompt: compactionPrompt,
            summarization: summarization,
            agentSpawn: agentSpawn,
            discoveryPriming: discoveryPriming,
            // Threaded only into the sidecar's configuration envelope (task
            // ^ne5g9jn), so the recorded configuration names the recording
            // root the session was actually vended with.
            recordingRoot: recordingRoot
        )
    }

    /// Mints one session's fresh outbox and mailbox and instances `tools`
    /// against them.
    ///
    /// Each tool is composed by
    /// ``ToolMounting/sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)``.
    /// The outbox and mailbox are fresh per session and never shared.
    ///
    /// - Parameters:
    ///   - tools: The caller's original tools, never mutated.
    ///   - sessionID: The owning session's identity.
    ///   - tokenLimit: The ``TokenBudget/toolOutputLimit`` to cap output to, or `nil` for no cap.
    /// - Returns: The session's outbox and mailbox with the instanced tool list.
    func makeSessionToolWiring(
        _ tools: [any Tool],
        sessionID: ULID,
        cappedToTokenLimit tokenLimit: Int?
    ) -> (outbox: SessionOutbox, mailbox: SessionMailbox, tools: [any Tool]) {
        let outbox = SessionOutbox()
        let mailbox = SessionMailbox()
        let instancedTools = tools.map { tool in
            ToolMounting.sessionMounted(
                tool: tool,
                sessionID: sessionID,
                mailbox: mailbox,
                sink: outbox,
                cappedToTokenLimit: tokenLimit
            )
        }
        return (outbox, mailbox, instancedTools)
    }

    /// The recording directory a fresh session or handle nests under.
    ///
    /// With `recordingRoot` supplied, the layout is `<recordingRoot>/<sessionId>/`.
    /// With `recordingRoot` `nil`, the layout is `<recordingsBase>/<routerId>/<sessionId>/`,
    /// where `recordingsBase` is the router's durable root or a temporary fallback.
    ///
    /// - Parameters:
    ///   - sessionId: The fresh session or handle's span id.
    ///   - recordingRoot: A per-session recording root, or `nil` for the router-level default.
    /// - Returns: The directory the transcript is recorded under.
    func recordingDirectory(forSessionId sessionId: ULID, recordingRoot: URL? = nil) -> URL {
        if let recordingRoot {
            return recordingRoot.appendingPathComponent(sessionId.description, isDirectory: true)
        }
        let recordingsBase = recordingsRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(moduleName, isDirectory: true)
                .appendingPathComponent("Transcripts", isDirectory: true)
        return recordingsBase
            .appendingPathComponent(routerId.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)
    }

    /// Builds a fresh ``RecordingLanguageModel`` handle over this resident model.
    ///
    /// - Parameters:
    ///   - sessionId: The handle's own session span id.
    ///   - owningProfile: The live owning profile to retain.
    ///   - recordingDirectory: The handle's own recording directory.
    ///   - parentId: The span id of the resumed session, or `nil`.
    ///   - forkedAtEntryCount: The count of `parentId`'s effective entries this handle inherits, or `nil`.
    ///   - forkedAtHistoryOrdinal: The cut point in `parentId`'s append-only history, or `nil`.
    ///   - initialTranscript: The transcript that primes the handle's last-seen diff baseline.
    /// - Returns: A fresh ``RecordingLanguageModel`` handle.
    private func makeRecordingLanguageModelHandle(
        sessionId: ULID,
        owningProfile: LanguageModelProfile,
        recordingDirectory: URL,
        parentId: ULID? = nil,
        forkedAtEntryCount: Int? = nil,
        forkedAtHistoryOrdinal: Int? = nil,
        initialTranscript: Transcript = Transcript(entries: [])
    ) -> RecordingLanguageModel {
        let state = RecordingLanguageModelState(
            routerId: routerId,
            sessionId: sessionId,
            recordingDirectory: recordingDirectory,
            slot: slot,
            model: chosen,
            recorder: recorder,
            generationGate: generationGate,
            sessionSidecarWriter: sessionSidecarWriter,
            wrapped: container.languageModel,
            profile: owningProfile,
            parentId: parentId,
            forkedAtEntryCount: forkedAtEntryCount,
            forkedAtHistoryOrdinal: forkedAtHistoryOrdinal,
            initialTranscript: initialTranscript
        )
        return RecordingLanguageModel(state: state)
    }

    /// Vends a fresh ``RecordingLanguageModel`` handle over this resident
    /// model, for use as a `FoundationModels.LanguageModel`.
    ///
    /// Each call mints a distinct handle with its own session id and
    /// recording directory. Call ``RecordingLanguageModel/sync(_:usage:)`` at
    /// turn end to record the turn-final response.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` is still alive.
    /// - Returns: A fresh ``RecordingLanguageModel`` handle over this model.
    public func makeLanguageModel() -> RecordingLanguageModel {
        let owningProfile = requireOwningProfile(apiName: "makeLanguageModel")
        let sessionId = ULID.generate()
        return makeRecordingLanguageModelHandle(
            sessionId: sessionId,
            owningProfile: owningProfile,
            recordingDirectory: recordingDirectory(forSessionId: sessionId)
        )
    }

    /// Vends a fresh ``RecordingLanguageModel`` handle that resumes a
    /// recorded session, with the reconstructed ``FoundationModels/Transcript``.
    ///
    /// The handle's last-seen transcript starts as the resumed transcript, so
    /// its first diff records only new entries. The handle nests under the
    /// resumed session's directory. Pass the pair to
    /// `LanguageModelSession(model:tools:transcript:)`.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` is still alive.
    /// - Parameter sessionId: The span id of the recorded session to resume.
    /// - Returns: The fresh handle and the reconstructed transcript.
    /// - Throws: ``SessionTreeRestorationError/noDurableRecordingsRoot`` when
    ///   this handle has no durable root; ``TranscriptTreeError`` or
    ///   ``TranscriptReconstructionError`` from transcript reconstruction.
    public func makeLanguageModel(
        resuming sessionId: ULID
    ) throws -> (handle: RecordingLanguageModel, transcript: Transcript) {
        let owningProfile = requireOwningProfile(apiName: "makeLanguageModel")
        guard let recordingsRoot else {
            throw SessionTreeRestorationError.noDurableRecordingsRoot
        }

        let routerDirectory = recordingsRoot.appendingPathComponent(
            routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let restoredTranscript = try tree.effectiveTranscript(forSession: sessionId)
        // The resume cut in the resumed session's recorded history's own
        // append-only coordinates: its raw effective entry-event count, fold
        // boundaries included. `restoredTranscript.count` cannot serve as
        // the cut — it counts the checkpoint-filtered restore view, which a
        // fold makes SMALLER than the raw count, and a reader applying it as
        // a raw prefix would select the oldest pre-fold span (the defect
        // task ^6z1msg1 removed for actor forks).
        let historyOrdinalAtResume = try tree.effectiveEntryEvents(forSession: sessionId).count

        // Nested directly under the resumed session's own directory, exactly
        // as ``RoutedSessionActor/fork(workingDirectory:)`` nests a fork:
        // nesting is what states lineage on disk now, so a handle that resumes
        // a session must physically live under it or `TranscriptTree` could
        // never rediscover the link. The resumed session's own node names the
        // directory, so this works for a resumed fork nested at any depth.
        guard let resumedNode = tree.session(sessionId) else {
            throw TranscriptTreeError.sessionNotFound(sessionId)
        }
        let childId = ULID.generate()
        let handle = makeRecordingLanguageModelHandle(
            sessionId: childId,
            owningProfile: owningProfile,
            recordingDirectory: resumedNode.directory
                .appendingPathComponent(childId.description, isDirectory: true),
            parentId: sessionId,
            // The legacy positional count stays the restore view's count —
            // it is also this handle's own diff baseline — while the
            // append-only ordinal above carries the actual cut.
            forkedAtEntryCount: restoredTranscript.count,
            forkedAtHistoryOrdinal: historyOrdinalAtResume,
            initialTranscript: restoredTranscript
        )
        return (handle, restoredTranscript)
    }
}
