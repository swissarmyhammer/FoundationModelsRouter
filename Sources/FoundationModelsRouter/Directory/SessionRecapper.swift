import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Tracing

/// The flash model of one recap call (D206): the model reference, its token
/// counter, the tracer of the recap span, and the factory of a new blank
/// backend for each call.
struct SessionRecapModel: Sendable {
    /// The model reference of the flash model. The recap waits while a
    /// session on this model has a running turn.
    let model: ModelRef

    /// The counter of the flash model, for the token limit of the input and
    /// the token counts of the span.
    let tokenCounter: any TokenCounter

    /// The tracer of the recap span, or `nil` to read
    /// `InstrumentationSystem.tracer` at call time.
    let tracer: (any Tracer)?

    /// Makes a new blank backend over the flash model, with no instructions,
    /// no tools and no transcript. Each recap call gets its own, so a recap
    /// never uses and never changes the KV cache or the transcript of a
    /// session.
    let makeBackend: @Sendable () -> any LanguageModelSessionBackend
}

extension SessionRecapModel {
    /// The recap model of the `flash` slot of a profile, as the compaction
    /// makes its flash summarizer (``RoutedSessionActor``): a new blank
    /// session of the flash container, here with greedy decoding (temperature
    /// 0).
    ///
    /// - Parameters:
    ///   - flash: The `flash` slot of the profile of the session.
    ///   - tracer: The tracer of the session, or `nil`.
    init(flash: RoutedLLM, tracer: (any Tracer)?) {
        let container = flash.container
        self.init(
            model: flash.chosen, tokenCounter: container.tokenCounter, tracer: tracer,
            makeBackend: { container.makeSession(instructions: nil, samplingMode: .greedy) })
    }
}

/// The recap maker of a ``RouterSessionDirectory`` (D206): it makes the recap
/// of each root session and each fork, one sentence of at most 200
/// characters about what the session did and where it stands now.
///
/// The directory gives it each event of each live session
/// (``observe(_:of:isIdle:getsRecap:)``), under the lock that applies the
/// event to the state tracking, before the `stateChanged` of the event goes
/// out; and the prompt text of each user-type mail that an answer delivered
/// (``noteDelivered(_:of:)``). The recapper keeps, for each session, the
/// user prompts, the tool calls and the last final message since the last
/// recap.
///
/// - A turn is trivial when its last answer ended with a cancel or an
///   error, or when it has no tool call and its final reply has fewer than
///   ``trivialReplyLength`` characters. A trivial turn starts no wait and no
///   call.
/// - At the end of a turn with the state idle, when the session has a turn
///   that is not trivial since the last recap, and the session gets a recap
///   (a root session or a fork, live, not archived, with the recap policy of
///   its folder on), a wait of ``idleTime`` starts on the clock. Before the
///   call, the host tells again whether the session gets a recap
///   (``Host/target``).
/// - The start of a turn of the session cancels its wait, takes it out of
///   the queue, or cancels its running call; the output of a cancelled call
///   is discarded. The turns that are not trivial add up until a recap is
///   written.
/// - After the wait, the session goes into the one queue of the recapper.
///   One call runs at a time. Before a call starts, it waits until no live
///   session on the flash model has a running turn (``Host/isModelBusy``).
/// - The call runs in a new blank session of the flash model with only the
///   recap prompt (``SessionRecapInput``, ``SessionRecapPrompt``), with the
///   reasoning off and at most ``outputTokenLimit`` output tokens. One
///   ``RouterTelemetry/SpanName/recap`` span records it.
/// - The cleaned output (``SessionRecapOutput``) goes to the record through
///   ``Host/write``. The host commits the write only when the job of the
///   recap is still current: the check and the change of the record are one
///   step (``Host/write``), so a cancel that comes while the write goes to
///   the host writes nothing, and the next recap keeps the prompts. A
///   failure, or an output with no words, writes nothing, so the record
///   keeps its previous recap. The span records the error.
/// - ``forget(_:)`` (an archive, a close) cancels the wait and the call of
///   the session and drops what the recapper keeps of it.
///
/// A recap never blocks or slows a turn of its own session: the call is no
/// submission of the session, and a new turn of the session cancels it.
final class SessionRecapper: Sendable {
    /// The seconds of ``idleTime``.
    static let idleSeconds: Int64 = 20

