import Foundation
import FoundationModels
import Synchronization

/// Extracts per-call detachment clocks from a call's opaque arguments.
///
/// The per-call clock sourcing hook: a wrapped tool that conforms lets the
/// ``DetachingTool`` engine read a per-call `waitSeconds` and/or `timeout`
/// out of the call's `GeneratedContent` — however the tool encodes them —
/// instead of using the wrap-time ``DetachConfiguration``. A `nil` field
/// falls back to that configuration; a tool that does not conform always
/// uses it.
public protocol DetachmentParameterProviding {
    /// Returns the per-call clocks encoded in `arguments`, or `nil` fields
    /// for whichever the call does not supply.
    ///
    /// - Parameter arguments: The call's arguments as opaque
    ///   `GeneratedContent` — the same content the tool's typed `Arguments`
    ///   were decoded from.
    /// - Returns: The per-call `waitSeconds` and `timeout`, each `nil` to
    ///   fall back to the wrap-time configuration.
    func detachmentClocks(
        from arguments: GeneratedContent
    ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?)
}

/// The wrap-time clock and mode configuration of a ``DetachingTool``.
///
/// The two clocks (eventplan.md § "Consolidation of the siblings"):
///
/// | Clock | Bounds | Reset by |
/// |---|---|---|
/// | ``waitSeconds`` | how long `call(arguments:)` blocks before detaching | nothing |
/// | ``timeout`` | how long the work itself may run | every progress event |
///
/// Progress keeps the work alive; it never buys the caller more waiting
/// time. Both values can be overridden per call through
/// ``DetachmentParameterProviding``.
public struct DetachConfiguration: Sendable, Equatable {
    /// Whether a call detaches at ``waitSeconds`` or runs to completion.
    public enum Mode: Sendable, Equatable {
        /// Race each call against ``DetachConfiguration/waitSeconds``;
        /// a call that does not complete in the window parks in the
        /// session's ``SessionMailbox`` and returns the pending envelope.
        /// Router's native-session mount.
        case detaching

        /// Run each call to completion, bounded only by
        /// ``DetachConfiguration/timeout`` — detachment off, the mode
        /// `ToolInvoker` mounts for inner `tools.*` calls. The same engine
        /// still owns correlation, events, and outcomes.
        case runToCompletion
    }

    /// The stock soft deadline: how long a call blocks before detaching —
    /// Router's mount default, shared with the sibling packages' own
    /// defaults so the tools behave alike on the clock a host is most
    /// likely to leave alone.
    public static let defaultWaitSeconds: TimeInterval = 5

    /// The stock per-call timeout — deliberately much longer than
    /// ``defaultWaitSeconds`` so at stock settings the soft deadline always
    /// wins: a silent call detaches as pending long before its timeout
    /// could cancel it, leaving real timeout headroom for follow-up.
    public static let defaultTimeoutSeconds: TimeInterval = 120

    /// Router's native-session mount: detachment on, stock clocks
    /// (``defaultWaitSeconds``/``defaultTimeoutSeconds``). The one
    /// configuration all three tool-composition sites apply —
    /// `RoutedModel.makeSession`, `RoutedSessionActor.fork`, and
    /// `restoreSessionTree` — so the mount policy has exactly one
    /// definition (eventplan.md § "Elevation" — that plan's name for
    /// detachment: two mounts, one engine, two policies; this is the
    /// native mount).
    public static let nativeSessionMount = DetachConfiguration(mode: .detaching)

    /// Whether a call detaches at ``waitSeconds`` or runs to completion.
    public var mode: Mode

    /// How long one call may block before detaching, in seconds. Nothing
    /// resets it. `0` detaches immediately. Ignored in
    /// ``Mode/runToCompletion``.
    public var waitSeconds: TimeInterval

    /// How long the work itself may run, in seconds. Every progress event
    /// resets it, and it suspends while an elicitation is pending. Expiry
    /// cancels the work and settles the run as
    /// ``OperationOutcome/timedOut``.
    public var timeout: TimeInterval

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - mode: Whether a call detaches at `waitSeconds` or runs to
    ///     completion.
    ///   - waitSeconds: How long one call may block before detaching.
    ///     Defaults to ``defaultWaitSeconds``.
    ///   - timeout: How long the work itself may run. Defaults to
    ///     ``defaultTimeoutSeconds``.
    public init(
        mode: Mode,
        waitSeconds: TimeInterval = Self.defaultWaitSeconds,
        timeout: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.mode = mode
        self.waitSeconds = waitSeconds
        self.timeout = timeout
    }
}

/// The failures the ``DetachingTool`` engine itself produces.
public enum DetachingToolError: Error, Equatable {
    /// The per-call `timeout` elapsed with no progress and no pending
    /// elicitation; the work was cancelled and the run settled as
    /// ``OperationOutcome/timedOut``.
    case timedOut(tool: String, timeoutSeconds: TimeInterval)
}

