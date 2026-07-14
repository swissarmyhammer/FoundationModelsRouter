import Foundation
import FoundationModels

/// A failure producing text from a resident generation model.
public enum GenerationError: Error, Equatable {
    /// The live `ModelContainer` generation pipeline is not wired yet — real
    /// text lands in the gated integration suite (milestone 7). The unit suite
    /// exercises the surface through a stub container instead.
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
/// invisible on the embedding handle ``RoutedEmbedder``. ``makeSession(instructions:workingDirectory:)``
/// is the *only* way to obtain a ``RoutedSession``: the vended session inherits
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
    /// ``makeSession(grammar:instructions:workingDirectory:)``,
    /// ``makeLanguageModel()``, and ``makeLanguageModel(resuming:registry:)``
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

    /// Vends a new generation session over this resident model.
    ///
    /// The session is born holding this handle's recorder and router id and a
    /// strong reference to the owning profile. Its
    /// ``RoutedSession/recordingDirectory`` nests under the router's recordings
    /// root (or a temporary base when recording to memory/none) by router id and
    /// the new session id; its ``RoutedSession/workingDirectory`` defaults to the
    /// recording directory and can be overridden without moving it.
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
    /// - Returns: A new ``RoutedSession`` over this model.
    public func makeSession(
        instructions: String? = nil,
        workingDirectory: URL? = nil
    ) -> RoutedSession {
        makeSession(grammar: nil, instructions: instructions, workingDirectory: workingDirectory)
    }

