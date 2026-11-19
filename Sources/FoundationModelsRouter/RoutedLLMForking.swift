import Foundation
import FoundationModels
import FoundationModelsExtras

/// The fork site of the generation handle ``RoutedLLM`` (D205): the third
/// shape of a session, beside the vended root (`makeSession`) and the
/// restored node (`restoreSessionTree`).
extension RoutedModel where Container == any LoadedLLMContainer {
    /// Makes a fork of `source` over this resident model, from `seed`.
    ///
    /// The fork has the id `id`, `source` as its ``RoutedSession/parentId``, and
    /// the working directory of `source`. Its recording directory nests in
    /// the recording directory of `source`, so a restore of the recording of
    /// `source` finds the fork as a fork node with its cut
    /// (``TranscriptTree``). Its backend is a new session of this model,
    /// seeded with ``ForkSeed/entries``, and each seeded entry counts as
    /// recorded: the fork records only its own entries, and copies no
    /// history of `source`.
    ///
    /// The tools are the tools of `surface`, the surface that the host gives
    /// the fork (``SessionLauncher/forkSession(_:)``). With no `surface`,
    /// they are the original tools of `source`, each forked first
    /// (`ForkableTool.forked()`, or the tool itself). Either way they are
    /// then mounted on the
    /// own outbox and run plane of the fork, so a background run of the fork
    /// never posts to `source`. The chain is fork → mount → cap. The fork is
    /// a top-level session, so its mount site is a root site, and it gets the
    /// delegation hint of `source` with a new count. Each setting of
    /// `source` that a host gives (the compaction, the priming, the
    /// protection, the repetition watch, the mail bound, the settle period,
    /// the no-op check, the user presence, the transcript reader) carries
    /// forward.
    ///
    /// The hooks of the fork have the kind `.fork`, the origin `.forked` and
    /// `source` as the parent (``SessionHooks/makeForkHooks(sessionID:workingDirectory:)``).
    /// The first facts are ``SessionFacts/forFork`` of the facts of `source`.
    /// The first record holds the added folders of `surface` as
    /// ``SessionRecord/additionalDirectories``, as the record of a new
    /// session holds them, so the first `index.md` of the fork has them.
    /// With no `surface`, they are the added folders of `source`.
    ///
    /// - Parameters:
    ///   - source: The session to fork. It runs on this handle.
    ///   - forkID: The id of the fork.
    ///   - seed: The transcript, the cut and the context counter of the fork.
    ///   - surface: The surface of the fork, or `nil` for the surface of
    ///     `source`.
    /// - Returns: The fork, not registered.
    func makeFork(
        of source: RoutedSessionActor, id forkID: ULID, seed: ForkSeed, surface: ForkSurface?
    ) -> RoutedSessionActor {
        let tools = surface?.tools
        let forkedTools = tools ?? source.originalTools.map { ($0 as? any ForkableTool)?.forked() ?? $0 }
        let delegationAdvisor = AgentDelegationAdvisor.make(
            hint: source.delegationAdvisorSlot.withLock { $0?.hint }, tools: forkedTools, isRoot: true)
        let (outbox, runPlane, instancedTools, resultWitness) = wireSessionTools(
            forkedTools,
            sessionID: forkID,
            cappedToTokenLimit: source.autoCompactionBudget?.toolOutputLimit,
            inlineSettleGrace: source.inlineSettleGrace,
            userPresence: source.runPlane.userPresence,
            parentCall: nil,
            recordedSpawn: nil,
            delegationAdvisor: delegationAdvisor,
            transcriptReader: source.transcriptReader)
        let backend = container.makeSession(
            transcript: Transcript(entries: seed.entries), tools: instancedTools, samplingMode: samplingMode)
        let fork = makeRoutedSessionActor(
            profile: source.profile,
            routerId: routerId,
            id: forkID,
            parentId: source.id,
            recordingDirectory: source.recordingDirectory.appendingPathComponent(forkID.description, isDirectory: true),
            workingDirectory: source.workingDirectory,
            backend: backend,
            slot: slot,
            model: chosen,
            recorder: recorder,
            instructions: source.instructions,
            grammar: source.grammar,
            tools: instancedTools,
            // The tools of the host, or the originals of the source and not
            // the forked copies: a fork of this fork forks each tool from its
            // original state again.
            originalTools: tools ?? source.originalTools,
            outbox: outbox,
            runPlane: runPlane,
            // Each entry of the seed is history of the source, so the fork
            // records none of them again.
            persistedEntryCount: seed.entries.count,
            // The cut: the record of the fork holds it as
            // `forkedAtHistoryOrdinal`.
            historyOrdinal: seed.historyOrdinal,
            indexWriter: source.indexWriter,
            origin: .forked,
            contextTokens: source.contextTokens,
            usageState: seed.usageState,
            autoCompactionBudget: source.autoCompactionBudget,
            autoCompactionPrompt: source.autoCompactionPrompt,
            // A fork carries no spawn: it is a top-level session.
            agentSpawn: nil,
            discoveryPriming: source.discoveryPriming,
            toolOutputProtection: source.toolOutputProtection,
            repetitionDetection: source.repetitionDetection,
            mailOnlyAnswerLimit: source.mailOnlyAnswerLimit,
            inlineSettleGrace: source.inlineSettleGrace,
            isNoOpToolCall: source.isNoOpToolCall,
            recordingRoot: source.record.configuration?.recordingRoot,
            tokenCounter: container.tokenCounter,
            tracer: tracer,
            hooks: source.hooks?.makeForkHooks(sessionID: forkID, workingDirectory: source.workingDirectory),
            transcriptReader: source.transcriptReader,
            record: .new(
                source.facts.forFork,
                additionalDirectories: surface?.additionalDirectories ?? source.record.additionalDirectories)
        )
        fork.bind(delegationAdvisor: delegationAdvisor)
        fork.bind(resultWitness: resultWitness)
        return fork
    }
}