/// The rendered output a detached call returns in place of its result: the
/// `pending` discriminator, the parked run's `completionToken`, and a `next`
/// field spelling out the collect step the model must take instead of
/// answering.
///
/// The `completionToken` is the parked run's key in the session's
/// ``SessionMailbox`` and the `correlationID` on every event the run posts —
/// one string, two planes.
///
/// The `next` instruction is not decoration (task ^ywc0q4f). This envelope is
/// the whole message a model receives when its long tool call parks, so a
/// bare token leaves it holding a key it has no reason to understand while
/// the user waits for an answer — the measured failure was a model inventing
/// the result outright. Every other in-band text this package hands a model
/// is phrased as repair instructions; so is this one. It is derived entirely
/// from ``completionToken``, so it is regenerated rather than carried as a
/// stored property: ``rendered``, not the synthesized `Codable` conformance,
/// is the authoritative wire form.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// Always `true` — the discriminator a reader branches on.
    public let pending: Bool

    /// The parked run's completion token: a ULID string that is also the
    /// run's event `correlationID`.
    public let completionToken: String

    /// Creates the envelope for a run parked under `completionToken`.
    public init(completionToken: String) {
        self.pending = true
        self.completionToken = completionToken
    }

    /// The `seconds` argument of the follow-up `wait` the ``rendered``
    /// instruction tells the model to make: long enough that most parked runs
    /// settle inside that single collect step, short enough that a stalled one
    /// still hands control back rather than blocking the turn.
    private static let followUpWaitSeconds = 60

    /// The run-plane state name a `wait` reports for a run that finished — the
    /// wire spelling of ``SessionMailbox/WaitResult/settled``, whose event
    /// carries the run's output in its `detail`.
    private static let settledStateName = "settled"

    /// The run-plane state name a `wait` reports when its own deadline ran out
    /// with the run still parked — the wire spelling of
    /// ``SessionMailbox/WaitResult/deadlineElapsed``.
    private static let deadlineElapsedStateName = "deadline_elapsed"

    /// The fixed text before the first `completionToken` slot in
    /// ``rendered``'s wire form.
    private static let renderedPrefix = "{\"pending\":true,\"completionToken\":\""

    /// The fixed text between ``rendered``'s two `completionToken` slots: the
    /// opening of the `next` instruction, ending inside the quoted token
    /// argument of the follow-up snippet it hands the model.
    private static let renderedMidfix =
        "\",\"next\":\"This run is still going. Do not answer yet, "
        + "and never invent or guess its result. "
        + "Call this tool again with a snippet that does: return await wait(\\\""

    /// The fixed text after ``rendered``'s second `completionToken` slot: the
    /// rest of the follow-up snippet, then how to read each state it can
    /// report back.
    private static let renderedSuffix =
        "\\\", \(followUpWaitSeconds)). "
        + "When the returned state is \\\"\(settledStateName)\\\", "
        + "the result is in its detail field. "
        + "When it is \\\"\(deadlineElapsedStateName)\\\", the run is still going: "
        + "call wait again with the same completionToken.\"}"

    /// ``rendered``'s exact length: the three fixed frame parts around two
    /// ``ULID/stringLength``-character token slots.
    private static let renderedLength =
        renderedPrefix.count + ULID.stringLength + renderedMidfix.count + ULID.stringLength
        + renderedSuffix.count

    /// Renders the wire form of an envelope for `completionToken`.
    ///
    /// The one definition both ``rendered`` and ``isRendered(_:)`` go through,
    /// so recognition can never drift from rendering. Built literally — a
    /// completion token is a 26-character Crockford base32 ULID, so no
    /// escaping can ever be needed — keeping the rendering total and
    /// deterministic.
    ///
    /// - Parameter completionToken: The parked run's completion token, spliced
    ///   into both of the wire form's token slots.
    /// - Returns: The envelope's JSON wire form.
    private static func rendered(forCompletionToken completionToken: String) -> String {
        renderedPrefix + completionToken + renderedMidfix + completionToken + renderedSuffix
    }

    /// The envelope rendered as its JSON wire form.
    public var rendered: String {
        Self.rendered(forCompletionToken: completionToken)
    }

    /// Whether `text` is exactly a rendered pending envelope: the fixed
    /// ``rendered`` frame around two slots holding one and the same valid ULID
    /// `completionToken`.
    ///
    /// This is what lets a decorator outside the detachment layer — today
    /// ``TokenCappingTool`` — recognize control-plane wire data and pass it
    /// through untouched, without JSON-parsing arbitrary tool output: the
    /// wire form is deterministic, so a byte-shape check is exact. Recognition
    /// is defined as re-rendering: the token is read out of the first slot,
    /// and `text` must equal what this envelope renders for exactly that
    /// token, so a twin-slot mismatch, an edited instruction, and any length
    /// change are all rejections by construction.
    ///
    /// - Parameter text: The rendered tool output to test.
    /// - Returns: `true` iff `text` is a rendered pending envelope.
    public static func isRendered(_ text: String) -> Bool {
        guard text.count == renderedLength, text.hasPrefix(renderedPrefix) else {
            return false
        }
        let completionToken = String(
            text.dropFirst(renderedPrefix.count).prefix(ULID.stringLength)
        )
        guard ULID(completionToken) != nil else {
            return false
        }
        return text == rendered(forCompletionToken: completionToken)
    }
}