    /// The idle time after a turn before the recap call.
    static let idleTime: Duration = .seconds(idleSeconds)

    /// The fewest characters of a final reply that make a turn with no tool
    /// call not trivial.
    static let trivialReplyLength = 280

    /// The most output tokens of a recap call.
    static let outputTokenLimit = 80

    /// The most user prompts the recapper keeps for one session. The input
    /// holds at most ``SessionRecapInput/tokenLimit`` tokens, and each prompt
    /// holds up to ``SessionRecapInput/promptCharacterLimit`` characters, so
    /// older prompts never reach the input.
    static let keptPromptLimit = 32

    /// The most tool call lines the recapper keeps for one session.
    static let keptToolCallLimit = 64

    /// The session that the host gives a recap: the flash model of the call,
    /// and the recap that the record holds.
    struct Target: Sendable {
        /// The flash model of the call.
        let model: SessionRecapModel

        /// The recap that the record holds, or `nil`.
        let previousRecap: String?
    }

    /// What the recapper asks of its owner, the session directory.
    struct Host: Sendable {
        /// The target of the session `id`, or `nil` when the session gets no
        /// recap: a subagent, a session that is not live or is archived, or
        /// a session of a folder whose recap policy is off.
        let target: @Sendable (_ id: ULID) -> Target?

        /// Whether a live session on the model `model` has a running turn.
        let isModelBusy: @Sendable (_ model: ModelRef) -> Bool

        /// Writes `recap`, made at `instant`, to the record of the session
        /// `id`, when `commit` returns `true`.
        ///
        /// The host calls `commit` one time, in one step with the change of
        /// the record: with no suspension point between the two, and under
        /// the lock or on the actor that orders the write with the archive
        /// and the close of the session. `commit` reads, under the lock of
        /// the recapper, whether the job of the recap is still current, and
        /// it then removes what the recap covers. When it returns `false` (a
        /// new turn, an archive, a close or a shutdown cancelled the job),
        /// the host writes nothing and sends no event.
        let write:
            @Sendable (_ recap: String, _ instant: Date, _ id: ULID, _ commit: @escaping @Sendable () -> Bool)
                async throws -> Void

        /// The host before the owner gives its own: no session gets a recap.
        static let none = Host(target: { _ in nil }, isModelBusy: { _ in false }, write: { _, _, _, _ in })
    }

    /// The facts of the turn that runs or ran last.
    fileprivate struct Turn {
        /// The number of tool calls of the answers of the turn.
        var toolCallCount = 0

        /// The final reply of the last answer of the turn, or `nil`.
        var reply: String?

        /// Whether the last answer of the turn ended with a cancel or an
        /// error.
        var failed = false

        /// Whether the turn is trivial.
        var isTrivial: Bool {
            failed || (toolCallCount == 0 && (reply?.count ?? 0) < SessionRecapper.trivialReplyLength)
        }
    }

    /// Where the recap of one session is.
    fileprivate enum Phase {
        /// The wait of the idle time, in its task.
        case waiting(Task<Void, Never>)

        /// In the queue, after the wait.
        case queued

        /// The call, in its task.
        case running(Task<Void, Never>)
    }

    /// The one recap of a session that waits, queues or runs.
    fileprivate struct Job {
        /// The id of the job, so a task of a cancelled job changes nothing.
        let id: UInt64

        /// Where the job is.
        var phase: Phase
    }

    /// What the recapper keeps of one session since its last recap.
    fileprivate struct Track {
        /// The user prompts, the oldest first.
        var prompts: [DeliveredPrompt] = []

        /// The tool call lines, the oldest first.
        var toolCalls: [String] = []

        /// The last final message, cut to
        /// ``SessionRecapInput/lastMessageCharacterLimit`` characters.
        var lastMessage: String?

        /// The number of turns that are not trivial since the last recap.
        var turnsToRecap = 0

        /// The turn that runs or ran last.
        var turn = Turn()

        /// The recap that waits, queues or runs, or `nil`.
        var job: Job?
    }

