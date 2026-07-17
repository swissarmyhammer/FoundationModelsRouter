import Foundation
import FoundationModels
import os

/// The logger ``RoutedSessionActor`` reports a defensively-clamped transcript
/// shrink to (see ``RoutedSessionActor/recordTranscriptDelta(grammar:since:usage:)``).
private let sessionRecordingLogger = makeModuleLogger(category: "Recording")

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
/// funnels through one private recorder-bracketed chokepoint: the model runs,
/// then the backend's real transcript is snapshot-diffed against what was
/// already persisted and the new entries are recorded, whether the model
/// returns or throws. A turn's recorded event count is however many entries
/// the SDK's own transcript gained for it — not a fixed one-open/one-close
/// pair — except on the throwing path, which still guarantees at least one
/// trace: either a real `.response` entry the SDK appended before failing, or
/// a synthetic bodyless close when it appended none. Concurrent generations on
/// one model do not interleave:
/// the chokepoint runs inside the model's per-model serial gate
/// (``RoutedModel/serialGate``, a fair FIFO ``AsyncSemaphore`` at value 1) that a
/// session shares with all its forks, so calls on one model queue rather than
/// overlap — MLX generation runs a single GPU stream. The generation itself runs
/// through Apple's own `LanguageModelSession` (`FoundationModels`, macOS 27+),
/// backed by a resident MLX model conformed to the `LanguageModel` protocol via
/// `MLXLanguageModel` (`MLXFoundationModels`) — never `MLXLMCommon`'s own
/// `ChatSession`, and never a hand-rolled generation loop of our own (see
/// plan.md's "Backends" section). The raw model/`LanguageModelSession` is never
/// vended to callers; ``RoutedSession`` is the only generation surface.
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
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:)`` and
    /// `nil` for one from ``RoutedModel/makeSession(instructions:workingDirectory:)``.
    ///
    /// It travels with the session so ``fork(workingDirectory:)`` inherits it;
    /// ``streamResponse(to:)`` stays unconstrained regardless.
    nonisolated var grammar: Grammar? { get }

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>

    /// Forks a child session over the same resident model.
    ///
    /// The child takes a fresh id with ``parentId`` set to this session's id and
    /// its ``recordingDirectory`` nested directly under the parent's, so the
    /// on-disk transcript tree mirrors the fork lineage regardless of
    /// `workingDirectory`; a guided session's fork inherits its ``grammar``. The
    /// child retains the ``profile`` so resident models stay alive, and its
    /// ``LanguageModelSessionBackend`` is seeded from this session's accumulated
    /// conversation state via ``LanguageModelSessionBackend/makeFork()``, so the
    /// child sees the parent's turns so far and then diverges independently.
    ///
    /// At most the router's `maxConcurrentForks` fork sessions over one model may
    /// be in flight at once; a fork past that ceiling awaits a free slot, freed
    /// when an outstanding fork is released.
    ///
    /// - Parameter workingDirectory: The child's working directory, or `nil` to
    ///   default to its recording directory.
    /// - Returns: The forked child session.
    /// - Throws: Nothing in the current implementation — the admission and
    ///   serial gates never throw and ``LanguageModelSessionBackend/makeFork()``
    ///   is non-throwing; declared `async throws` to match ``RoutedSession``'s
    ///   other generation entry points and leave room for a future conforming
    ///   backend whose fork can fail.
    func fork(workingDirectory: URL?) async throws -> RoutedSession
}

extension RoutedSession {
    /// Generates a complete text response to a prompt using the underlying
    /// model's own default token ceiling, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    public func respond(to prompt: String) async throws -> String {
        try await respond(to: prompt, maxTokens: nil)
    }

    /// Streams a text response to a prompt as it is produced, using the
    /// underlying model's own default token ceiling, recording the call.
    ///
    /// - Parameter prompt: The prompt to respond to.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    public func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: prompt, maxTokens: nil)
    }
}