/// The detachment engine: a decorator over `any Tool` that races each call
/// against the soft `waitSeconds` deadline and parks a call that outlives it
/// in the session's ``SessionMailbox`` (eventplan.md § "Elevation:
/// waitSeconds and the completion token" — that plan's name for
/// detachment).
///
/// Follows ``TokenCappingTool``'s forwarding precedent — `name`,
/// `description`, `parameters`, and `includesSchemaInInstructions` pass
/// through untouched; only `call(arguments:)` is decorated — and its
/// `Output` is the rendered value, so a typed wrapped `Output` never has to
/// represent the pending case: the model reads text on the wire either way.
///
/// Per call, the engine:
/// 1. Mints a `completionToken` (a ULID; it IS the run's event
///    `correlationID`) and binds a ``ToolContext`` around the inner call.
/// 2. In ``DetachConfiguration/Mode/detaching``, races the call against
///    `waitSeconds` using a continuation-based race (never a task group — a
///    group cannot exit with a suspended child). In-window completion
///    returns the rendered output inline; nothing resets `waitSeconds`.
/// 3. On window elapse, parks the still-running call in the mailbox (kind
///    ``SessionMailbox/RunKind/swiftTask``, cooperative canceler), posts
///    one synthesized `progress` event iff the run has posted no events of
///    its own yet, and returns ``PendingRunEnvelope/rendered``.
/// 4. Enforces terminal-scoped synthesis at a single posting funnel:
///    exactly one `.completed` per detached run in every path — inline,
///    detached, tool-throws, cancel, timeout — with the rendered output in
///    `detail`, the `completionToken` as `correlationID`, and the honest
///    ``OperationOutcome``. A run that posted its own terminal gets no
///    duplicate; a run that settles entirely in-band, silently and
///    successfully, posts nothing at all. Terminal events always go
///    upstream, even when a `wait()` already collected the result — the
///    journal must stay complete.
/// 5. Bounds the work with the per-call `timeout`, which progress resets
///    and a pending elicitation suspends (the ported `CallDeadline` loop).
///    In ``DetachConfiguration/Mode/runToCompletion`` the call runs to
///    completion bounded only by that timeout — same engine, detachment off.
///
/// `Arguments` must be `Sendable` — beyond `Tool`'s own
/// `ConvertibleFromGeneratedContent` bound — because detachment is exactly
/// the act of moving a call across tasks: the arguments are handed to the
/// detached run body that may outlive the call that received them.
public struct DetachingTool<Arguments: ConvertibleFromGeneratedContent & Sendable>: Tool {
    /// The wrapped tool, called through untouched save for detachment.
    /// Internal rather than private, mirroring ``TokenCappingTool``'s own
    /// `wrapped`, so composition-site wiring tests can assert the per-site
    /// decorator chain order.
    let wrapped: any Tool<Arguments, String>

    /// The owning session's identity, stamped into each run's
    /// ``ToolContext``.
    private let sessionID: ULID

    /// The owning session's mailbox — where detached runs park.
    private let mailbox: SessionMailbox

    /// The upstream sink every run's events funnel into.
    private let sink: any OperationEventSink

    /// The wrap-time mode and clock defaults; per-call values from
    /// ``DetachmentParameterProviding`` override the clocks.
    private let configuration: DetachConfiguration

    /// The wrapped tool's name.
    public var name: String { wrapped.name }

    /// The wrapped tool's description.
    public var description: String { wrapped.description }