    /// The facts that one call reads, and that a written recap consumes.
    private struct Snapshot: Sendable {
        /// The input of the call, with no previous recap yet.
        let input: SessionRecapInput

        /// The number of prompts of the input.
        let promptCount: Int

        /// The number of tool call lines of the input.
        let toolCallCount: Int

        /// The number of turns that are not trivial that the recap covers.
        let turnCount: Int
    }

    /// The mutable state, behind one lock.
    fileprivate struct State {
        /// The host of the recapper.
        var host = Host.none

        /// The clock of the waits.
        var clock: any RunClock

        /// What the recapper keeps of each session, by session id.
        var tracks: [ULID: Track] = [:]

        /// The sessions whose wait ended, in order.
        var queue: [ULID] = []

        /// The task that runs the calls of the queue one at a time, or `nil`
        /// while the queue is empty.
        var worker: Task<Void, Never>?

        /// The id of the next job.
        var nextJobID: UInt64 = 0

        /// The number of call tasks that did not end, also of jobs that a
        /// new turn or an archive cancelled.
        var activeCalls = 0
    }

    /// The state.
    private let state: Mutex<State>

    /// Signals each change of the work of a session on any model
    /// (``observe(_:of:isIdle:getsRecap:)``). A call that waits for the flash model
    /// waits on it.
    private let workChanges = ChangeSignal()

    /// Signals each change of ``jobCount``. Only the tests read it.
    let jobChanges = ChangeSignal()

    /// Makes a recapper with no host: no session gets a recap until
    /// ``use(host:)``.
    ///
    /// - Parameter clock: The clock of the waits. The default is the real
    ///   time.
    init(clock: any RunClock = ContinuousRunClock()) {
        state = Mutex(State(clock: clock))
    }

    /// The number of recaps that wait or queue, plus the calls that did not
    /// end. Only the tests read it.
    var jobCount: Int {
        state.withLock { current in
            current.activeCalls + current.tracks.values.filter { $0.job?.isWaitingOrQueued ?? false }.count
        }
    }

    /// Gives the recapper its host.
    ///
    /// - Parameter host: The host.
    func use(host: Host) {
        state.withLock { $0.host = host }
    }

    /// Gives the recapper the clock of its waits. A wait that runs keeps its
    /// clock.
    ///
    /// - Parameter clock: The clock.
    func use(clock: any RunClock) {
        state.withLock { $0.clock = clock }
    }

    /// Keeps the prompts that an answer of the session `id` delivered. A
    /// prompt of a mail that the recapper keeps already is not kept again,
    /// so a mail that a failed submission gave back counts one time.
    ///
    /// - Parameters:
    ///   - prompts: The delivered prompts, in take order.
    ///   - id: The session id.
    func noteDelivered(_ prompts: [DeliveredPrompt], of id: ULID) {
        state.withLock { current in
            var track = current.tracks[id] ?? Track()
            let known = Set(track.prompts.map(\.mail))
            let new = prompts.filter { !known.contains($0.mail) }
            track.prompts = Array((track.prompts + new).suffix(Self.keptPromptLimit))
            current.tracks[id] = track
        }
    }