    /// The shared builder behind the plain and guided session surfaces.
    ///
    /// ``makeSession(instructions:workingDirectory:)`` calls this with `grammar`
    /// `nil`; ``makeGuidedSession(grammar:instructions:workingDirectory:)`` (in
    /// GuidedGeneration.swift) calls it with a grammar that then constrains every
    /// `respond` on the vended session and is stamped onto each recorded turn. It
    /// is `internal` so the guided surface in another file in this module can
    /// reuse it.
    ///
    /// - Parameters:
    ///   - grammar: The grammar constraining the session, or `nil` for an
    ///     unconstrained session.
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - workingDirectory: A working directory override, or `nil` to default to
    ///     the recording directory.
    /// - Returns: A new ``RoutedSession`` over this model.
    func makeSession(
        grammar: Grammar?,
        instructions: String?,
        workingDirectory: URL?
    ) -> RoutedSession {
        let owningProfile = requireOwningProfile(apiName: "makeSession")

        let sessionId = ULID.generate()
        let recordingDirectory = self.recordingDirectory(forSessionId: sessionId)

        // The container is only a factory: it manufactures the backend the
        // vended session owns and drives for its whole lifetime, born already
        // carrying `instructions` so generation calls never pass them again.
        let backend = container.makeSession(instructions: instructions)

        // A root's index path is just its own session id — it sits directly
        // under the router root (`recordings/<routerId>/<sessionId>/`).
        let indexPath = sessionId.description
        // This vending site is synchronous, so the record is appended
        // fire-and-forget on an unstructured `Task`; every actor-isolated
        // entry point on the constructed session awaits it before doing its
        // own work (see ``RoutedSessionActor/pendingIndexWrite``), so by the
        // time any interaction with the session completes, this record is
        // guaranteed durable.
        let pendingIndexWrite = sessionIndexWriter.map { writer in
            let record = SessionIndexRecord(
                sessionId: sessionId,
                parentId: nil,
                path: indexPath,
                forkedAtEntryCount: 0,
                slot: slot,
                model: chosen,
                instructions: instructions,
                grammar: grammar?.source,
                createdAt: Date()
            )
            return Task { await writer.append(record) }
        }

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
            // The serial and fork-admission gates are the model handle's, shared
            // across all its sessions and forks. A root session holds no
            // fork-admission permit.
            serialGate: serialGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: false,
            // A root session starts with nothing persisted: the first turn's
            // whole transcript diff (including any leading `.instructions`
            // entry) is new.
            persistedEntryCount: 0,
            indexPath: indexPath,
            sessionIndexWriter: sessionIndexWriter,
            pendingIndexWrite: pendingIndexWrite
        )
    }

    /// The recording directory a fresh session/handle with `sessionId` nests
    /// under: the router's durable transcripts root (or a per-process
    /// temporary fallback when recording to memory/none), by router id and
    /// session id — shared by ``makeSession(grammar:instructions:workingDirectory:)``
    /// and ``makeLanguageModel()`` so the two factories nest identically.
    ///
    /// - Parameter sessionId: The fresh session/handle's own span id.
    /// - Returns: The directory its transcript is recorded under.
    func recordingDirectory(forSessionId sessionId: ULID) -> URL {
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
    /// ``recordingDirectory(forSessionId:)`` nests any fresh session/handle.
    ///
    /// Shared by ``makeLanguageModel()`` (a from-scratch handle: `parentId`
    /// `nil`, `forkedAtEntryCount` `0`, empty initial transcript) and
    /// ``makeLanguageModel(resuming:registry:)`` (a resuming handle: passes
    /// its own resumed-session lineage), which otherwise differ only in
    /// those values.
    ///
    /// - Parameters:
    ///   - sessionId: The handle's own session span id.
    ///   - owningProfile: The already-confirmed-live owning profile to
    ///     retain for this handle's whole lifetime.
    ///   - parentId: The span id of the session this handle resumed from, or
    ///     `nil` for a from-scratch handle. Defaults to `nil`.
    ///   - forkedAtEntryCount: How many of `parentId`'s effective entry-kind
    ///     events belong to this handle's own effective transcript. Defaults
    ///     to `0`.
    ///   - initialTranscript: The transcript to prime the handle's last-seen
    ///     diff baseline with. Defaults to empty.
    /// - Returns: A fresh ``RecordingLanguageModel`` handle.
    private func makeRecordingLanguageModelHandle(
        sessionId: ULID,
        owningProfile: LanguageModelProfile,
        parentId: ULID? = nil,
        forkedAtEntryCount: Int = 0,
        initialTranscript: Transcript = Transcript(entries: [])
    ) -> RecordingLanguageModel {
        let recordingDirectory = self.recordingDirectory(forSessionId: sessionId)
        let indexPath = sessionId.description

        let state = RecordingLanguageModelState(
            routerId: routerId,
            sessionId: sessionId,
            recordingDirectory: recordingDirectory,
            slot: slot,
            model: chosen,
            recorder: recorder,
            serialGate: serialGate,
            sessionIndexWriter: sessionIndexWriter,
            indexPath: indexPath,
            wrapped: container.languageModel,
            profile: owningProfile,
            parentId: parentId,
            forkedAtEntryCount: forkedAtEntryCount,
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
    /// ``makeSession(instructions:workingDirectory:)``'s is), and its own
    /// last-seen transcript, so two live handles never interleave events or
    /// share a directory. Generation is recorded by diffing the transcript
    /// `LanguageModelExecutorGenerationRequest` carries on every call against
    /// last-seen; the turn-final response additionally needs an explicit
    /// ``RecordingLanguageModel/sync(_:)`` call at turn end
    /// (`session.transcript`), since it is not observable at the executor
    /// boundary. See ``RecordingLanguageModelState`` for the full mechanism.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` must still be
    ///   alive when this is called — mirrors
    ///   ``makeSession(instructions:workingDirectory:)``'s own precondition,
    ///   since this handle's resident model must stay alive for its whole
    ///   lifetime too.
    /// - Returns: A fresh ``RecordingLanguageModel`` handle over this model.
    public func makeLanguageModel() -> RecordingLanguageModel {
        let owningProfile = requireOwningProfile(apiName: "makeLanguageModel")
        let sessionId = ULID.generate()
        return makeRecordingLanguageModelHandle(sessionId: sessionId, owningProfile: owningProfile)
    }

    /// Vends a fresh ``RecordingLanguageModel`` handle resuming a previously
    /// recorded session, plus the reconstructed ``FoundationModels/Transcript``
    /// to pair it with.
    ///
    /// Unlike ``makeLanguageModel()``, whose last-seen transcript starts
    /// empty, this primes the handle's last-seen transcript with `sessionId`'s
    /// own reconstructed ``TranscriptTree/effectiveTranscript(forSession:registry:)``,
    /// so the handle's *first* diff records only genuinely new entries —
    /// never the whole resumed history re-recorded into a fresh directory.
    /// The vended handle's own ``SessionIndexRecord`` names `sessionId` as its
    /// parent and the resumed transcript's entry count as its
    /// `forkedAtEntryCount`, the same lineage semantics
    /// ``RoutedSessionActor/fork(workingDirectory:)`` establishes for
    /// ``RoutedSession`` — so ``TranscriptTree``/``MergedTranscript``
    /// reconstruction over the resumed session plus this handle's own
    /// recordings yields the full conversation.
    ///
    /// This is also how a resumed session finally gets real tools: pair the
    /// returned handle and transcript into
    /// `LanguageModelSession(model: handle, tools: realTools, transcript: restored)`
    /// — unlike ``restoreSessionTree(root:registry:)``, which is stuck
    /// reconstructing through `LoadedLLMContainer.makeSession(transcript:)`
    /// (which hardcodes `tools: []`), this handle wraps
    /// `container.languageModel` directly, so the *caller* supplies real
    /// tools straight to `LanguageModelSession`'s own initializer.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` must still be
    ///   alive when this is called — mirrors ``makeLanguageModel()``'s own
    ///   precondition.
    /// - Parameters:
    ///   - sessionId: The previously recorded session's span id to resume
    ///     from — any session already present in this router's
    ///     `sessions.jsonl` (a root, a fork, or another recording-handle
    ///     session).
    ///   - registry: The registered ``PersistableCustomSegment`` types a
    ///     `.custom` segment anywhere in the resumed session's recorded
    ///     transcript may need to rebuild. Defaults to an empty registry.
    /// - Returns: A fresh ``RecordingLanguageModel`` handle whose first diff
    ///   only records genuinely new entries, paired with the reconstructed
    ///   ``FoundationModels/Transcript`` to hand to
    ///   `LanguageModelSession(model:tools:transcript:)`.
    /// - Throws: ``SessionTreeRestorationError/noDurableRecordingsRoot`` if
    ///   this handle has no durable transcripts root; ``TranscriptTreeError``
    ///   / ``TranscriptReconstructionError`` for anything
    ///   ``TranscriptTree/load(under:)`` or
    ///   ``TranscriptTree/effectiveTranscript(forSession:registry:)`` throws.
    public func makeLanguageModel(
        resuming sessionId: ULID,
        registry: CustomSegmentRegistry = CustomSegmentRegistry()
    ) throws -> (handle: RecordingLanguageModel, transcript: Transcript) {
        let owningProfile = requireOwningProfile(apiName: "makeLanguageModel")
        guard let recordingsRoot else {
            throw SessionTreeRestorationError.noDurableRecordingsRoot
        }

        let routerDirectory = recordingsRoot.appendingPathComponent(routerId.description, isDirectory: true)
        let tree = try TranscriptTree.load(under: routerDirectory)
        let restoredTranscript = try tree.effectiveTranscript(forSession: sessionId, registry: registry)

        // Nested the same flat way a root session/handle is (see
        // `recordingDirectory(forSessionId:)`) rather than physically nested
        // under the resumed session's own directory: `SessionIndexRecord.path`
        // is an independent lookup `TranscriptTree.load(under:)` resolves on
        // its own, so physical nesting carries no functional meaning — only
        // `parentId`/`forkedAtEntryCount`, set below, establish the lineage.
        let childId = ULID.generate()
        let handle = makeRecordingLanguageModelHandle(
            sessionId: childId,
            owningProfile: owningProfile,
            parentId: sessionId,
            forkedAtEntryCount: restoredTranscript.count,
            initialTranscript: restoredTranscript
        )
        return (handle, restoredTranscript)
    }
}
