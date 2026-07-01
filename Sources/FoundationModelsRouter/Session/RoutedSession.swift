import Foundation

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:)``
/// — there is no public initializer — so it is born holding the router's
/// recording root (``routerId``) and the non-optional ``TranscriptRecorder`` the
/// vending handle carried, and it **retains its ``profile``** so the resident
/// models cannot be evicted out from under an in-flight session.
///
/// Every public generation method (``respond(to:)``, ``streamResponse(to:)``)
/// funnels through one private recorder-bracketed chokepoint: an open event is
/// recorded, the model runs, and a close event is recorded whether the model
/// returns or throws. Each call's bracket is individually balanced — exactly one
/// open and one close. Concurrent generations on one model do not interleave:
/// the chokepoint runs inside the model's per-model serial gate
/// (``RoutedModel/serialGate``, a fair FIFO ``AsyncSemaphore`` at value 1) that a
/// session shares with all its forks, so calls on one model queue rather than
/// overlap — MLX generation runs a single GPU stream. The raw model/`ChatSession`
/// is never vended.
///
/// Its identity and directory accessors are `nonisolated` immutables readable
/// without awaiting.
public protocol RoutedSession: Actor {
    /// The resolved profile this session runs against, retained so its resident
    /// models stay alive for the session's lifetime.
    nonisolated var profile: LanguageModelProfile { get }

    /// The recording root id — the router instance that owns this transcript.
    nonisolated var routerId: ULID { get }

    /// This session's span id.
    nonisolated var id: ULID { get }

    /// The span id of the session that forked this one, or `nil` for a root
    /// session.
    nonisolated var parentId: ULID? { get }

    /// The directory this session's transcript is recorded under.
    nonisolated var recordingDirectory: URL { get }

    /// The directory model/tool work runs relative to; defaults to
    /// ``recordingDirectory`` and is overridable at creation without moving the
    /// recording directory.
    nonisolated var workingDirectory: URL { get }

    /// The grammar constraining every ``respond(to:)`` on this session, or `nil`
    /// for an unconstrained session.
    ///
    /// Set when the session is vended by
    /// ``RoutedModel/makeGuidedSession(_:instructions:workingDirectory:)`` and
    /// `nil` for one from ``RoutedModel/makeSession(instructions:workingDirectory:)``.
    /// It travels with the session so ``fork(workingDirectory:)`` inherits it;
    /// ``streamResponse(to:)`` stays unconstrained regardless.
    nonisolated var grammar: Grammar? { get }

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    func respond(to prompt: String) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error>

    /// Forks a child session that continues this one's conversation.
    ///
    /// The child's KV cache **begins as a copy of this session's** (via
    /// ``SessionKVCache/copy()``), so it inherits the prefilled prefix's compute
    /// and then diverges independently rather than replaying the transcript. The
    /// child takes a fresh id with ``parentId`` set to this session's id and nests
    /// under the parent regardless of `workingDirectory` (full transcript nesting
    /// lands in milestone 10, but `parentId` is set here); a guided session's fork
    /// inherits its ``grammar``. The child retains the ``profile`` so resident
    /// models stay alive, and its cache dies with it (ARC) — releasing a fork
    /// frees its KV.
    ///
    /// At most the router's `maxConcurrentForks` fork sessions over one model may
    /// be in flight at once; a fork past that ceiling awaits a free slot, freed
    /// when an outstanding fork is released.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    func fork(workingDirectory: URL?) async throws -> RoutedSession
}