    /// The wrapped tool's parameter schema.
    public var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the schema is included in the tool's instructions.
    public var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped` in the detachment engine.
    ///
    /// - Parameters:
    ///   - wrapped: The tool to decorate.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink the run's events are posted to.
    ///   - configuration: The wrap-time mode and clock defaults.
    public init(
        wrapping wrapped: any Tool<Arguments, String>,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        configuration: DetachConfiguration
    ) {
        self.wrapped = wrapped
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
        self.configuration = configuration
    }

    /// Runs one call through the engine — see the type doc for the full
    /// behavior.
    ///
    /// - Parameter arguments: The call's arguments, forwarded to the
    ///   wrapped tool untouched.
    /// - Returns: The wrapped tool's rendered output when the call settles
    ///   in-band, or ``PendingRunEnvelope/rendered`` when it detaches.
    /// - Throws: Whatever the wrapped tool throws, unmodified, when the
    ///   call settles in-band with an error;
    ///   ``DetachingToolError/timedOut(tool:timeoutSeconds:)`` when the
    ///   per-call timeout ends an in-band call.
    public func call(arguments: Arguments) async throws -> String {
        let clocks = perCallClocks(from: arguments)
        let waitSeconds = clocks.waitSeconds ?? configuration.waitSeconds
        let timeoutSeconds = clocks.timeout ?? configuration.timeout

        let completionToken = SessionMailbox.makeCompletionToken()
        let cancellationFlag = CancellationRequestFlag()
        let funnel = RunEventFunnel(
            upstream: sink, mailbox: mailbox, completionToken: completionToken
        )
        let context = ToolContext(
            stamping: wrapped,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: funnel,
            completionToken: completionToken,
            isCancelled: { cancellationFlag.isRequested }
        )

        let wrapped = self.wrapped
        let workTask = Task { () async -> RunSettlement in
            await ToolContext.$current.withValue(context) {
                await Self.settle(
                    calling: wrapped,
                    arguments: arguments,
                    context: context,
                    funnel: funnel,
                    timeoutSeconds: timeoutSeconds,
                    cancellationFlag: cancellationFlag
                )
            }
        }

        switch configuration.mode {
        case .runToCompletion:
            return try await withTaskCancellationHandler {
                let settlement = await workTask.value
                return try settlement.result.get()
            } onCancel: {
                cancellationFlag.request()
                workTask.cancel()
            }
        case .detaching:
            let deadline = SessionMailbox.boundedNanoseconds(clamping: waitSeconds)
            guard deadline > 0 else {
                return try await detach(
                    workTask: workTask, funnel: funnel, context: context,
                    cancellationFlag: cancellationFlag
                )
            }
            switch await Self.raceSettlement(of: workTask, deadlineNanoseconds: deadline) {
            case .settled(let settlement):
                return try settlement.result.get()
            case .deadlineElapsed:
                return try await detach(
                    workTask: workTask, funnel: funnel, context: context,
                    cancellationFlag: cancellationFlag
                )
            }
        }
    }

    // MARK: - Per-call clocks

    /// The per-call clocks the wrapped tool supplies through
    /// ``DetachmentParameterProviding``, or all-`nil` when it does not
    /// conform (or its arguments cannot round-trip to `GeneratedContent`).
    private func perCallClocks(
        from arguments: Arguments
    ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
        guard
            let provider = wrapped as? any DetachmentParameterProviding,
            let convertible = arguments as? any ConvertibleToGeneratedContent
        else {
            return (nil, nil)
        }
        return provider.detachmentClocks(from: convertible.generatedContent)
    }

    // MARK: - Detachment

    /// Detaches a call whose window elapsed: parks the still-running work
    /// in the mailbox, posts the synthesized progress iff the run has been
    /// silent, and returns the pending envelope. When the run settled in
    /// the instants between the window elapsing and detachment, returns its
    /// in-band result instead — a settled run is never parked.
    private func detach(
        workTask: Task<RunSettlement, Never>,
        funnel: RunEventFunnel,
        context: ToolContext,
        cancellationFlag: CancellationRequestFlag
    ) async throws -> String {
        let envelope = PendingRunEnvelope(completionToken: context.completionToken)
        let synthesizedProgress = OperationEvent(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            kind: .progress,
            detail: envelope.rendered
        )
        guard await funnel.markDetached(postingIfSilent: synthesizedProgress) else {
            return try await workTask.value.result.get()
        }
        let settling = Task { await workTask.value.terminal }
        await mailbox.park(
            tool: context.tool,
            op: context.op,
            kind: .swiftTask,
            completionToken: context.completionToken,
            settling: settling,
            canceler: {
                // A swiftTask run's cancellation is cooperative: request it
                // and report exactly that, never certainty.
                cancellationFlag.request()
                workTask.cancel()
                return .cancelled
            }
        )
        return envelope.rendered
    }

    // MARK: - Settlement

    /// The one run body: calls the wrapped tool raced against its
    /// resettable timeout, funnels the terminal synthesis, and returns both
    /// the in-band result and the terminal event.
    private static func settle(
        calling wrapped: any Tool<Arguments, String>,
        arguments: Arguments,
        context: ToolContext,
        funnel: RunEventFunnel,
        timeoutSeconds: TimeInterval,
        cancellationFlag: CancellationRequestFlag
    ) async -> RunSettlement {
        // Created inside the ToolContext binding, so the inner call — and
        // any unstructured work it starts — inherits the ambient context.
        let inner = Task { try await wrapped.call(arguments: arguments) }
        let result = await withTaskCancellationHandler {
            await raceInnerAgainstTimeout(
                inner: inner,
                timeoutSeconds: timeoutSeconds,
                funnel: funnel,
                cancellationFlag: cancellationFlag,
                tool: context.tool
            )
        } onCancel: {
            cancellationFlag.request()
            inner.cancel()
        }
        let facts = terminalFacts(for: result)
        let terminal = OperationEvent(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            kind: .completed,
            detail: facts.detail,
            outcome: facts.outcome
        )
        await funnel.settleRun(with: terminal)
        return RunSettlement(result: result, terminal: terminal)
    }

    /// Races the inner call against the resettable per-call timeout — the
    /// ported `CallDeadline` loop — through the same continuation-based
    /// race the soft deadline uses. Timeout expiry cancels the inner call
    /// and resolves as ``DetachingToolError/timedOut(tool:timeoutSeconds:)``.
    private static func raceInnerAgainstTimeout(
        inner: Task<String, any Error>,
        timeoutSeconds: TimeInterval,
        funnel: RunEventFunnel,
        cancellationFlag: CancellationRequestFlag,
        tool: String
    ) async -> Result<String, any Error> {
        let gate = RaceGate<TimeoutRaceOutcome>()
        Task {
            gate.resume(with: .finished(await inner.result))
        }
        let watcher = Task {
            if await watchForTimeout(funnel: funnel, timeoutSeconds: timeoutSeconds) {
                gate.resume(with: .timedOut)
            }
        }
        let outcome = await withCheckedContinuation { gate.register(continuation: $0) }
        watcher.cancel()
        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            cancellationFlag.request()
            inner.cancel()
            return .failure(
                DetachingToolError.timedOut(tool: tool, timeoutSeconds: timeoutSeconds)
            )
        }
    }

    /// Sleeps in full-`timeout` increments until one whole window elapses
    /// with no deadline reset and no pending elicitation — the ported
    /// `CallDeadline.resetForProgress` comparison loop.
    ///
    /// - Returns: `true` when the call genuinely timed out; `false` when
    ///   the watcher was cancelled because the race already resolved.
    private static func watchForTimeout(
        funnel: RunEventFunnel, timeoutSeconds: TimeInterval
    ) async -> Bool {
        let window = SessionMailbox.boundedNanoseconds(clamping: timeoutSeconds)
        while true {
            let before = await funnel.timeoutCheckpoint()
            do {
                try await Task.sleep(nanoseconds: window)
            } catch {
                return false
            }
            let after = await funnel.timeoutCheckpoint()
            // A window that saw progress — or that ended (or ran) with an
            // elicitation pending — proves the call alive: sleep another
            // full window. An elicitation's resolution bumps the reset
            // count (see `timeoutCheckpoint()`), so a call that stalls
            // again after answering still times out on this same loop.
            guard after.resetCount == before.resetCount, !after.isElicitationPending else {
                continue
            }
            return true
        }
    }

    /// Maps an in-band result to its terminal event's outcome and detail:
    /// output for success; the honest ``OperationOutcome`` and the error's
    /// description otherwise.
    private static func terminalFacts(
        for result: Result<String, any Error>
    ) -> (outcome: OperationOutcome, detail: String) {
        switch result {
        case .success(let output):
            return (.succeeded, output)
        case .failure(let error):
            if error is CancellationError {
                return (.cancelled, String(describing: error))
            }
            if case DetachingToolError.timedOut = error {
                return (.timedOut, String(describing: error))
            }
            return (.failed, String(describing: error))
        }
    }

    // MARK: - The soft-deadline race

    /// Races a run's settlement against the soft `waitSeconds` deadline —
    /// a continuation-based race, deliberately not a task group: a group
    /// implicitly awaits every child before returning, so one awaiting the
    /// settlement task could never be abandoned and nothing would bound the
    /// wait at all (the ported `raceThroughGate` shape).
    ///
    /// Ambient cancellation of the calling task folds into
    /// ``WaitRaceOutcome/deadlineElapsed`` — a caller who asked for a
    /// bounded wait already accepted that the work may outlive the call,
    /// so cancelling that wait detaches exactly as the deadline elapsing
    /// early would.
    private static func raceSettlement(
        of settling: Task<RunSettlement, Never>, deadlineNanoseconds: UInt64
    ) async -> WaitRaceOutcome {
        let gate = RaceGate<WaitRaceOutcome>()
        Task {
            gate.resume(with: .settled(await settling.value))
        }
        let deadlineTask = Task {
            do {
                try await Task.sleep(nanoseconds: deadlineNanoseconds)
            } catch {
                return
            }
            gate.resume(with: .deadlineElapsed)
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { gate.register(continuation: $0) }
        } onCancel: {
            gate.resume(with: .deadlineElapsed)
        }
        deadlineTask.cancel()
        return outcome
    }

}

/// The untyped entry point over the ``DetachingTool`` decorator — the
/// discovery half of the pair, mirroring `ToolOutputCapping`'s
/// `wrapping(tool:toTokenLimit:)`: Router's tool-instancing seams hold plain
/// `[any Tool]` lists, so this is where the existential is opened and the
/// decorator applied.
///
/// The shared per-tool session-mount composition,
/// ``sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)``,
/// extends this namespace from `Session/ToolOutputCapping.swift` — it
/// layers `ToolOutputCapping` over ``wrapping(_:sessionID:mailbox:sink:configuration:)``,
/// and lives beside the capping layer so this file carries no dependency
/// on it.
public enum ToolDetachment {
    /// Wraps `tool` in a ``DetachingTool`` when it can be detached,
    /// discovered dynamically rather than requiring the tool to opt in —
    /// and in the binding-only ``ContextBindingTool`` otherwise, so every
    /// tool leaves here with a per-call, per-tool-stamped ambient
    /// ``ToolContext`` (task ^6htgvw2).
    ///
    /// Detachment requires the wrapped tool's `Output` to be `String` —
    /// checked with a runtime existential cast against `Tool`'s primary
    /// associated types — because the pending envelope replaces the
    /// rendered output on the same wire, and `FoundationModels.Prompt`
    /// exposes no generic way to substitute text into any other `Output`
    /// (the exact reasoning behind `ToolOutputCapping.wrapping`'s identical
    /// restriction). A tool with any other `Output` gets the
    /// ``ContextBindingTool`` decorator instead: it runs un-detached,
    /// in-band, exactly as it does today — never detachable — but its
    /// ambient posts still carry its own tool identity and a fresh
    /// per-call `correlationID` rather than falling back to the session's
    /// turn-scope binding.
    ///
    /// ``DetachingTool``'s other bound — `Arguments: Sendable` — needs no
    /// check here: `Tool`'s own `@concurrent call(arguments:)` requirement
    /// already makes a conformance with non-`Sendable` `Arguments`
    /// uncompilable, so every tool this can receive satisfies it.
    ///
    /// - Parameters:
    ///   - tool: The tool to consider for detachment.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink the run's events are posted to.
    ///   - configuration: The wrap-time mode and clock defaults.
    /// - Returns: The detaching decorator around `tool` when it qualifies;
    ///   the binding-only ``ContextBindingTool`` around it otherwise.
    public static func wrapping(
        _ tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        configuration: DetachConfiguration
    ) -> any Tool {
        func openArguments<A: ConvertibleFromGeneratedContent & Sendable>(
            _ argumentsType: A.Type, of candidate: any Tool
        ) -> any Tool {
            guard let typed = candidate as? any Tool<A, String> else { return candidate }
            return DetachingTool(
                wrapping: typed,
                sessionID: sessionID,
                mailbox: mailbox,
                sink: sink,
                configuration: configuration
            )
        }
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard tool is any Tool<T.Arguments, String> else {
                return ContextBindingTool<T.Arguments, T.Output>(
                    wrapping: tool,
                    sessionID: sessionID,
                    mailbox: mailbox,
                    sink: sink
                )
            }
            // A type-system bridge, not a runtime filter: `Sendable` is a
            // marker protocol with no runtime representation, and `Tool`
            // conformance already guarantees it (see the doc above) — this
            // cast only restates that fact where the generic system can see
            // it, so `DetachingTool`'s `Arguments: Sendable` bound is
            // satisfied. Routed through `Any` because the compiler can
            // neither prove the coercion statically nor represent a failing
            // path; the fallback is unreachable and kept only for totality.
            let erasedArguments: Any = T.Arguments.self
            guard
                let argumentsType =
                    erasedArguments as? any (ConvertibleFromGeneratedContent & Sendable).Type
            else {
                return tool
            }
            return openArguments(argumentsType, of: tool)
        }
        return open(tool)
    }
}

/// The binding-only decorator over a non-`String`-output tool: binds a
/// per-call, per-tool-stamped ``ToolContext`` around the wrapped call —
/// exactly the ambient identity ``DetachingTool`` binds — while skipping the
/// pending-envelope/park machinery entirely, because that machinery requires
/// a `String` wire form the pending envelope can replace and this tool's
/// `Output` has none (task ^6htgvw2).
///
/// Follows ``TokenCappingTool``'s forwarding precedent — `name`,
/// `description`, `parameters`, and `includesSchemaInInstructions` pass
/// through untouched — and returns the wrapped tool's own `Output`
/// unchanged: the call always runs in-band, in the calling task, bounded by
/// nothing this decorator adds.
///
/// Per call, the decorator mints a fresh `completionToken` (run scope,
/// never session scope), stamps ``ToolContext/tool``/``ToolContext/op``
/// with the wrapped tool's `name` (the phase-1 stamping rule — see
/// ``ToolContext/init(stamping:sessionID:mailbox:sink:completionToken:isCancelled:)``),
/// and posts the tool's own ambient events straight to the session's sink.
/// It synthesizes nothing: no progress, no terminal — a silent run posts no
/// events at all, and the calling task's cancellation is mirrored into the
/// context's honest ``ToolContext/isCancelled`` probe.
public struct ContextBindingTool<
    Arguments: ConvertibleFromGeneratedContent, Output: PromptRepresentable
>: Tool {
    /// The wrapped tool, called through untouched save for the ambient
    /// binding. Internal rather than private, mirroring ``DetachingTool``'s
    /// own `wrapped`, so composition-site wiring tests can assert the
    /// per-site decorator chain.
    let wrapped: any Tool<Arguments, Output>

    /// The owning session's identity, stamped into each call's
    /// ``ToolContext``.
    private let sessionID: ULID

    /// The owning session's mailbox, carried by the bound context for
    /// ``ToolContext/elicit(_:)``.
    private let mailbox: SessionMailbox

    /// The upstream sink the bound context posts the tool's events to.
    private let sink: any OperationEventSink

    /// The wrapped tool's name.
    public var name: String { wrapped.name }

    /// The wrapped tool's description.
    public var description: String { wrapped.description }

    /// The wrapped tool's parameter schema.
    public var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the schema is included in the tool's instructions.
    public var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped` in the binding-only decorator.
    ///
    /// - Parameters:
    ///   - wrapped: The tool to decorate.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink the bound context posts events to.
    public init(
        wrapping wrapped: any Tool<Arguments, Output>,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink
    ) {
        self.wrapped = wrapped
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
    }