/// Builds a ``RoutedSessionActor``, the shared construction path behind both a
/// fresh root session (``RoutedModel/makeSession(grammar:instructions:workingDirectory:)``)
/// and a forked child (``RoutedSessionActor/fork(workingDirectory:)``).
///
/// The two call sites' constructor invocations used to be near-verbatim
/// duplicates of each other, differing only in the values they passed —
/// duplication that meant any change to ``RoutedSessionActor``'s initializer
/// (a new parameter, a reordering) had to be applied in two places and could
/// silently drift. Factoring the call out here means it is made in exactly
/// one place; each call site just forwards the values it already has in
/// scope (a root session's freshly computed identity/directory/zero baseline,
/// or a fork's inherited profile/gates plus its own child identity and
/// fork-time baseline).
///
/// - Parameters: mirror ``RoutedSessionActor/init(profile:routerId:id:parentId:recordingDirectory:workingDirectory:backend:slot:model:recorder:instructions:grammar:serialGate:forkAdmissionGate:holdsAdmissionPermit:persistedEntryCount:sidecarOrigin:)``
///   one-for-one.
/// - Returns: The constructed session actor.
func makeRoutedSessionActor(
    profile: LanguageModelProfile,
    routerId: ULID,
    id: ULID,
    parentId: ULID?,
    recordingDirectory: URL,
    workingDirectory: URL,
    backend: any LanguageModelSessionBackend,
    slot: ModelSlot,
    model: ModelRef,
    recorder: any TranscriptRecorder,
    instructions: String?,
    grammar: Grammar?,
    serialGate: AsyncSemaphore,
    forkAdmissionGate: AsyncSemaphore,
    holdsAdmissionPermit: Bool,
    persistedEntryCount: Int,
    sidecarOrigin: SessionSidecarOrigin
) -> RoutedSessionActor {
    RoutedSessionActor(
        profile: profile,
        routerId: routerId,
        id: id,
        parentId: parentId,
        recordingDirectory: recordingDirectory,
        workingDirectory: workingDirectory,
        backend: backend,
        slot: slot,
        model: model,
        recorder: recorder,
        instructions: instructions,
        grammar: grammar,
        serialGate: serialGate,
        forkAdmissionGate: forkAdmissionGate,
        holdsAdmissionPermit: holdsAdmissionPermit,
        persistedEntryCount: persistedEntryCount,
        sidecarOrigin: sidecarOrigin
    )
}

