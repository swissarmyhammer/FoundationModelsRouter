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
    /// `nil`; ``makeGuidedSession(_:instructions:workingDirectory:)`` (in
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
        // When the router has no durable transcripts root (recording to
        // memory/none), nest the session directory under a per-process temporary
        // location, so the directory is still well-defined.
        let recordingsBase = recordingsRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(moduleName, isDirectory: true)
                .appendingPathComponent("Transcripts", isDirectory: true)
        let recordingDirectory = recordingsBase
            .appendingPathComponent(routerId.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)

        return RoutedSessionActor(
            profile: owningProfile,
            routerId: routerId,
            id: sessionId,
            parentId: nil,
            recordingDirectory: recordingDirectory,
            workingDirectory: workingDirectory ?? recordingDirectory,
            container: container,
            slot: slot,
            model: chosen,
            recorder: recorder,
            instructions: instructions,
            grammar: grammar,
            // A fresh session owns an empty (inert — see ``InertKVCache``) cache;
            // the serial and fork-admission gates are the model handle's, shared
            // across all its sessions and forks. A root session holds no
            // fork-admission permit.
            cache: InertKVCache(),
            serialGate: serialGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: false
        )
    }
}