    /// Runs one call under a fresh per-call ``ToolContext`` binding — see
    /// the type doc for the full behavior.
    ///
    /// - Parameter arguments: The call's arguments, forwarded to the
    ///   wrapped tool untouched.
    /// - Returns: The wrapped tool's own output, unchanged.
    /// - Throws: Whatever the wrapped tool throws, unmodified.
    public func call(arguments: Arguments) async throws -> Output {
        let cancellationFlag = CancellationRequestFlag()
        let context = ToolContext(
            stamping: wrapped,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { cancellationFlag.isRequested }
        )
        return try await withTaskCancellationHandler {
            try await ToolContext.$current.withValue(context) {
                try await wrapped.call(arguments: arguments)
            }
        } onCancel: {
            cancellationFlag.request()
        }
    }
}

// MARK: - Run bookkeeping

/// How one run's body ended: the in-band result the inline path returns (or
/// rethrows) and the terminal event the run plane records.
private struct RunSettlement: Sendable {
    /// The wrapped tool's output, or the error that ended the call.
    let result: Result<String, any Error>

    /// The run's terminal event — already funneled upstream per the
    /// terminal-scoped synthesis rules; also what the mailbox retains for
    /// late `wait()` calls.
    let terminal: OperationEvent
}

/// Whichever of a run's settlement or its soft `waitSeconds` deadline
/// arrives first. Only two cases: ambient cancellation of the bounded wait
/// folds into ``deadlineElapsed`` (see
/// `DetachingTool.raceSettlement(of:deadlineNanoseconds:)`).
private enum WaitRaceOutcome: Sendable {
    /// The run settled in the window; return its in-band result.
    case settled(RunSettlement)