/// The concrete ``RoutedSession``, backed by a loaded ``LoadedLLMContainer``.
///
/// It is `internal` with an `internal` initializer so the only way to obtain one
/// is ``RoutedModel/makeSession(instructions:workingDirectory:)`` — there is no
/// public initializer. The recorder and `routerId` flow down from the vending
/// handle; the `container`, `slot`, `model`, and `instructions` are what the
/// single ``generate(grammar:_:)`` chokepoint runs the model with.
actor RoutedSessionActor: RoutedSession {
    nonisolated let profile: LanguageModelProfile
    nonisolated let routerId: ULID
    nonisolated let id: ULID
    nonisolated let parentId: ULID?
    nonisolated let recordingDirectory: URL
    nonisolated let workingDirectory: URL

    /// The resident container the model generation runs through. Never vended.
    private nonisolated let container: any LoadedLLMContainer

    /// The slot this session's model fills, stamped onto recorded events.
    private nonisolated let slot: ModelSlot

    /// The concrete model reference, stamped onto recorded events.
    private nonisolated let model: ModelRef

    /// The non-optional recorder every generation brackets through.
    private nonisolated let recorder: any TranscriptRecorder

    /// The session's system instructions, passed to the model on each call.
    private nonisolated let instructions: String?

    /// The grammar constraining every ``respond(to:)``, or `nil` for an
    /// unconstrained session. Travels with the session so a fork inherits it.
    nonisolated let grammar: Grammar?

    /// This session's KV cache — the prefilled-prefix compute it accumulates.
    ///
    /// Owned for the session's lifetime and freed with the session (ARC); a
    /// ``fork(workingDirectory:)`` seeds the child from a ``SessionKVCache/copy()``
    /// of this one, so the child inherits the prefix and then diverges.
    private nonisolated let cache: any SessionKVCache

    /// The per-model serial generation gate, shared with the owning model's other
    /// sessions and forks. Every ``generate(grammar:_:)`` runs inside it, so
    /// generations on one model serialize rather than interleave.
    private nonisolated let serialGate: AsyncSemaphore

    /// The fork-admission gate, shared with the owning model.
    /// ``fork(workingDirectory:)`` acquires a permit to admit the child; a fork
    /// releases it on deinit (see ``holdsAdmissionPermit``).
    private nonisolated let forkAdmissionGate: AsyncSemaphore

    /// Whether this session holds a fork-admission permit to release when it is
    /// deallocated. `true` for a fork admitted through ``fork(workingDirectory:)``,
    /// `false` for a root session, which consumes no admission permit.
    private nonisolated let holdsAdmissionPermit: Bool

    /// Creates a session. Internal: construction is only via
    /// ``RoutedModel/makeSession(instructions:workingDirectory:)`` /
    /// ``RoutedModel/makeGuidedSession(_:instructions:workingDirectory:)`` or by
    /// ``fork(workingDirectory:)``.
    init(
        profile: LanguageModelProfile,
        routerId: ULID,
        id: ULID,
        parentId: ULID?,
        recordingDirectory: URL,
        workingDirectory: URL,
        container: any LoadedLLMContainer,
        slot: ModelSlot,
        model: ModelRef,
        recorder: any TranscriptRecorder,
        instructions: String?,
        grammar: Grammar? = nil,
        cache: any SessionKVCache,
        serialGate: AsyncSemaphore,
        forkAdmissionGate: AsyncSemaphore,
        holdsAdmissionPermit: Bool = false
    ) {
        self.profile = profile
        self.routerId = routerId
        self.id = id
        self.parentId = parentId
        self.recordingDirectory = recordingDirectory
        self.workingDirectory = workingDirectory
        self.container = container
        self.slot = slot
        self.model = model
        self.recorder = recorder
        self.instructions = instructions
        self.grammar = grammar
        self.cache = cache
        self.serialGate = serialGate
        self.forkAdmissionGate = forkAdmissionGate
        self.holdsAdmissionPermit = holdsAdmissionPermit
    }

    /// Releases this session's fork-admission permit when it is deallocated, so a
    /// fork blocked on the ceiling can proceed.
    ///
    /// Only a fork holds a permit; a root session's `deinit` is a no-op here. The
    /// session's KV cache is freed by ARC as the actor is torn down — releasing a
    /// fork frees its KV.
    deinit {
        if holdsAdmissionPermit {
            forkAdmissionGate.signal()
        }
    }

    func respond(to prompt: String) async throws -> String {
        // A guided session constrains every response to its grammar, through the
        // container's whole-chunk xgrammar entry point; an unguided session takes
        // the plain path. Both funnel through the same chokepoint, which stamps the
        // grammar (or `nil`) onto each event.
        if let grammar {
            return try await generate(grammar: grammar) {
                try await self.container.respond(
                    to: prompt,
                    instructions: self.instructions,
                    following: grammar
                )
            }
        }
        return try await generate {
            try await self.container.respond(to: prompt, instructions: self.instructions)
        }
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamGenerating(prompt, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Runs the recorder-bracketed streaming generation, forwarding each chunk
    /// the model produces to `continuation`.
    ///
    /// Extracted from ``streamResponse(to:)`` so that method's stream/`Task`
    /// scaffolding stays shallow: the bracketed `for`-loop lives here instead of
    /// nesting inside the continuation closure.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - continuation: The stream continuation each produced chunk is yielded to.
    /// - Throws: Any error thrown by the model, after the chokepoint records the
    ///   close event.
    private func streamGenerating(
        _ prompt: String,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        try await generate {
            for try await chunk in self.container.streamResponse(
                to: prompt,
                instructions: self.instructions
            ) {
                continuation.yield(chunk)
            }
        }
    }

    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        // Admission: at most the router's `maxConcurrentForks` fork sessions over
        // this model may be in flight at once. Past the ceiling this suspends
        // (FIFO) until an outstanding fork is released and frees its slot. The
        // permit is held for the child's lifetime and released in its `deinit`.
        await forkAdmissionGate.wait()

        let childId = ULID.generate()
        // The child nests as a sibling under the same router recording root
        // (`recordingDirectory` is `<base>/<routerId>/<sessionId>`); full
        // transcript nesting under the parent lands in milestone 10, but the
        // lineage is recorded now through `parentId`.
        let childRecordingDirectory = recordingDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(childId.description, isDirectory: true)

        return RoutedSessionActor(
            profile: profile,
            routerId: routerId,
            id: childId,
            parentId: id,
            recordingDirectory: childRecordingDirectory,
            workingDirectory: workingDirectory ?? childRecordingDirectory,
            container: container,
            slot: slot,
            model: model,
            recorder: recorder,
            instructions: instructions,
            grammar: grammar,
            // The child begins with a copy of this session's prefilled prefix,
            // inheriting its compute and then diverging independently.
            cache: cache.copy(),
            serialGate: serialGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: true
        )
    }

    /// The single recorder-bracketed generation chokepoint every public method
    /// funnels through.
    ///
    /// The whole bracket runs inside the model's per-model serial gate
    /// (``RoutedModel/serialGate``), so concurrent generations on one model —
    /// including from forks that share the gate — queue in FIFO order rather than
    /// interleave. Inside the gate it records an open event, runs `body`, then
    /// records a close event — on the success path and on the throwing path alike,
    /// so a transcript always pairs each open with a close. Rich event provenance
    /// (token metering, error detail) and lineage nesting land in milestone 10;
    /// here it proves the bracket emits exactly one open and one close and that
    /// generations serialize.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn, stamped
    ///     onto both bracket events, or `nil` for an unconstrained turn.
    ///   - body: The model work to run inside the bracket.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws, after recording the close event.
    private func generate<R>(
        grammar: Grammar? = nil,
        _ body: () async throws -> R
    ) async throws -> R {
        // Acquire the serial permit for the whole bracket, releasing it on every
        // path with a `defer` (the recording bracket stays in this actor's
        // isolation region, so the gated work is not sent across an isolation
        // boundary as a `withPermit` closure would be). `wait()`/`signal()` pair
        // exactly like `withPermit`, so no permit can leak.
        await serialGate.wait()
        defer { serialGate.signal() }

        await recorder.append(makePartialEvent(kind: .prompt, grammar: grammar))
        do {
            let result = try await body()
            await recorder.append(makePartialEvent(kind: .response, grammar: grammar))
            return result
        } catch {
            await recorder.append(makePartialEvent(kind: .response, grammar: grammar))
            throw error
        }
    }

    /// Builds a bracket event of the given kind stamped with this session's
    /// provenance.
    ///
    /// The open (`.prompt`) and close (`.response`) events the chokepoint records
    /// are identical but for their kind, so both come from this one helper.
    ///
    /// - Parameters:
    ///   - kind: The event kind to stamp — `.prompt` to open, `.response` to
    ///     close.
    ///   - grammar: The guided-generation grammar in force, recorded as its
    ///     source, or `nil` for an unconstrained turn.
    /// - Returns: The partial event for the recorder to stamp and append.
    private func makePartialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: kind,
            grammar: grammar?.source
        )
    }
}
