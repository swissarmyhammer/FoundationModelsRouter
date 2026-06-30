import Foundation

/// A failure operating a ``RoutedSession``.
public enum SessionError: Error, Equatable {
    /// Forking — copying the parent's KV cache into a child session so the child
    /// continues the conversation without replaying it — lands in milestone 9.
    /// The surface is declared now; the copy is not yet wired.
    case forkNotWiredUntilMilestone9
}

/// A generation session over a resident model: the recorded surface an
/// application drives to produce text.
///
/// A session is vended only by ``RoutedModel/makeSession(instructions:workingDirectory:)``
/// — there is no public initializer — so it is born holding the router's
/// recording root (``routerID``) and the non-optional ``TranscriptRecorder`` the
/// vending handle carried, and it **retains its ``profile``** so the resident
/// models cannot be evicted out from under an in-flight session.
///
/// Every public generation method (``respond(to:)``, ``streamResponse(to:)``)
/// funnels through one private recorder-bracketed chokepoint: an open event is
/// recorded, the model runs, and a close event is recorded whether the model
/// returns or throws. Each call's bracket is individually balanced — exactly one
/// open and one close — but because generation suspends at `await` points, the
/// actor is reentrant: two concurrent calls on the same session may interleave
/// their (still balanced) events in the transcript. Strict per-session
/// serialization of generations lands with the concurrency gates in milestone 9.
/// The raw model/`ChatSession` is never vended.
///
/// Its identity and directory accessors are `nonisolated` immutables readable
/// without awaiting.
public protocol RoutedSession: Actor {
    /// The resolved profile this session runs against, retained so its resident
    /// models stay alive for the session's lifetime.
    nonisolated var profile: LanguageModelProfile { get }

    /// The recording root id — the router instance that owns this transcript.
    nonisolated var routerID: ULID { get }

    /// This session's span id.
    nonisolated var id: ULID { get }

    /// The span id of the session that forked this one, or `nil` for a root
    /// session.
    nonisolated var parentID: ULID? { get }

    /// The directory this session's transcript is recorded under.
    nonisolated var recordingDirectory: URL { get }

    /// The directory model/tool work runs relative to; defaults to
    /// ``recordingDirectory`` and is overridable at creation without moving the
    /// recording directory.
    nonisolated var workingDirectory: URL { get }

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
    /// The real behavior — copying the parent's KV cache so the child resumes
    /// without replaying the transcript — lands in milestone 9; until then this
    /// throws ``SessionError/forkNotWiredUntilMilestone9``.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   inherit a default.
    /// - Returns: The forked child session.
    /// - Throws: ``SessionError/forkNotWiredUntilMilestone9`` until milestone 9.
    func fork(workingDirectory: URL?) async throws -> RoutedSession
}

/// The concrete ``RoutedSession``, backed by a loaded ``LoadedLLMContainer``.
///
/// It is `internal` with an `internal` initializer so the only way to obtain one
/// is ``RoutedModel/makeSession(instructions:workingDirectory:)`` — there is no
/// public initializer. The recorder and `routerID` flow down from the vending
/// handle; the `container`, `slot`, `model`, and `instructions` are what the
/// single ``generate(_:)`` chokepoint runs the model with.
actor RoutedSessionActor: RoutedSession {
    nonisolated let profile: LanguageModelProfile
    nonisolated let routerID: ULID
    nonisolated let id: ULID
    nonisolated let parentID: ULID?
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

    /// Creates a session. Internal: construction is only via
    /// ``RoutedModel/makeSession(instructions:workingDirectory:)``.
    init(
        profile: LanguageModelProfile,
        routerID: ULID,
        id: ULID,
        parentID: ULID?,
        recordingDirectory: URL,
        workingDirectory: URL,
        container: any LoadedLLMContainer,
        slot: ModelSlot,
        model: ModelRef,
        recorder: any TranscriptRecorder,
        instructions: String?
    ) {
        self.profile = profile
        self.routerID = routerID
        self.id = id
        self.parentID = parentID
        self.recordingDirectory = recordingDirectory
        self.workingDirectory = workingDirectory
        self.container = container
        self.slot = slot
        self.model = model
        self.recorder = recorder
        self.instructions = instructions
    }

    func respond(to prompt: String) async throws -> String {
        try await generate {
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
        throw SessionError.forkNotWiredUntilMilestone9
    }

    /// The single recorder-bracketed generation chokepoint every public method
    /// funnels through.
    ///
    /// Records an open event, runs `body`, then records a close event — on the
    /// success path and on the throwing path alike, so a transcript always pairs
    /// each open with a close. Rich event provenance (token metering, error
    /// detail) and lineage nesting land in milestone 10; here it proves the
    /// bracket emits exactly one open and one close.
    ///
    /// - Parameter body: The model work to run inside the bracket.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws, after recording the close event.
    private func generate<R>(_ body: () async throws -> R) async throws -> R {
        await recorder.append(makePartialEvent(kind: .prompt))
        do {
            let result = try await body()
            await recorder.append(makePartialEvent(kind: .response))
            return result
        } catch {
            await recorder.append(makePartialEvent(kind: .response))
            throw error
        }
    }

    /// Builds a bracket event of the given kind stamped with this session's
    /// provenance.
    ///
    /// The open (`.prompt`) and close (`.response`) events the chokepoint records
    /// are identical but for their kind, so both come from this one helper.
    ///
    /// - Parameter kind: The event kind to stamp — `.prompt` to open, `.response`
    ///   to close.
    /// - Returns: The partial event for the recorder to stamp and append.
    private func makePartialEvent(kind: TranscriptEvent.Kind) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerID,
            sessionId: id,
            parentId: parentID,
            slot: slot,
            model: model,
            kind: kind
        )
    }
}