/// The concrete ``RoutedSession``, backed by a ``LanguageModelSessionBackend``.
///
/// It is `internal` with an `internal` initializer so the only way to obtain one
/// is ``RoutedModel/makeSession(instructions:workingDirectory:)`` — there is no
/// public initializer. The recorder and `routerId` flow down from the vending
/// handle; the `backend`, `slot`, and `model` are what the single
/// ``generate(grammar:_:)`` chokepoint runs the model with.
actor RoutedSessionActor: RoutedSession {
    nonisolated let profile: LanguageModelProfile
    nonisolated let routerId: ULID
    nonisolated let id: ULID
    nonisolated let parentId: ULID?
    nonisolated let recordingDirectory: URL
    nonisolated let workingDirectory: URL

    /// The persistent backend this session drives every generation and fork
    /// through, for the session's whole lifetime.
    ///
    /// Born already carrying this session's instructions (baked in when it was
    /// manufactured by ``LoadedLLMContainer/makeSession(instructions:)``), so
    /// generation calls no longer pass `instructions` per turn, and calls
    /// accumulate conversation state across turns instead of each starting a
    /// fresh backend. Never vended to callers.
    private nonisolated let backend: any LanguageModelSessionBackend

    /// The slot this session's model fills, stamped onto recorded events.
    private nonisolated let slot: ModelSlot

    /// The concrete model reference, stamped onto recorded events.
    private nonisolated let model: ModelRef

    /// The non-optional recorder every generation brackets through.
    private nonisolated let recorder: any TranscriptRecorder

    /// The session's system instructions, baked into ``backend`` at
    /// construction; retained here only to carry forward into a forked child's
    /// actor state.
    private nonisolated let instructions: String?

    /// The grammar constraining every ``respond(to:)``, or `nil` for an
    /// unconstrained session.
    ///
    /// Travels with the session so a fork inherits it.
    nonisolated let grammar: Grammar?

    /// The per-model serial generation gate, shared with the owning model's other
    /// sessions and forks.
    ///
    /// Every ``generate(grammar:_:)`` runs inside it, so generations on one
    /// model serialize rather than interleave.
    private nonisolated let serialGate: AsyncSemaphore

    /// The fork-admission gate, shared with the owning model.
    ///
    /// ``fork(workingDirectory:)`` acquires a permit to admit the child; a fork
    /// releases it on deinit (see ``holdsAdmissionPermit``).
    private nonisolated let forkAdmissionGate: AsyncSemaphore

    /// Whether this session holds a fork-admission permit to release when it is
    /// deallocated.
    ///
    /// `true` for a fork admitted through ``fork(workingDirectory:)``, `false`
    /// for a root session, which consumes no admission permit.
    private nonisolated let holdsAdmissionPermit: Bool

    /// Whether the session's first-line `session` meta event has been recorded.
    ///
    /// The chokepoint emits the meta event lazily, before the first turn's open
    /// event, so a session that never generates writes no file at all while one
    /// that does always opens its transcript with a `session` line. Guarded by the
    /// actor's isolation and flipped before the meta append, so no reentrant turn
    /// can emit it twice.
    private var didRecordSessionMeta = false

    /// How many of ``backend``'s ``LanguageModelSessionBackend/transcriptEntries()``
    /// have already been persisted, so each turn's post-generation snapshot can
    /// diff against it to find only what the SDK appended *this* turn.
    ///
    /// `0` for a root session — nothing has been persisted yet. For a fork,
    /// this is the parent's entry count *at fork time*
    /// (``fork(workingDirectory:)`` captures it inside the serial gate it
    /// already holds, before ``LanguageModelSessionBackend/makeFork()`` seeds
    /// the child), so the inherited history the child's backend starts holding
    /// is never re-persisted into the child's own transcript.
    private var persistedEntryCount: Int

    /// Where this session's `session.json` comes from: its own write at init
    /// when the session is new, or the tree it was restored from.
    ///
    /// Inherited from the vending handle — so a fork's sidecar states the same
    /// slot/model/context this session's does — and handed on to every fork
    /// taken from this session (see ``SessionSidecarOrigin/forFork``).
    private nonisolated let sidecarOrigin: SessionSidecarOrigin

    /// Creates a session, landing its own `session.json` when it is a new one.
    ///
    /// The sidecar write happens here, synchronously, rather than at each
    /// creation site: a session records its own facts as it comes into
    /// existence, so no builder can produce a durable session directory that a
    /// transcript can land in with no sidecar beside it (see
    /// ``SessionSidecarOrigin``). It runs before the session exists to record
    /// anything, which is what makes "a session's facts are on disk before any
    /// of its transcript is" true by construction rather than by an awaited
    /// handshake. Failure is logged and dropped, so it can never fail a
    /// `makeSession` or a `fork`.
    ///
    /// Internal: construction is only via
    /// ``RoutedModel/makeSession(instructions:workingDirectory:)`` /
    /// ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:)``,
    /// ``fork(workingDirectory:)``, or
    /// ``RoutedModel/restoreSessionTree(root:registry:)``.
    ///
    /// - Parameters:
    ///   - persistedEntryCount: The baseline ``backend`` entry count
    ///     already persisted — `0` for a root session, or the parent's entry
    ///     count at fork time for a fork (see ``persistedEntryCount``). For a
    ///     new fork this is also the cut point recorded into its sidecar, so
    ///     the lineage cut point and the diff baseline are one fact.
    ///   - sidecarOrigin: Where this session's `session.json` comes from — a
    ///     write of its own at init, a tree it was restored from, or nothing
    ///     durable at all.
    init(
        profile: LanguageModelProfile,
        routerId: ULID,
        id: ULID,
        parentId: ULID?,
        recordingDirectory: URL,
        workingDirectory: URL,
        backend: any LanguageModelSessionBackend,
        slot: ModelSlot,
        model: ModelRef,
        recorder: any TranscriptRecorder,
        instructions: String?,
        grammar: Grammar? = nil,
        serialGate: AsyncSemaphore,
        forkAdmissionGate: AsyncSemaphore,
        holdsAdmissionPermit: Bool = false,
        persistedEntryCount: Int,
        sidecarOrigin: SessionSidecarOrigin
    ) {
        self.profile = profile
        self.routerId = routerId
        self.id = id
        self.parentId = parentId
        self.recordingDirectory = recordingDirectory
        self.workingDirectory = workingDirectory
        self.backend = backend
        self.slot = slot
        self.model = model
        self.recorder = recorder
        self.instructions = instructions
        self.grammar = grammar
        self.serialGate = serialGate
        self.forkAdmissionGate = forkAdmissionGate
        self.holdsAdmissionPermit = holdsAdmissionPermit
        self.persistedEntryCount = persistedEntryCount
        self.sidecarOrigin = sidecarOrigin

        // The session's own directory is brought into existence here, by its
        // write-once sidecar, before the session exists to record anything into
        // it — so any transcript a reader finds always has the facts to
        // interpret it sitting beside it. A session with no parent is a root and
        // carries no cut point; a fork's cut point *is* its diff baseline, read
        // from the one `persistedEntryCount` rather than passed a second time.
        sidecarOrigin.writeSidecarIfNew(
            instructions: instructions,
            grammar: grammar?.source,
            forkedAtEntryCount: parentId == nil ? nil : persistedEntryCount,
            to: recordingDirectory
        )
    }

    /// Releases this session's fork-admission permit when it is deallocated, so a
    /// fork blocked on the ceiling can proceed.
    ///
    /// Only a fork holds a permit; a root session's `deinit` is a no-op here. The
    /// session's backend is freed by ARC as the actor is torn down — releasing a
    /// fork frees whatever conversation state it holds.
    deinit {
        if holdsAdmissionPermit {
            forkAdmissionGate.signal()
        }
    }

    /// Generates a complete text response to a prompt, recording the call.
    ///
    /// Routes through the guided path when ``grammar`` is set, constraining the
    /// response to it through the backend's whole-chunk xgrammar entry point;
    /// otherwise runs the plain path. Both funnel through the same
    /// ``generate(grammar:_:)`` chokepoint.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: The model's complete text response.
    /// - Throws: Any error thrown by the model.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        // `backend` is this session's own persistent generation object — never
        // recreated per call — so turns accumulate conversation state. A guided
        // session constrains every response to its grammar, through the
        // backend's whole-chunk xgrammar entry point; an unguided session takes
        // the plain path. Both funnel through the same chokepoint, which stamps
        // the grammar (or `nil`) onto each event.
        if let grammar {
            return try await generate(grammar: grammar) {
                try await backend.respond(to: prompt, following: grammar, maxTokens: maxTokens)
            }
        }
        return try await generate {
            try await backend.respond(to: prompt, maxTokens: maxTokens)
        }
    }

    /// Streams a text response to a prompt as it is produced, recording the call.
    ///
    /// Wraps ``streamGenerating(prompt:maxTokens:into:)`` in an
    /// `AsyncThrowingStream`, forwarding each produced chunk to the stream's
    /// continuation and finishing it when generation completes or throws;
    /// cancelling the stream cancels the underlying `Task`.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    /// - Returns: A stream of response fragments, finishing when generation
    ///   completes or throwing if it fails.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamGenerating(prompt: prompt, maxTokens: maxTokens, into: continuation)
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
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` to use
    ///     the underlying model's own default ceiling.
    ///   - continuation: The stream continuation each produced chunk is yielded to.
    /// - Throws: Any error thrown by the model, after the chokepoint records the
    ///   close event.
    private func streamGenerating(
        prompt: String,
        maxTokens: Int?,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Accumulate the streamed chunks so the close event can carry the full
        // response body; the accumulated text is the recorded response, while the
        // caller has already received each chunk through the continuation.
        _ = try await generate {
            var response = ""
            for try await chunk in backend.streamResponse(to: prompt, maxTokens: maxTokens) {
                continuation.yield(chunk)
                response += chunk
            }
            return response
        }
    }

    func fork(workingDirectory: URL?) async throws -> RoutedSession {
        // Admission: at most the router's `maxConcurrentForks` fork sessions over
        // this model may be in flight at once. Past the ceiling this suspends
        // (FIFO) until an outstanding fork is released and frees its slot. The
        // permit is held for the child's lifetime and released in its `deinit`.
        await forkAdmissionGate.wait()

        // Acquire the serial gate before reading `backend`'s conversation state to
        // fork it. `generate(grammar:_:)` releases this same gate only
        // *after* `body()` returns, but `body()` itself suspends across an await
        // while the model generates — so a concurrent turn can be mid-flight,
        // outside the gate's protection window as far as `backend` internals are
        // concerned, mutating the underlying `LanguageModelSession.transcript` at
        // the exact moment `makeFork()` would otherwise read it. Taking the gate
        // here serializes the fork's read against any in-flight generation,
        // closing that data race; releasing it immediately after capturing the
        // forked backend keeps the hold no longer than necessary.
        await serialGate.wait()
        // Captured in the same gate window as `makeFork()`, so it names exactly
        // the entry count the child's seeded backend starts holding — the
        // child's own `persistedEntryCount` baseline, so the parent's history
        // inherited into the fork is never re-persisted into the child's
        // transcript (see ``persistedEntryCount``).
        let entryCountAtFork = backend.transcriptEntries().count
        let forkedBackend = backend.makeFork()
        serialGate.signal()

        let childId = ULID.generate()
        // The child's transcript nests directly *under this session's* directory,
        // so the on-disk tree mirrors the fork lineage: a root session lives at
        // `<base>/<routerId>/<rootId>/`, its fork at `.../<rootId>/<childId>/`, a
        // grandfork one level deeper again. Nesting is derived purely from the
        // parent chain — the child's `workingDirectory` override never moves it.
        let childRecordingDirectory = recordingDirectory
            .appendingPathComponent(childId.description, isDirectory: true)
        // The child lands its own sidecar as it is constructed, from the
        // `entryCountAtFork` baseline passed below — so `fork()` never returns a
        // durable child directory a transcript can land in with no sidecar
        // beside it, and needs no sidecar call of its own to say so (see
        // ``SessionSidecarOrigin``).
        return makeRoutedSessionActor(
            profile: profile,
            routerId: routerId,
            id: childId,
            parentId: id,
            recordingDirectory: childRecordingDirectory,
            workingDirectory: workingDirectory ?? childRecordingDirectory,
            backend: forkedBackend,
            slot: slot,
            model: model,
            recorder: recorder,
            instructions: instructions,
            grammar: grammar,
            serialGate: serialGate,
            forkAdmissionGate: forkAdmissionGate,
            holdsAdmissionPermit: true,
            persistedEntryCount: entryCountAtFork,
            // A fork is a brand-new session wherever its parent could record
            // one — including a fork of a restored session.
            sidecarOrigin: sidecarOrigin.forFork
        )
    }

    /// The single recorder-bracketed generation chokepoint every public method
    /// funnels through.
    ///
    /// The whole bracket runs inside the model's per-model serial gate
    /// (``RoutedModel/serialGate``), so concurrent generations on one model —
    /// including from forks that share the gate — queue in FIFO order rather than
    /// interleave. Inside the gate it first lazily records the session's
    /// first-line `session` meta event (once per session), then runs `body`, then
    /// snapshot-diffs ``backend``'s real transcript (see
    /// ``recordTranscriptDelta(grammar:since:usage:)``) so what lands on disk mirrors
    /// the SDK's own `Transcript.Entry` values rather than a hand-built
    /// paraphrase of the prompt/response strings — on the success path and the
    /// throwing path alike, so a transcript always gains whatever the SDK
    /// durably appended for the turn. A throwing turn additionally gets a
    /// bodyless `.response`-kind close event carrying the turn's `ms`, so every
    /// failed turn still leaves a trace even when the SDK appended no `.response`
    /// entry of its own. Every event is routed to this session's
    /// ``recordingDirectory``, so the on-disk transcript tree mirrors the fork
    /// lineage; the single recorder stamps a globally monotonic `seq` at append.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn, stamped
    ///     onto every event this turn appends.
    ///   - body: The model work to run inside the bracket, returning the response
    ///     text callers receive (still returned directly; no longer the source of
    ///     any recorded event body).
    /// - Returns: The response text `body` produced.
    /// - Throws: Whatever `body` throws, after recording whatever the SDK
    ///   appended plus the bodyless close event.
    private func generate(
        grammar: Grammar? = nil,
        _ body: () async throws -> String
    ) async throws -> String {
        // Acquire the serial permit for the whole bracket, releasing it on every
        // path with a `defer` (the recording bracket stays in this actor's
        // isolation region, so the gated work is not sent across an isolation
        // boundary as a `withPermit` closure would be). `wait()`/`signal()` pair
        // exactly like `withPermit`, so no permit can leak.
        await serialGate.wait()
        defer { serialGate.signal() }

        await recordSessionMetaIfNeeded()
        let started = Date()
        let usageBefore = backend.usageTokenCounts()
        do {
            let response = try await body()
            _ = await finishTurn(grammar: grammar, since: started, usageBefore: usageBefore)
            return response
        } catch {
            // Whatever the SDK durably appended before failing is still diffed
            // and persisted, with `ms` stamped the same way as the success path
            // (on the diff's own last `.response`-kind entry, if any) — a
            // post-generation failure can still leave the SDK having appended a
            // genuine `.response` entry before throwing.
            let (diffIncludedResponse, usage) = await finishTurn(grammar: grammar, since: started, usageBefore: usageBefore)
            // Only synthesize the router-only bodyless close when the SDK's own
            // diff did *not* already include a `.response`-kind entry — otherwise
            // this would double up two `.response` events for one turn, breaking
            // the "exactly one close per turn" invariant. This still guarantees
            // every failed turn leaves a trace: either the SDK's own `.response`
            // entry (mapped above) or this synthetic one.
            if !diffIncludedResponse {
                await append(
                    partial: makePartialEvent(
                        kind: .response,
                        grammar: grammar,
                        since: started,
                        tokensIn: usage?.input,
                        tokensOut: usage?.output
                    )
                )
            }
            throw error
        }
    }

    /// Computes this turn's usage delta and records whatever the SDK's
    /// transcript diff contains — the one place both of ``generate(grammar:_:)``'s
    /// success and throwing exits go through, so the usage-delta computation
    /// and the ``recordTranscriptDelta(grammar:since:usage:)`` call are made in
    /// exactly one place rather than duplicated per branch.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force, forwarded to
    ///     ``recordTranscriptDelta(grammar:since:usage:)``.
    ///   - since: The turn's start instant, forwarded to
    ///     ``recordTranscriptDelta(grammar:since:usage:)`` to stamp `ms`.
    ///   - usageBefore: The pre-turn snapshot captured immediately before
    ///     `body()` ran.
    /// - Returns: Whether the diff included a `.response`-kind entry — the
    ///   throwing path uses this to decide whether a synthetic bodyless close
    ///   is still needed — and the turn's own usage delta (`nil` if the
    ///   backend cannot report usage), which the throwing path stamps onto
    ///   that synthetic close.
    private func finishTurn(
        grammar: Grammar?,
        since: Date,
        usageBefore: (input: Int, output: Int)?
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?) {
        let usage = Self.usageDelta(before: usageBefore, after: backend.usageTokenCounts())
        let diffIncludedResponse = await recordTranscriptDelta(
            grammar: grammar, since: since, usage: usage)
        return (diffIncludedResponse, usage)
    }

    /// The per-turn token usage delta between two ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots taken immediately before and after a turn's `body()` ran.
    ///
    /// `nil` when either snapshot is `nil` — a backend that cannot report
    /// usage at all, or one that stopped being able to mid-turn — rather than
    /// synthesizing a delta from a partial reading.
    ///
    /// - Parameters:
    ///   - before: The snapshot taken immediately before `body()` ran.
    ///   - after: The snapshot taken immediately after `body()` returned or
    ///     threw.
    /// - Returns: The turn's own `(input, output)` token counts, or `nil`.
    private static func usageDelta(
        before: (input: Int, output: Int)?,
        after: (input: Int, output: Int)?
    ) -> (input: Int, output: Int)? {
        guard let before, let after else { return nil }
        return (after.input - before.input, after.output - before.output)
    }

    /// Snapshot-diffs ``backend``'s real transcript against ``persistedEntryCount``
    /// and persists exactly what the SDK appended since the last diff — the core
    /// of the "persist the SDK's own `Transcript`, not a paraphrase" design (see
    /// plan.md's "Transcript fidelity" section).
    ///
    /// Reads `backend.transcriptEntries()` once. If a shrink is detected
    /// (`entries.count < persistedEntryCount` — nothing guarantees the SDK
    /// transcript stays strictly append-only forever; a future
    /// `TranscriptErrorHandlingPolicy` opt-in could condense or rewrite it),
    /// this logs a warning, records nothing for this turn's diff, and resets
    /// ``persistedEntryCount`` to the smaller count so the next turn diffs from
    /// reality instead of tripping the same guard again. Otherwise the
    /// last-seen (the first ``persistedEntryCount`` entries) and current (all
    /// of `entries`) states are diffed via ``TranscriptDiffer/diff(lastSeen:current:routerId:sessionId:parentId:slot:model:)``
    /// — the one diff implementation this session shares with the upcoming
    /// recording handle — which maps every new entry through
    /// ``TranscriptEntryMapper/event(from:)`` and stamps this session's
    /// identity onto each produced partial.
    ///
    /// Each produced partial is then re-stamped with this turn's `grammar`
    /// and appended as its own event. When `since` is non-nil, the turn's
    /// measured `ms` is stamped only on the *last* `.response`-kind event the
    /// diff produced — not on every appended event — on the success path and
    /// the throwing path alike, so an SDK-appended `.response` entry from a
    /// turn that failed *after* generating still gets the turn's `ms`.
    /// `usage` (the turn's own `tokensIn`/`tokensOut` delta, or `nil` when the
    /// backend cannot report usage) is stamped the same way, on that same
    /// last `.response`-kind event — mirroring `ms`, since both are per-turn
    /// totals that only make sense attributed to the turn's one closing
    /// event, not every entry it appended.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force, stamped onto every
    ///     appended event.
    ///   - since: The turn's start instant to stamp `ms` with on the diff's last
    ///     `.response`-kind event, or `nil` to leave `ms` unset on every
    ///     appended event.
    ///   - usage: The turn's own `(input, output)` token usage delta to stamp
    ///     as `tokensIn`/`tokensOut` on the diff's last `.response`-kind
    ///     event, or `nil` to leave both unset on every appended event.
    /// - Returns: Whether this diff included a `.response`-kind entry — the
    ///   throwing path in ``generate(grammar:_:)`` uses this to decide whether
    ///   a synthetic bodyless close is still needed, so a turn whose SDK
    ///   transcript already gained a real `.response` entry before failing
    ///   never gets two `.response` events.
    @discardableResult
    private func recordTranscriptDelta(
        grammar: Grammar?,
        since: Date?,
        usage: (input: Int, output: Int)?
    ) async -> Bool {
        let entries = backend.transcriptEntries()
        guard entries.count >= persistedEntryCount else {
            sessionRecordingLogger.warning(
                """
                transcript shrank from \(self.persistedEntryCount, privacy: .public) to \
                \(entries.count, privacy: .public) entries for session \
                \(self.id.description, privacy: .public); recording no entries for this turn and \
                resetting the baseline
                """
            )
            persistedEntryCount = entries.count
            return false
        }

        let diffPartials = TranscriptDiffer.diff(
            lastSeen: Transcript(entries: entries.prefix(persistedEntryCount)),
            current: Transcript(entries: entries),
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard !diffPartials.isEmpty else { return false }

        let lastResponseIndex = diffPartials.lastIndex { $0.kind == .response }

        for (index, diffPartial) in diffPartials.enumerated() {
            let isTurnClose = index == lastResponseIndex
            let stampSince = (since != nil && isTurnClose) ? since : nil
            let stampUsage = (usage != nil && isTurnClose) ? usage : nil
            await append(
                partial: makePartialEvent(
                    kind: diffPartial.kind,
                    grammar: grammar,
                    text: diffPartial.text,
                    since: stampSince,
                    entry: diffPartial.entry,
                    tokensIn: stampUsage?.input,
                    tokensOut: stampUsage?.output
                )
            )
        }
        persistedEntryCount = entries.count
        return lastResponseIndex != nil
    }

    /// Records the session's first-line `session` meta event the first time this
    /// session records anything, so a generating session's transcript always opens
    /// with a `session` line while a session that never generates writes no file.
    ///
    /// The flag is flipped before the append so a reentrant turn during the meta
    /// append's suspension cannot emit a second meta event.
    private func recordSessionMetaIfNeeded() async {
        guard !didRecordSessionMeta else { return }
        didRecordSessionMeta = true
        await append(partial: makePartialEvent(kind: .session, grammar: grammar))
    }

    /// Appends a partial event through the recorder into this session's own
    /// transcript directory, so siblings write separate files and the on-disk tree
    /// mirrors the fork lineage.
    ///
    /// - Parameter partial: The event to record, minus its recorder-owned `seq`
    ///   and `ts`.
    private func append(partial: TranscriptEvent.Partial) async {
        await recorder.append(partial, to: recordingDirectory)
    }

    /// Builds an event of the given kind stamped with this session's provenance.
    ///
    /// The `session` meta event, every entry-derived event
    /// ``recordTranscriptDelta(grammar:since:usage:)`` appends, and the throwing
    /// path's bodyless close event all share this one helper; a close-carrying
    /// call passes `since` to record the turn's measured duration.
    ///
    /// - Parameters:
    ///   - kind: The event kind to stamp — `.session` for meta, or the mapped
    ///     ``TranscriptEntryMapper/event(from:)`` kind for an entry-derived event.
    ///   - grammar: The guided-generation grammar in force, recorded as its
    ///     source, or `nil` for an unconstrained turn.
    ///   - text: The event's flattened body text from the mapper, or `nil` for
    ///     the bodyless `session` meta event or a bodyless close. Recording-level
    ///     and redaction trimming happen later, in the recorder.
    ///   - since: The turn's start instant to stamp `ms` with, or `nil` to leave
    ///     `ms` unset.
    ///   - entry: The structural payload mirroring the SDK's own
    ///     `Transcript.Entry`, or `nil` for the `session` meta event and the
    ///     throwing path's bodyless close.
    ///   - tokensIn: The turn's input token usage delta to stamp, or `nil` to
    ///     leave it unset.
    ///   - tokensOut: The turn's output token usage delta to stamp, or `nil`
    ///     to leave it unset.
    /// - Returns: The partial event for the recorder to stamp and append.
    private func makePartialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil,
        text: String? = nil,
        since: Date? = nil,
        entry: TranscriptEntryPayload? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: kind,
            grammar: grammar?.source,
            text: text,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            ms: since.map { Int(Date().timeIntervalSince($0) * 1_000) },
            entry: entry
        )
    }
}
