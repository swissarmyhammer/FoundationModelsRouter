import Foundation

/// A failure producing text from a resident generation model.
public enum GenerationError: Error, Equatable {
    /// The live `ModelContainer` generation pipeline is not wired yet — real
    /// text lands in the gated integration suite (milestone 7). The unit suite
    /// exercises the surface through a stub container instead.
    case notWiredForLiveInference
}

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
        // The handle references its profile weakly (no retain cycle with the
        // profile's strong hold on its models). The session is what retains the
        // profile, so the profile must still be alive at this point; if a caller
        // cached the handle and released the profile first, that is misuse — fail
        // loudly with a clear message rather than an opaque nil-unwrap trap.
        guard let owningProfile = owningProfileBox.current else {
            preconditionFailure(
                "makeSession requires a live owning LanguageModelProfile; the handle holds it weakly and the profile was released before this call"
            )
        }

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
        guard let owningProfile = owningProfileBox.current else {
            preconditionFailure(
                "makeLanguageModel requires a live owning LanguageModelProfile; the handle holds it weakly and the profile was released before this call"
            )
        }

        let sessionId = ULID.generate()
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
            profile: owningProfile
        )
        return RecordingLanguageModel(state: state)
    }
}