    /// The window elapsed first; detach the still-running call.
    case deadlineElapsed
}

/// Whichever of the inner call's completion or its resettable per-call
/// timeout arrives first.
private enum TimeoutRaceOutcome: Sendable {
    /// The inner call finished with this result.
    case finished(Result<String, any Error>)

    /// A full timeout window elapsed with no progress and no pending
    /// elicitation.
    case timedOut
}

/// A sticky request-for-cancellation flag — the honest probe behind a run's
/// ``ToolContext/isCancelled``: set when the mailbox canceler, the timeout,
/// or the calling task's own cancellation requests the run stop, and never
/// cleared (cancellation is a one-way request).
private final class CancellationRequestFlag: Sendable {
    /// Whether cancellation has been requested.
    private let requested = Mutex(false)

    /// Records the request.
    func request() {
        requested.withLock { $0 = true }
    }

    /// Whether cancellation has been requested.
    var isRequested: Bool {
        requested.withLock { $0 }
    }
}

/// A resume-exactly-once rendezvous for a race whose competitors — and the
/// racer's own cancellation — can arrive in any order, including before the
/// continuation racing them exists (the ported `CancellationGate`).
///
/// Whichever of ``register(continuation:)``'s continuation or the first
/// ``resume(with:)`` happens first, the other's eventual call is what
/// actually resumes the continuation; every later resume is a no-op.
private final class RaceGate<Value: Sendable>: Sendable {
    /// This gate's state machine.
    private enum State {
        /// Neither ``register(continuation:)`` nor ``resume(with:)`` has run yet.
        case awaitingContinuation