    /// Applies one event of the session `id`, after the state tracking of
    /// the directory applied it.
    ///
    /// The call takes no lock but the lock of the recapper, and it calls no
    /// host, so the directory calls it under its own lock. A cancel that it
    /// makes runs the cancel handlers of a recap task: the wait of the clock,
    /// the wait for the flash model and the call of the model, and none of
    /// them takes the lock of the directory.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - id: The session id.
    ///   - isIdle: Whether the state of the session is `idle` after the
    ///     event.
    ///   - getsRecap: Whether the session gets a recap: a live root session
    ///     or fork, not archived, with the recap policy of its folder on. The
    ///     recapper reads it at the end of a turn.
    func observe(_ event: SessionEvent, of id: ULID, isIdle: Bool, getsRecap: Bool) {
        switch event {
        case .workStarted:
            workChanges.signal()
            turnStarted(id)
        case .workEnded:
            workChanges.signal()
            turnEnded(id, startsWait: isIdle && getsRecap)
        case .answered(let answer):
            noteAnswer(answer, of: id)
        case .answerFailed:
            changeTrack(of: id) { $0.turn.failed = true }
        case .textDelta, .textReset, .reasoningDelta, .toolCall, .toolStatus, .toolInvocation, .toolCallReport,
            .toolDisplay, .entryRecorded, .compactionStarted, .compaction, .compactionFailed, .discoveryPrimingFailed,
            .generationStalled, .submissionStarted, .submissionEnded, .repetitionStopped, .reasoningStopped,
            .runSettled, .runMessage, .runProgress, .elicitationRequested, .generationCall, .mailDeliveryPaused,
            .mailDelivered, .cancelled, .signalDone, .lost, .elicitationEnded, .elicitationCompleted:
            // The answer carries the tool calls and the reply of the turn,
            // and the work events frame the turn. No other event changes the
            // recap.
            break
        }
    }

    /// Cancels the wait and the call of the session `id`, and drops what the
    /// recapper keeps of it: the session was archived or closed. An
    /// unarchive starts nothing.
    ///
    /// - Parameter id: The session id.
    func forget(_ id: ULID) {
        let task = state.withLock { current -> Task<Void, Never>? in
            let task = current.takeJob(of: id)
            current.tracks[id] = nil
            return task
        }
        task?.cancel()
        jobChanges.signal()
    }

