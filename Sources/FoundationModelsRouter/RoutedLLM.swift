import Foundation
import FoundationModels

/// A failure producing text from a resident generation model.
public enum GenerationError: Error, Equatable {
    /// The live `ModelContainer` generation pipeline is not wired yet — real
    /// text lands in the gated integration suite (milestone 7).
    ///
    /// The unit suite exercises the surface through a stub container
    /// instead.
    case notWiredForLiveInference
}

/// The shared suffix of the precondition-failure message a generation-only
/// entry point traps with when its owning profile has already been
/// released, so there is exactly one string to update if the wording ever
/// changes — see ``RoutedModel/requireOwningProfile(apiName:)``.
private let missingOwningProfileMessageSuffix =
    "requires a live owning LanguageModelProfile; the handle holds it weakly and the profile was released before this call"

/// The session-creation surface on the generation handle.
///
/// ``RoutedLLM`` is `RoutedModel<any LoadedLLMContainer>`, so the
/// generation-only API arrives here as a container-constrained extension — it is
/// invisible on the embedding handle ``RoutedEmbedder``. ``makeSession(configuration:)``
/// — with the nine-parameter
/// ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
/// convenience over it — is the *only* way to obtain a ``RoutedSession``: the vended session inherits
/// this handle's ``RoutedModel/routerId`` and non-optional
/// ``RoutedModel/recorder``, retains the owning ``LanguageModelProfile`` so the
/// resident models stay alive for its lifetime, and runs generation through the
/// resident container.
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Returns the currently live owning profile, or traps if it has already
    /// been released.
    ///
    /// Shared by every generation-only entry point that requires a live
    /// owning ``LanguageModelProfile`` —
    /// ``makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``,
    /// ``makeLanguageModel()``, and ``makeLanguageModel(resuming:)``
    /// — which otherwise differ only in which name the trap message should
    /// report. A handle holds its profile only *weakly* (no retain cycle
    /// with the profile's strong hold on its models): whatever the caller
    /// vends from this handle is what retains the profile, so the profile
    /// must still be alive at this point. Calling any of these entry points
    /// after the profile has been released (and its models evicted) is a
    /// programmer error, so this fails loudly with a clear message naming
    /// the offending entry point rather than an opaque nil-unwrap trap.
    ///
    /// - Parameter apiName: The calling entry point's own name, interpolated
    ///   into the trap message so it names the actual entry point invoked.
    /// - Returns: The currently live owning profile.
    func requireOwningProfile(apiName: String) -> LanguageModelProfile {
        guard let owningProfile = owningProfileBox.current else {
            preconditionFailure("\(apiName) \(missingOwningProfileMessageSuffix)")
        }
        return owningProfile
    }

    // sah:allow duplication a frozen public convenience (^pckk91c) whose body only forwards its nine parameters into a SessionConfiguration and on to makeSession(configuration:); makeGuidedSession forwards the same nine plus its grammar, and neither body holds logic that can drift
    /// Vends a new generation session over this resident model.
    ///
    /// The session is born holding this handle's recorder and router id and a
    /// strong reference to the owning profile. Its
    /// ``RoutedSession/recordingDirectory`` nests under the router's recordings
    /// root (or a temporary base when recording to memory/none) by router id and
    /// the new session id; its ``RoutedSession/workingDirectory`` defaults to the
    /// recording directory and can be overridden without moving it.
    ///
    /// **This does a small, synchronous disk write** when the router records
    /// durably: the session creates its own directory and writes its write-once
    /// ``SessionSidecar`` as it is constructed, before this returns (see
    /// ``SessionSidecarOrigin``). That is deliberate — it is what makes "a
    /// session's facts are on disk before any of its transcript is" true by
    /// construction rather than by an awaited handshake, so a reader can never
    /// meet a transcript it has no facts to interpret. The cost is two syscalls
    /// on the calling thread,
    /// which vending a session (unlike a turn) does not do in a loop. Callers
    /// that vend sessions from the main actor in a tight loop should hop off
    /// it first.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` must still be alive
    ///   when this is called. A handle holds its profile only *weakly*, so the
    ///   profile is not kept alive by caching `profile.standard` / `profile.flash`
    ///   on its own — the session retains it only once created. Calling this after
    ///   the profile has been released (and its models evicted) is a programmer
    ///   error and traps.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil` to default to
    ///     the recording directory.
    ///   - recordingRoot: A per-session recording root override, or `nil` to
    ///     default to this handle's router-level ``Router/recordingsDir`` —
    ///     see ``recordingDirectory(forSessionId:recordingRoot:)`` for the
    ///     layout each choice produces (task ke41yth). Defaults to `nil`, so
    ///     an existing caller that never opts in gets today's directory
    ///     layout byte-for-byte.
    ///   - tools: The tools the model can call during this session. Before
    ///     being threaded to the underlying `LanguageModelSession` (mirroring
    ///     Apple's `LanguageModelSession(tools:)`), every String-output tool
    ///     is wrapped in the detachment engine, and every non-String-output
    ///     tool in the binding-only ``ContextBindingTool``; both wrappers
    ///     bind the ambient ``ToolContext`` — stamped with the tool's own
    ///     identity and a fresh per-call `correlationID`, posting events to
    ///     the vended session's own fresh ``SessionOutbox`` — around
    ///     each call, and the tool instance itself passes through untouched
    ///     (see ``makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``).
    ///     Defaults to no tools.
    ///   - budget: The auto-compaction opt-in (the "session
    ///     that manages its own window" opt-in, task 8213x39), or `nil` (the
    ///     default) for manual-only compaction via
    ///     ``RoutedSession/compact(prompt:budget:)``. When set, the vended
    ///     session checks its measured context usage against
    ///     `budget`'s ``TokenBudget/triggerTokens`` before every turn and folds
    ///     automatically once it is reached, and a turn that still overflows mid-generation
    ///     (`LanguageModelError.contextSizeExceeded`) is compacted harder and
    ///     retried exactly once before the error surfaces. A fork inherits
    ///     its parent's opt-in.
    ///   - compactionPrompt: The compaction prompt auto-compaction's own
    ///     folds send to the summarizer, when `budget` is set. Ignored
    ///     otherwise. Defaults to ``CompactionPrompt/default``.
    ///   - summarization: The model-assisted compaction stage every fold on the
    ///     vended session runs — the caller-driven
    ///     ``RoutedSession/compact(prompt:budget:)`` and, when `budget` is set,
    ///     the automatic one alike. Its three knobs
    ///     (``Summarization/keepRecentTurns``, ``Summarization/maxChunkTokens``,
    ///     ``Summarization/summaryTokenRatio``) are how a caller trades
    ///     compression for summary fidelity and sizes chunking for the model
    ///     that really summarizes. A session is where that choice belongs
    ///     rather than a `compact` argument, because an automatic fold has no
    ///     caller to pass one to — see
    ///     ``RoutedSessionActor/summarization``. Defaults to `Summarization()`,
    ///     every default. A fork inherits it.
    ///   - agentSpawn: The parent session/tool-call this session was spawned
    ///     from — e.g. an agents tool creating this session as a
    ///     sub-agent mid-turn (creation-metadata task
    ///     6j4bven) — or `nil` for a session vended with no such spawn
    ///     context. Recorded onto this session's own sidecar (see
    ///     ``SessionSidecar/agentSpawn``); a fork of this session never
    ///     repeats it, since the fork's lineage back to this root is already
    ///     stated by directory nesting. Defaults to `nil`.
    ///   - discoveryPriming: The pre-discovery seeding opt-in, or `nil` (the
    ///     default) to leave it off — with it off, a turn's transcript
    ///     construction is exactly what it has always been. When set, every
    ///     turn on the vended session first runs the named mounted tool
    ///     host-side over the turn's own prompt and seeds the real call it made
    ///     into the turn's transcript before generation, so the turn's first
    ///     tool call is deterministic by construction rather than something the
    ///     model has to decide to make (see ``DiscoveryPriming``). A discovery
    ///     call that fails never blocks the turn: the turn generates unseeded
    ///     and the failure surfaces as
    ///     ``SessionEvent/discoveryPrimingFailed(_:)`` on two routes — on the
    ///     turn's own stream when that turn was started through
    ///     ``RoutedSession/streamEvents(to:maxTokens:)``, and on
    ///     ``RoutedSession/streamSessionEvents()`` for every turn, whichever
    ///     entry point ran it. A fork inherits its parent's opt-in.
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
    /// ``SessionConfiguration`` value — the primary session factory.
    ///
    /// Every knob rides on `configuration`: the nine-parameter
    /// ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// documents each one's semantics, and is itself a convenience that builds
    /// a configuration and forwards here. A configuration with a
    /// ``SessionConfiguration/grammar`` vends the same guided session
    /// ``makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// vends, so the plain and guided surfaces are one vocabulary.
    ///
    /// The disk-write behavior and the precondition are the nine-parameter
    /// overload's, unchanged: the vended session writes its own write-once
    /// sidecar synchronously as it is constructed, and the owning
    /// ``LanguageModelProfile`` must still be alive when this is called.
    ///
    /// - Parameter configuration: The value describing everything the session
    ///   is vended with. `SessionConfiguration()` vends the same session the
    ///   zero-argument `makeSession()` call vends.
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
    /// ``makeSession(configuration:)`` calls this with every
    /// ``SessionConfiguration`` field; the nine-parameter
    /// ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// and ``makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// (in GuidedGeneration.swift) each build a configuration and forward
    /// through it. A non-`nil` `grammar` constrains
    /// every `respond` on the vended session and is stamped onto each recorded
    /// turn.
    ///
    /// - Parameters:
    ///   - grammar: The grammar constraining the session, or `nil` for an
    ///     unconstrained session.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil` to default to
    ///     the recording directory.
    ///   - recordingRoot: A per-session recording root override — see
    ///     ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///     Defaults to `nil`.
    ///   - tools: The tools the model can call during this session. See
    ///     ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` for the
    ///     detachment wrapping applied before threading. Defaults to no tools.
    ///   - budget: The auto-compaction opt-in — see
    ///     ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///     Defaults to `nil`.
    ///   - compactionPrompt: The compaction prompt auto-compaction's own
    ///     folds send to the summarizer, when `budget` is set. Defaults to
    ///     ``CompactionPrompt/default``.
    ///   - summarization: The model-assisted compaction stage every fold on the
    ///     vended session runs — see
    ///     ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///     Defaults to `Summarization()`.
    ///   - agentSpawn: The parent session/tool-call this session was spawned
    ///     from — see ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///     Defaults to `nil`.
    ///   - discoveryPriming: The pre-discovery seeding opt-in — see
    ///     ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
    ///     Defaults to `nil`, which leaves priming off and transcript
    ///     construction exactly as it has always been.
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
        // for the fresh outbox/mailbox scope rule and the detach → cap
        // chain this site applies (task
        // ^k4nygqa; the fork and restore sites each have their own
        // deliberately distinct chain — see
        // ``RoutedSessionActor/fork(workingDirectory:)`` and
        // `restoreSessionTree`). Because this runs before
        // `container.makeSession` below, the model-facing tool list the
        // backend actually receives is these composed wrappers — each
        // String-output tool's detachment layer, and each non-String-output
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
            // own tool list via fork-then-detach composition, sourced from
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

    /// Mints one session's event wiring — a fresh outbox and mailbox — and
    /// instances `tools` against it: each String-output tool is wrapped
    /// in the detachment engine — whose ambient ``ToolContext`` posts the
    /// tool's events to the session's own outbox — and, only when
    /// `cappedToTokenLimit` is set, capped outermost. A non-String-output
    /// tool is wrapped in the binding-only ``ContextBindingTool`` instead
    /// (task ^6htgvw2; see
    /// ``ToolDetachment/wrapping(tool:sessionID:mailbox:sink:op:configuration:)``):
    /// its ambient posts carry the tool's own identity and a fresh per-call
    /// `correlationID` exactly as a detached tool's do — never the
    /// turn-scope binding's `"session"`/`"respond"` stamps — while the call
    /// itself runs in-band, un-detached, and the capping layer passes it
    /// through unwrapped
    /// (``ToolOutputCapping/wrapping(tool:toTokenLimit:)``).
    ///
    /// The outbox and mailbox are minted here, never accepted from the
    /// caller, because both share one scope rule: fresh per session, never
    /// shared, so a tool's events post to *this* session's own outbox
    /// rather than a sibling or ancestor's, and parked runs and pending
    /// elicitations never migrate between sessions or survive a restore
    /// (see ``RoutedSessionActor/mailbox``).
    ///
    /// The shared detach → optional-cap pipeline behind two of
    /// task ^k4nygqa's three composition sites: the root site
    /// (``makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``,
    /// detach → cap) and the restore site (`restoreSessionTree`,
    /// detach — it passes a `nil` `cappedToTokenLimit`, so no capping
    /// layer is ever added). The fork site mints its own wiring because it
    /// forks each tool first, then hands the forked copy to the same
    /// per-tool composition (see
    /// ``RoutedSessionActor/fork(workingDirectory:)``).
    ///
    /// Each tool is composed by the shared per-tool chain
    /// ``ToolDetachment/sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)``
    /// — detachment with the native session mount (eventplan.md
    /// § "Elevation", that plan's name for detachment), or with the mount a
    /// tool declares for itself through
    /// ``DetachmentParameterProviding/detachmentMount``, then, only when
    /// `cappedToTokenLimit` is set, capping outermost — see that helper's
    /// doc for the full layering rationale.
    ///
    /// - Parameters:
    ///   - tools: The caller's original tools, never mutated.
    ///   - sessionID: The owning session's identity, stamped into each
    ///     detached run's ``ToolContext``.
    ///   - tokenLimit: The ``TokenBudget/toolOutputLimit`` to cap
    ///     rendered output to, or `nil` for no capping layer.
    /// - Returns: The session's fresh outbox and mailbox alongside the
    ///   instanced, model-facing tool list wired to them.
    func makeSessionToolWiring(
        _ tools: [any Tool],
        sessionID: ULID,
        cappedToTokenLimit tokenLimit: Int?
    ) -> (outbox: SessionOutbox, mailbox: SessionMailbox, tools: [any Tool]) {
        let outbox = SessionOutbox()
        let mailbox = SessionMailbox()
        let instancedTools = tools.map { tool in
            ToolDetachment.sessionMounted(
                tool: tool,
                sessionID: sessionID,
                mailbox: mailbox,
                sink: outbox,
                cappedToTokenLimit: tokenLimit
            )
        }
        return (outbox, mailbox, instancedTools)
    }

    /// The recording directory a fresh session/handle with the given
    /// `forSessionId` nests under.
    ///
    /// Two layouts, chosen by whether `recordingRoot` is supplied (task
    /// ke41yth):
    ///
    /// - **`recordingRoot` supplied** — a flat `<recordingRoot>/<sessionId>/`,
    ///   with no ``RoutedModel/routerId`` segment. This is what a caller
    ///   opting into ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
    ///   per-session root gets: the routerId groups recordings by *process
    ///   run*, a detail nobody browses by, and reintroducing it under a
    ///   caller-chosen project-local root would just be a pile of opaque
    ///   ULID directories again. The routerId is not lost — it travels as
    ///   ``SessionSidecar/routerId`` metadata inside the session directory
    ///   instead of as a path segment.
    /// - **`recordingRoot` omitted (`nil`)** — today's nested
    ///   `<recordingsBase>/<routerId>/<sessionId>/`, where `recordingsBase`
    ///   is the router's durable transcripts root, or a per-process temporary
    ///   fallback when recording to memory/none. Reproduces every existing
    ///   caller's layout byte-for-byte — shared by
    ///   ``makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`` and
    ///   ``makeLanguageModel()`` so the two factories nest identically.
    ///
    /// - Parameters:
    ///   - sessionId: The fresh session/handle's own span id.
    ///   - recordingRoot: A per-session recording root override, or `nil` for
    ///     the router-level default. Defaults to `nil`.
    /// - Returns: The directory its transcript is recorded under.
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

    /// Builds a fresh ``RecordingLanguageModel`` handle over this resident
    /// model, with `sessionId`'s own recording directory nested the same way
    /// ``recordingDirectory(forSessionId:recordingRoot:)`` nests any fresh session/handle.
    ///
    /// Shared by ``makeLanguageModel()`` (a from-scratch handle: no parent,
    /// no cut point, empty initial transcript, nested directly under the
    /// router root) and ``makeLanguageModel(resuming:)`` (a resuming
    /// handle: nested under the session it resumed, with that session's own
    /// entry counts as its cut points), which otherwise differ only in those
    /// values.
    ///
    /// - Parameters:
    ///   - sessionId: The handle's own session span id.
    ///   - owningProfile: The already-confirmed-live owning profile to
    ///     retain for this handle's whole lifetime.
    ///   - recordingDirectory: The handle's own recording directory — nested
    ///     under the router root for a from-scratch handle, or under the
    ///     resumed session's own directory for a resuming one, since a
    ///     session's lineage is stated by that nesting.
    ///   - parentId: The span id of the session this handle resumed from, or
    ///     `nil` for a from-scratch handle. Defaults to `nil`.
    ///   - forkedAtEntryCount: How many of `parentId`'s effective entry-kind
    ///     events belong to this handle's own effective transcript, or `nil`
    ///     for a from-scratch handle, which inherits nothing. Defaults to
    ///     `nil`.
    ///   - forkedAtHistoryOrdinal: The handle's cut point in `parentId`'s
    ///     recorded history's own append-only coordinates, or `nil` for a
    ///     from-scratch handle. Defaults to `nil`. See
    ///     ``RecordingLanguageModelState/forkedAtHistoryOrdinal``.
    ///   - initialTranscript: The transcript to prime the handle's last-seen
    ///     diff baseline with. Defaults to empty.
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
    /// model: a `FoundationModels.LanguageModel` conformer any caller can
    /// build a `LanguageModelSession(model:tools:instructions:)` over
    /// directly — recorded, serial-gated, and tool-capable with zero session
    /// plumbing.
    ///
    /// A FACTORY, not a property: each call mints a distinct handle with its
    /// own session ULID, its own recording directory (nested the same way
    /// ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s is), and its own
    /// last-seen transcript, so two live handles never interleave events or
    /// share a directory. Generation is recorded by diffing the transcript
    /// `LanguageModelExecutorGenerationRequest` carries on every call against
    /// last-seen; the turn-final response additionally needs an explicit
    /// ``RecordingLanguageModel/sync(_:usage:)`` call at turn end
    /// (`session.transcript`), since it is not observable at the executor
    /// boundary. See ``RecordingLanguageModelState`` for the full mechanism.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` must still be
    ///   alive when this is called — mirrors
    ///   ``makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s own precondition,
    ///   since this handle's resident model must stay alive for its whole
    ///   lifetime too.
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

    /// Vends a fresh ``RecordingLanguageModel`` handle resuming a previously
    /// recorded session, plus the reconstructed ``FoundationModels/Transcript``
    /// to pair it with.
    ///
    /// Unlike ``makeLanguageModel()``, whose last-seen transcript starts
    /// empty, this primes the handle's last-seen transcript with the resumed
    /// session's own reconstructed ``TranscriptTree/effectiveTranscript(forSession:view:)``,
    /// so the handle's *first* diff records only genuinely new entries —
    /// never the whole resumed history re-recorded into a fresh directory.
    /// The vended handle nests under the resumed session's own directory and records
    /// the resumed transcript's entry count as its
    /// ``SessionSidecar/forkedAtEntryCount`` alongside the resumed session's
    /// raw effective entry-event count as its
    /// ``SessionSidecar/forkedAtHistoryOrdinal`` — the same lineage semantics
    /// ``RoutedSessionActor/fork(workingDirectory:)`` establishes for
    /// ``RoutedSession`` — so ``TranscriptTree``/``MergedTranscript``
    /// reconstruction over the resumed session plus this handle's own
    /// recordings yields the full conversation, and resuming a *compacted*
    /// session restores the fold's live window rather than the discarded
    /// pre-fold span (see ``TranscriptTree/effectiveEntryEvents(forSession:)``).
    ///
    /// This is also a way for a single resumed session to get real tools by
    /// pairing the returned handle and transcript directly into
    /// `LanguageModelSession(model: handle, tools: realTools, transcript: restored)`:
    /// this handle wraps `container.languageModel` directly, so the *caller*
    /// supplies real tools straight to `LanguageModelSession`'s own
    /// initializer, with no per-session instancing of its own. For restoring
    /// a whole fork tree at once, prefer
    /// ``restoreSessionTree(root:recordingRoot:tools:)`` instead, which threads
    /// its own `tools:` parameter to every restored node — each with its own
    /// fresh outbox and instanced tool copies — via
    /// ``LoadedLLMContainer/makeSession(transcript:tools:)``.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` must still be
    ///   alive when this is called — mirrors ``makeLanguageModel()``'s own
    ///   precondition.
    /// - Parameters:
    ///   - sessionId: The previously recorded session's span id to resume
    ///     from — any session already recorded under this router's root (a
    ///     root, a fork, or another recording-handle session).
    /// - Returns: A fresh ``RecordingLanguageModel`` handle whose first diff
    ///   only records genuinely new entries, paired with the reconstructed
    ///   ``FoundationModels/Transcript`` to hand to
    ///   `LanguageModelSession(model:tools:transcript:)`.
    /// - Throws: ``SessionTreeRestorationError/noDurableRecordingsRoot`` if
    ///   this handle has no durable transcripts root; ``TranscriptTreeError``
    ///   / ``TranscriptReconstructionError`` for anything
    ///   ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:view:)`` throws.
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