        /// ``register(continuation:)`` ran first; this is the continuation it
        /// recorded.
        case continuationRegistered(CheckedContinuation<Value, Never>)

        /// ``resume(with:)`` ran first, before any continuation existed;
        /// this is the value the eventual registration resumes with.
        case resolvedBeforeContinuation(Value)

        /// The continuation has been resumed; every further call is a
        /// no-op.
        case resumed
    }

    /// The gate's state, guarded for the racing callers.
    private let state = Mutex<State>(.awaitingContinuation)

    /// Registers the continuation to resume, resuming it immediately when a
    /// competitor already resolved the race.
    ///
    /// - Parameter continuation: The continuation to resume exactly once.
    func register(continuation: CheckedContinuation<Value, Never>) {
        let immediateValue: Value? = state.withLock { current in
            switch current {
            case .awaitingContinuation:
                current = .continuationRegistered(continuation)
                return nil
            case .resolvedBeforeContinuation(let value):
                current = .resumed
                return value
            case .continuationRegistered, .resumed:
                return nil
            }
        }
        if let immediateValue {
            continuation.resume(returning: immediateValue)
        }
    }

    /// Resolves the race with `value`: resumes the registered continuation,
    /// records the value for a registration still to come, or no-ops when
    /// the race is already resolved.
    ///
    /// - Parameter value: The competitor's value.
    func resume(with value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = state.withLock { current in
            switch current {
            case .awaitingContinuation:
                current = .resolvedBeforeContinuation(value)
                return nil
            case .continuationRegistered(let registered):
                current = .resumed
                return registered
            case .resolvedBeforeContinuation, .resumed:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}

/// One run's single posting funnel: every event the run produces — the
/// tool's own posts through its ``ToolContext``, the synthesized progress
/// at detachment, and the terminal synthesis at settlement — passes through
/// here, which is what makes "exactly one `.completed` per run" enforceable
/// at all (precedent: `MCPServer.postOperationCompletedEvent`).
///
/// Also the per-run deadline state the ported `CallDeadline` loop compares:
/// progress bumps the reset count, and a posted elicitation suspends the
/// timeout until the mailbox no longer holds it pending (its resolution
/// bumps the reset count exactly as `endElicitation()` would).
///
/// Upstream deliveries are FIFO-chained, so an engine post can never
/// overtake a tool post — the synthesized progress at detachment always
/// lands upstream before the run's terminal.
private actor RunEventFunnel: OperationEventSink {
    /// Where the run is in its detachment lifecycle.
    private enum Phase {
        /// The call is running in-band.
        case running

        /// The window elapsed and the run was parked.
        case detached

        /// The run's body ended; the terminal decision has been made.
        case settled
    }

    /// One timeout-loop observation: the deadline reset count and whether
    /// an elicitation is currently pending.
    struct TimeoutCheckpoint: Sendable, Equatable {
        /// Bumped by every progress event and every elicitation
        /// resolution.
        let resetCount: Int

        /// Whether any elicitation this run posted is still pending in the
        /// mailbox.
        let isElicitationPending: Bool
    }

    /// The sink every delivery forwards to.
    private let upstream: any OperationEventSink

    /// The session's mailbox: progress feeds its run-plane snapshot, and
    /// pending elicitations are reconciled against it.
    private let mailbox: SessionMailbox

    /// The run's completion token — the key progress updates address.
    private let completionToken: String

    /// Where the run is in its detachment lifecycle.
    private var phase: Phase = .running

    /// Whether any event has been delivered upstream for this run.
    private var hasDeliveredAnyEvent = false

    /// Whether a terminal event has been delivered upstream for this run.
    private var hasDeliveredTerminal = false

    /// The ported `CallDeadline.resetCount`: bumped by progress and by
    /// elicitation resolutions, compared by the timeout loop around each
    /// full-window sleep.
    private var deadlineResetCount = 0

    /// The elicitation ids this run has posted that were pending at last
    /// reconciliation.
    private var trackedElicitationIds: Set<ULID> = []

    /// The FIFO chain every upstream delivery is enqueued onto.
    private var deliveryChain = SerialAsyncChain()

    /// Creates the funnel for one run.
    ///
    /// - Parameters:
    ///   - upstream: The sink every delivery forwards to.
    ///   - mailbox: The session's mailbox.
    ///   - completionToken: The run's completion token.
    init(upstream: any OperationEventSink, mailbox: SessionMailbox, completionToken: String) {
        self.upstream = upstream
        self.mailbox = mailbox
        self.completionToken = completionToken
    }

    /// Receives one of the tool's own posts: records what the deadline and
    /// synthesis decisions need, then forwards it upstream — except a
    /// second terminal for the run, which is dropped (exactly one
    /// `.completed` per run is enforced here).
    func post(_ event: OperationEvent) async {
        switch event.kind {
        case .completed:
            guard !hasDeliveredTerminal else { return }
            hasDeliveredTerminal = true
        case .progress:
            deadlineResetCount += 1
        case .elicitation:
            if let elicitationId = event.elicitation?.elicitationId {
                trackedElicitationIds.insert(elicitationId)
            }
        }
        hasDeliveredAnyEvent = true
        let delivery = enqueueUpstream(event: event)
        if event.kind == .progress {
            await mailbox.updateProgress(completionToken: completionToken, detail: event.detail)
        }
        await delivery.value
    }

    /// Marks the run detached and, iff it has posted nothing yet, delivers
    /// the one synthesized progress event.
    ///
    /// - Parameter progress: The synthesized progress to deliver when the
    ///   run has been silent.
    /// - Returns: `true` when the run is (now) detached; `false` when it
    ///   already settled — the caller returns the in-band result instead
    ///   of parking a finished run.
    func markDetached(postingIfSilent progress: OperationEvent) async -> Bool {
        guard case .running = phase else {
            return false
        }
        phase = .detached
        guard !hasDeliveredAnyEvent else {
            return true
        }
        hasDeliveredAnyEvent = true
        await enqueueUpstream(event: progress).value
        return true
    }

    /// Records the run's settlement and applies the terminal-scoped
    /// synthesis rule: deliver `terminal` upstream iff no terminal has
    /// passed yet **and** the run either detached, posted any event of its
    /// own, or ended abnormally. A silent, successful, in-band run posts
    /// nothing at all — the `OperationEventKind` contract's "may post
    /// nothing" case.
    ///
    /// - Parameter terminal: The engine's synthesized terminal event.
    func settleRun(with terminal: OperationEvent) async {
        let wasDetached: Bool =
            if case .detached = phase { true } else { false }
        phase = .settled
        let mustDeliver =
            !hasDeliveredTerminal
            && (wasDetached || hasDeliveredAnyEvent || terminal.outcome != .succeeded)
        guard mustDeliver else {
            return
        }
        hasDeliveredTerminal = true
        hasDeliveredAnyEvent = true
        await enqueueUpstream(event: terminal).value
    }

    /// One timeout-loop observation, reconciling tracked elicitations
    /// against the mailbox first: an elicitation that resolved since the
    /// last look bumps the reset count — `endElicitation()` semantics, so
    /// however long the question took is never counted as silent stall.
    func timeoutCheckpoint() async -> TimeoutCheckpoint {
        let tracked = trackedElicitationIds
        if !tracked.isEmpty {
            let stillPending = Set(await mailbox.pendingElicitationIds())
            let resolved = tracked.subtracting(stillPending)
            if !resolved.isEmpty {
                deadlineResetCount += 1
                trackedElicitationIds.subtract(resolved)
            }
        }
        return TimeoutCheckpoint(
            resetCount: deadlineResetCount,
            isElicitationPending: !trackedElicitationIds.isEmpty
        )
    }

    /// Chains one upstream delivery onto ``deliveryChain`` and returns it for
    /// the caller to await, so a run's own events reach the sink in the order
    /// the run posted them.
    private func enqueueUpstream(event: OperationEvent) -> Task<Void, Never> {
        let upstream = self.upstream
        return deliveryChain.enqueue { await upstream.post(event) }
    }
}