    /// Cancels each wait and each call, and drops what the recapper keeps:
    /// the directory shuts down.
    func cancelAll() {
        let tasks = state.withLock { current -> [Task<Void, Never>] in
            let tasks = current.tracks.keys.compactMap { current.takeJob(of: $0) }
            current.tracks = [:]
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
        jobChanges.signal()
    }

    // MARK: - Turns

    /// A turn of the session `id` starts: its wait, its place in the queue
    /// or its call ends, and the facts of the new turn start empty.
    ///
    /// - Parameter id: The session id.
    private func turnStarted(_ id: ULID) {
        let task = state.withLock { current -> Task<Void, Never>? in
            let task = current.takeJob(of: id)
            current.tracks[id, default: Track()].turn = Turn()
            return task
        }
        task?.cancel()
        jobChanges.signal()
    }

    /// Keeps the tool calls and the reply of one answer of the session `id`.
    ///
    /// - Parameters:
    ///   - answer: The answer.
    ///   - id: The session id.
    private func noteAnswer(_ answer: SessionAnswer, of id: ULID) {
        let lines = answer.toolCalls.map {
            SessionRecapInput.toolCallLine(name: $0.name, argumentsJSON: $0.argumentsJSON)
        }
        changeTrack(of: id) { track in
            track.toolCalls = Array((track.toolCalls + lines).suffix(Self.keptToolCallLimit))
            track.lastMessage = String(answer.reply.prefix(SessionRecapInput.lastMessageCharacterLimit))
            track.turn.toolCallCount += answer.toolCalls.count
            track.turn.reply = answer.reply
            track.turn.failed = false
        }
    }

    /// A turn of the session `id` ended: a turn that is not trivial adds up,
    /// and the wait starts when the session has a turn to recap.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - startsWait: Whether the end can start the wait: the state is idle
    ///     and the session gets a recap.
    private func turnEnded(_ id: ULID, startsWait: Bool) {
        let hasTurnsToRecap = state.withLock { current -> Bool in
            var track = current.tracks[id] ?? Track()
            if !track.turn.isTrivial {
                track.turnsToRecap += 1
            }
            current.tracks[id] = track
            return track.turnsToRecap > 0
        }
        guard startsWait, hasTurnsToRecap else { return }
        startWait(of: id)
    }

    /// Changes what the recapper keeps of the session `id`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - change: The change.
    private func changeTrack(of id: ULID, _ change: (inout Track) -> Void) {
        state.withLock { change(&$0.tracks[id, default: Track()]) }
    }

    // MARK: - The wait and the queue

    /// Starts the wait of the idle time of the session `id`. The deadline is
    /// set now, so a clock that moves before the task starts still ends the
    /// wait.
    ///
    /// - Parameter id: The session id.
    private func startWait(of id: ULID) {
        let earlier = state.withLock { current -> Task<Void, Never>? in
            let earlier = current.takeJob(of: id)
            let jobID = current.nextJobID
            current.nextJobID += 1
            let clock = current.clock
            let deadline = clock.now.advanced(by: Self.idleTime)
            let task = Task { [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                self?.enqueue(id, job: jobID)
            }
            current.tracks[id, default: Track()].job = Job(id: jobID, phase: .waiting(task))
            return earlier
        }
        earlier?.cancel()
        jobChanges.signal()
    }

    /// Puts the session `id` into the queue after its wait, and starts the
    /// worker when none runs. A job that a turn or an archive cancelled
    /// changes nothing.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - jobID: The id of the job whose wait ended.
    private func enqueue(_ id: ULID, job jobID: UInt64) {
        state.withLock { current in
            guard current.tracks[id]?.job?.id == jobID else { return }
            current.tracks[id]?.job?.phase = .queued
            current.queue.append(id)
            guard current.worker == nil else { return }
            current.worker = Task { [weak self] in await self?.runQueue() }
        }
        jobChanges.signal()
    }

    /// Runs the calls of the queue, one at a time, until the queue is empty.
    private func runQueue() async {
        while let call = startNextCall() {
            await call.value
        }
    }

    /// Takes the first session of the queue and starts its call. The call
    /// task starts under the lock, so a new turn that comes at once finds it
    /// and cancels it.
    ///
    /// - Returns: The task of the call, or `nil` when the queue is empty. The
    ///   worker then ends.
    private func startNextCall() -> Task<Void, Never>? {
        state.withLock { current in
            while !current.queue.isEmpty {
                let id = current.queue.removeFirst()
                // A cancel takes the session out of the queue with its job,
                // so each session of the queue has its job.
                guard let jobID = current.tracks[id]?.job?.id else { continue }
                current.activeCalls += 1
                let call = Task { [weak self] in
                    await self?.makeRecap(of: id, job: jobID)
                    self?.endCall(of: id, job: jobID)
                }
                current.tracks[id]?.job?.phase = .running(call)
                return call
            }
            current.worker = nil
            return nil
        }
    }

    /// Ends the call of the job `jobID` of the session `id`: the call does
    /// not count any more, and a job that no turn cancelled ends.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - jobID: The id of the job.
    private func endCall(of id: ULID, job jobID: UInt64) {
        state.withLock { current in
            current.activeCalls -= 1
            if current.tracks[id]?.job?.id == jobID {
                current.tracks[id]?.job = nil
            }
        }
        jobChanges.signal()
    }

    // MARK: - The call

    /// Makes the recap of the session `id`: waits until no session on the
    /// flash model has a running turn, calls the flash model, and writes the
    /// recap. A cancel at any step writes nothing.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - jobID: The id of the job.
    private func makeRecap(of id: ULID, job jobID: UInt64) async {
        let host = state.withLock { $0.host }
        guard let target = host.target(id),
            await workChanges.waitUntil({ !host.isModelBusy(target.model.model) }),
            let snapshot = snapshot(of: id, job: jobID),
            let current = host.target(id)
        else { return }
        var input = snapshot.input
        input.previousRecap = current.previousRecap
        do {
            let recap = try await Self.call(current.model, with: input, of: id)
            try Task.checkCancellation()
            try await host.write(recap, Date(), id) { [weak self] in
                self?.commit(snapshot, of: id, job: jobID) ?? false
            }
        } catch {
            RouterSessionDirectory.logSession(
                .notice, "a recap call failed; the session keeps its previous recap", session: id, error: error)
        }
    }

    /// The input of the call of the job `jobID` of the session `id`, from
    /// what the recapper keeps now.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - jobID: The id of the job.
    /// - Returns: The snapshot, or `nil` when a turn or an archive cancelled
    ///   the job.
    private func snapshot(of id: ULID, job jobID: UInt64) -> Snapshot? {
        state.withLock { current in
            guard let track = current.tracks[id], track.job?.id == jobID else { return nil }
            return Snapshot(
                input: SessionRecapInput(
                    previousRecap: nil, prompts: track.prompts.map(\.text), toolCalls: track.toolCalls,
                    lastMessage: track.lastMessage),
                promptCount: track.prompts.count, toolCallCount: track.toolCalls.count,
                turnCount: track.turnsToRecap)
        }
    }

    /// Commits the write of the recap of the job `jobID` of the session
    /// `id`: when the job is still current, removes what the recap covers
    /// (the prompts, the tool calls and the turns of its input) and gives
    /// `true`. What came after the snapshot stays for the next recap.
    ///
    /// The check and the removal are one step under the lock of the
    /// recapper, which each cancel of a job takes too. The host calls it in
    /// one step with its write (``Host/write``).
    ///
    /// - Parameters:
    ///   - snapshot: The snapshot of the recap.
    ///   - id: The session id.
    ///   - jobID: The id of the job.
    /// - Returns: `true` when the host can write the recap; `false` when a
    ///   new turn, an archive, a close or a shutdown cancelled the job.
    private func commit(_ snapshot: Snapshot, of id: ULID, job jobID: UInt64) -> Bool {
        state.withLock { current in
            guard var track = current.tracks[id], track.job?.id == jobID else { return false }
            track.prompts.removeFirst(min(snapshot.promptCount, track.prompts.count))
            track.toolCalls.removeFirst(min(snapshot.toolCallCount, track.toolCalls.count))
            track.turnsToRecap = max(0, track.turnsToRecap - snapshot.turnCount)
            current.tracks[id] = track
            return true
        }
    }

    /// Calls the flash model in a new blank session with the recap prompt,
    /// inside one recap span.
    ///
    /// - Parameters:
    ///   - model: The flash model.
    ///   - input: The input of the call.
    ///   - id: The session id.
    /// - Returns: The recap.
    /// - Throws: The error of the model, ``SessionRecapError/emptyOutput``
    ///   for an output with no words, or `CancellationError`.
    private static func call(_ model: SessionRecapModel, with input: SessionRecapInput, of id: ULID) async throws
        -> String
    {
        let prompt = input.prompt(countingWith: model.tokenCounter)
        return try await RouterTelemetry.withSpan(RouterTelemetry.SpanName.recap, ofKind: .client, tracer: model.tracer)
        { span in
            span.attributes[RouterTelemetry.AttributeKey.sessionId] = id.description
            span.attributes[RouterTelemetry.AttributeKey.slot] = ModelSlot.flash.rawValue
            span.attributes[RouterTelemetry.AttributeKey.modelRef] = model.model.stringValue
            span.attributes[RouterTelemetry.AttributeKey.tokensIn] = model.tokenCounter.count(prompt)
            let output = try await model.makeBackend().respondWithoutReasoning(
                to: prompt, maxTokens: outputTokenLimit)
            span.attributes[RouterTelemetry.AttributeKey.tokensOut] = model.tokenCounter.count(output)
            guard let recap = SessionRecapOutput.recap(from: output) else { throw SessionRecapError.emptyOutput }
            return recap
        }
    }
}

/// Why a recap call wrote no recap, besides the error of the model.
enum SessionRecapError: Error, Equatable {
    /// The output of the model had no words.
    case emptyOutput
}

extension SessionRecapper.Job {
    /// Whether the job waits for its idle time or waits in the queue.
    fileprivate var isWaitingOrQueued: Bool {
        if case .running = phase { return false }
        return true
    }

    /// The task of the job, or `nil` for a job in the queue.
    fileprivate var task: Task<Void, Never>? {
        switch phase {
        case .waiting(let task), .running(let task):
            return task
        case .queued:
            return nil
        }
    }
}

extension SessionRecapper.State {
    /// Takes the job of the session `id` off its track and out of the queue.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The task of the job, for the caller to cancel outside the
    ///   lock, or `nil` when the session has no job or its job is in the
    ///   queue.
    fileprivate mutating func takeJob(of id: ULID) -> Task<Void, Never>? {
        let job = tracks[id]?.job
        tracks[id]?.job = nil
        queue.removeAll { $0 == id }
        return job?.task
    }
}
