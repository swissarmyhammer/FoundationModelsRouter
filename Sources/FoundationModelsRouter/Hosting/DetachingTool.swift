import Foundation
import FoundationModels
import Synchronization

/// Declares a wrapped tool's own detachment parameters.
///
/// The hook a tool states its own detachment behaviour through. A tool that
/// conforms makes up to three declarations, and the ``DetachingTool`` engine
/// reads each of them over the wrap-time ``DetachConfiguration`` its
/// composition site applies:
///
/// - ``detachmentMount`` states the whole mount the tool needs, for every
///   call it takes.
/// - ``detachmentClocks(from:)`` reads a `waitSeconds` and/or a `timeout`
///   out of one call's `GeneratedContent` — however the tool encodes them.
/// - ``detachmentCollectInstruction(forCompletionToken:)`` states the `next`
///   sentence of the pending envelope a parked call hands the model: the
///   collect step the tool's own host offers.
///
/// Each declaration has a default, so a tool states only the part it needs,
/// and a tool that does not conform at all keeps the configuration its
/// composition site gave it and the default collect sentence.
public protocol DetachmentParameterProviding {
    /// The mount this tool needs whatever mount its composition site
    /// applies, or `nil` to take that site's own.
    ///
    /// The mode belongs to the tool, not to the session, because one session
    /// vends tools that no single policy fits. A discovery tool must block
    /// until it holds the catalogue: a model handed a pending envelope for
    /// discovery stops discovering and starts collecting, so it never learns
    /// what it may call, and it answers that it has no access at all. A tool
    /// that runs a long snippet beside it must still park, because a turn
    /// cannot wait for that snippet. The first declares
    /// ``DetachConfiguration/runToCompletionMount`` here, the second
    /// declares nothing, and one session mounts both.
    ///
    /// A declaration wins over the configuration the composition site
    /// passes, clock and all: a tool states a mount only for behaviour it
    /// cannot work without, so a site that overrode it would hand the tool
    /// behaviour its author refused. Only ``detachmentClocks(from:)``
    /// narrows a declared mount further, being the statement about one call
    /// rather than about every call.
    ///
    /// Detachment reaches a tool whose `Output` is `String` alone, so this
    /// declaration reaches no other tool either — see
    /// ``ToolDetachment/wrapping(tool:sessionID:mailbox:sink:configuration:)``.
    var detachmentMount: DetachConfiguration? { get }

    /// Returns the per-call clocks encoded in `arguments`, or `nil` fields
    /// for whichever the call does not supply.
    ///
    /// - Parameter arguments: The call's arguments as opaque
    ///   `GeneratedContent` — the same content the tool's typed `Arguments`
    ///   were decoded from.
    /// - Returns: The per-call `waitSeconds` and `timeout`, each `nil` to
    ///   fall back to the mount the call resolved to.
    func detachmentClocks(
        from arguments: GeneratedContent
    ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?)

    /// Returns the `next` sentence of the pending envelope a parked call of
    /// this tool hands the model: the in-band collect step for
    /// `completionToken`.
    ///
    /// The tool that owns the collect verb owns this sentence (task
    /// ^rx6f25m). A host whose collect step is not a tool named `wait`, or
    /// whose `wait` reports its outcome under names of its own, states its
    /// own step here, and the engine renders that text in place of
    /// ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``.
    ///
    /// The sentence must name `completionToken`, and it must lead to a step
    /// that returns the run's result in band. It must not prescribe a call
    /// to the parked tool itself: a tool that parks every call would then
    /// hand the model a new token on each round and never the result. The
    /// engine carries the rendered envelope as the detail of the synthesized
    /// progress event, and the run plane keeps the trailing
    /// ``ToolContext/terminalDetailTailLimit`` characters of a detail, so
    /// the sentence must keep the whole envelope under that limit or the
    /// model loses the token.
    ///
    /// - Parameter completionToken: The parked run's completion token.
    /// - Returns: The `next` text as plain prose; the envelope escapes it
    ///   for the wire.
    func detachmentCollectInstruction(forCompletionToken completionToken: String) -> String
}

extension DetachmentParameterProviding {
    /// Blanket default: the sentence
    /// ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``
    /// renders, which names the `wait` tool and the same token, and no
    /// run-plane state.
    ///
    /// - Parameter completionToken: The parked run's completion token.
    /// - Returns: The default collect sentence for `completionToken`.
    public func detachmentCollectInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// Blanket default: no declared mount, so the tool runs under the
    /// configuration its composition site passes.
    public var detachmentMount: DetachConfiguration? { nil }

    /// Blanket default: no per-call clocks, so both clocks come from the
    /// mount the call resolved to.
    ///
    /// - Parameter arguments: The call's arguments, which this default does
    ///   not read.
    /// - Returns: Two `nil` clocks.
    public func detachmentClocks(
        from arguments: GeneratedContent
    ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
        (nil, nil)
    }
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

        /// Run each call to completion — detachment off, the mode
        /// `ToolInvoker` mounts for inner `tools.*` calls. The same engine
        /// still owns correlation, events, and outcomes.
        ///
        /// ``DetachConfiguration/timeout`` still bounds the work unless it
        /// is `nil`. A host that needs a call which blocks until it finishes
        /// and reports only a real failure needs both halves at once, and
        /// ``DetachConfiguration/runToCompletionMount`` is that pair.
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
    ///
    /// That ordering is a checked rule in ``Mode/detaching``, not a habit —
    /// see `clockRelationFailure(tool:mode:waitSeconds:timeout:)`.
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

    /// The run-to-completion mount: a call blocks until the wrapped tool
    /// finishes, and only a real failure of that tool reaches the model.
    ///
    /// This is the mount for a tool whose result the model cannot proceed
    /// without. A discovery tool is the measured case: a model handed a
    /// pending envelope for discovery stops discovering and starts
    /// collecting, so it never learns what it may call, and it answers that
    /// it has no access at all.
    ///
    /// The mount carries no clock. ``timeout`` is `nil`, so no timeout
    /// watcher is ever started and a slow call can never be reported as a
    /// failed one. A long ``timeout`` is not the same thing and is not a
    /// substitute: a timeout that fires is itself a failure report. A host
    /// that does want a bound on such a call states ``timeout`` on a
    /// configuration of its own, and accepts that the bound reports
    /// ``DetachingToolError/timedOut(tool:timeoutSeconds:)`` when it fires.
    ///
    /// A tool asks for this mount by declaring it as its own
    /// ``DetachmentParameterProviding/detachmentMount``, which is how one
    /// session carries a tool that must never park beside one that must:
    /// every session-mounted tool is composed with the one
    /// ``nativeSessionMount``, so a mount a host could state only for a
    /// whole session would fix the first tool by breaking the second.
    public static let runToCompletionMount = DetachConfiguration(
        mode: .runToCompletion, timeout: nil
    )

    /// Whether a call detaches at ``waitSeconds`` or runs to completion.
    public var mode: Mode

    /// How long one call may block before detaching, in seconds. Nothing
    /// resets it. `0` detaches immediately. Ignored in
    /// ``Mode/runToCompletion``.
    ///
    /// In ``Mode/detaching`` it must stand strictly under ``timeout`` — see
    /// `clockRelationFailure(tool:mode:waitSeconds:timeout:)`.
    public var waitSeconds: TimeInterval

    /// How long the work itself may run, in seconds, or `nil` for no
    /// timeout at all. Every progress event resets it, and it suspends
    /// while an elicitation is pending. Expiry cancels the work and settles
    /// the run as ``OperationOutcome/timedOut``.
    ///
    /// `nil` is how a configuration says "nothing this engine adds bounds
    /// this work": no watcher is started, so the work ends when it ends.
    public var timeout: TimeInterval?

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - mode: Whether a call detaches at `waitSeconds` or runs to
    ///     completion.
    ///   - waitSeconds: How long one call may block before detaching.
    ///     Defaults to ``defaultWaitSeconds``. In ``Mode/detaching`` it must
    ///     stand strictly under `timeout`; a call whose resolved clocks do
    ///     not is refused with
    ///     ``DetachingToolError/invalidClocks(tool:waitSeconds:timeout:)``
    ///     rather than run.
    ///   - timeout: How long the work itself may run, or `nil` for no
    ///     timeout at all. Defaults to ``defaultTimeoutSeconds``.
    public init(
        mode: Mode,
        waitSeconds: TimeInterval = Self.defaultWaitSeconds,
        timeout: TimeInterval? = Self.defaultTimeoutSeconds
    ) {
        self.mode = mode
        self.waitSeconds = waitSeconds
        self.timeout = timeout
    }

    /// Whether a pair of clocks can both mean what they say.
    ///
    /// In ``Mode/detaching`` the two clocks start together and never consult
    /// each other, so `waitSeconds` must stand strictly under `timeout`: a
    /// call that reaches its soft deadline first parks, which is the whole
    /// point of the mode, and the timeout keeps real headroom behind it. A
    /// pair that inverts the order asks the engine to race two timers that
    /// were never meant to meet, and scheduling decides which of the two
    /// answers the caller gets.
    ///
    /// ``Mode/runToCompletion`` ignores `waitSeconds`, and a `nil` `timeout`
    /// is no clock at all, so neither can invert anything.
    ///
    /// This is the one implementation of the rule: the wrap-time
    /// configuration and a per-call override from
    /// ``DetachmentParameterProviding`` are both judged here, on the clocks
    /// the call actually resolved to.
    ///
    /// - Parameters:
    ///   - tool: The wrapped tool's name, for the report.
    ///   - mode: The mode the call runs in.
    ///   - waitSeconds: The call's resolved soft deadline.
    ///   - timeout: The call's resolved timeout, or `nil` for no timeout.
    /// - Returns: The failure to refuse the call with, or `nil` when the
    ///   pair is usable as written.
    static func clockRelationFailure(
        tool: String, mode: Mode, waitSeconds: TimeInterval, timeout: TimeInterval?
    ) -> DetachingToolError? {
        guard mode == .detaching, let timeout, waitSeconds >= timeout else { return nil }
        return .invalidClocks(tool: tool, waitSeconds: waitSeconds, timeout: timeout)
    }
}

/// The failures the ``DetachingTool`` engine itself produces.
///
/// Each case renders as a sentence rather than as its own reflection,
/// because both of them reach a model: a thrown engine failure is what the
/// model reads in place of the tool's output, and it is the `detail` of the
/// run's terminal event.
public enum DetachingToolError: Error, Equatable, CustomStringConvertible {
    /// The per-call `timeout` elapsed with no progress and no pending
    /// elicitation; the work was cancelled and the run settled as
    /// ``OperationOutcome/timedOut``.
    case timedOut(tool: String, timeoutSeconds: TimeInterval)

    /// The call's resolved clocks cannot both mean what they say: in
    /// ``DetachConfiguration/Mode/detaching``, `waitSeconds` did not stand
    /// strictly under `timeout`. The call is refused before any work
    /// starts, so nothing ran, nothing parked, and nothing was reported.
    case invalidClocks(tool: String, waitSeconds: TimeInterval, timeout: TimeInterval)

    /// What the failure says to whoever reads it.
    public var description: String {
        switch self {
        case .timedOut(let tool, let timeoutSeconds):
            "\(tool) timed out after \(timeoutSeconds) seconds with no progress"
        case .invalidClocks(let tool, let waitSeconds, let timeout):
            "\(tool) was called with waitSeconds \(waitSeconds) and timeout \(timeout): "
                + "a detaching tool's waitSeconds must stand strictly under its timeout. "
                + "A tool that must never park is mounted on "
                + "DetachConfiguration.runToCompletionMount, which carries no clock at "
                + "all, rather than on two clocks set to the same number."
        }
    }
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
/// is phrased as repair instructions; so is this one. The wrapped tool owns
/// the sentence (task ^rx6f25m): it supplies one through
/// ``DetachmentParameterProviding/detachmentCollectInstruction(forCompletionToken:)``,
/// and a tool that supplies none gets
/// ``defaultCollectInstruction(forCompletionToken:)``. ``rendered``, not the
/// synthesized `Codable` conformance, is the authoritative wire form.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// Always `true` — the discriminator a reader branches on.
    public let pending: Bool

    /// The parked run's completion token: a ULID string that is also the
    /// run's event `correlationID`.
    public let completionToken: String

    /// The collect step the model must take instead of answering, as plain
    /// prose: the wrapped tool's own sentence, or the default.
    public let next: String

    /// Creates the envelope for a run parked under `completionToken`, with
    /// ``defaultCollectInstruction(forCompletionToken:)`` as its `next` text.
    public init(completionToken: String) {
        self.init(
            completionToken: completionToken,
            next: Self.defaultCollectInstruction(forCompletionToken: completionToken)
        )
    }

    /// Creates the envelope for a run parked under `completionToken`, with
    /// `next` as its collect sentence.
    ///
    /// - Parameters:
    ///   - completionToken: The parked run's completion token.
    ///   - next: The collect sentence, as plain prose — the text the wrapped
    ///     tool supplied through
    ///     ``DetachmentParameterProviding/detachmentCollectInstruction(forCompletionToken:)``.
    public init(completionToken: String, next: String) {
        self.pending = true
        self.completionToken = completionToken
        self.next = next
    }

    /// The collect sentence an envelope carries when the wrapped tool
    /// supplies none.
    ///
    /// It names the in-band collect step and the same token: call the `wait`
    /// tool with the completionToken, and call it again when the run is not
    /// finished. It names no run-plane state, because Router's
    /// ``WaitOutcome`` is a Swift value with no wire spelling: the host's
    /// `wait` tool reports outcomes under names of its own, and a sentence
    /// that named Router's would name values the model never sees. It
    /// prescribes no snippet either: a host whose detaching tool takes no
    /// snippet has nothing to run, and a host whose every call parks would
    /// hand the model a fresh token on each round instead of the result.
    ///
    /// - Parameter completionToken: The parked run's completion token.
    /// - Returns: The default `next` text for `completionToken`.
    public static func defaultCollectInstruction(forCompletionToken completionToken: String) -> String {
        "This run is still going. Do not answer yet, and never invent or guess its result. "
            + "Call the wait tool with completionToken \"\(completionToken)\" to collect the result. "
            + "If the run is not finished yet, call wait again with the same completionToken."
    }

    /// The fixed text before the `completionToken` slot in ``rendered``'s
    /// wire form.
    private static let renderedPrefix = "{\"pending\":true,\"completionToken\":\""

    /// The fixed text between the `completionToken` slot and the `next`
    /// field's string body in ``rendered``'s wire form.
    private static let renderedMidfix = "\",\"next\":\""

    /// The fixed text after the `next` field's string body in ``rendered``'s
    /// wire form.
    private static let renderedSuffix = "\"}"

    /// The first Unicode scalar value that is not a JSON control character:
    /// every scalar under it must be written as a JSON escape.
    private static let firstUnescapedScalarValue: UInt32 = 0x20

    /// Renders the wire form of an envelope for `completionToken` and `next`.
    ///
    /// The one definition both ``rendered`` and ``isRendered(text:)`` go
    /// through, so recognition can never drift from rendering. The frame is
    /// literal — a completion token is a 26-character Crockford base32 ULID,
    /// so its slot needs no escaping — and the `next` body is
    /// ``jsonStringBody(of:)``, so the rendering is total and deterministic
    /// for any sentence.
    ///
    /// - Parameters:
    ///   - completionToken: The parked run's completion token, spliced into
    ///     the wire form's token slot.
    ///   - next: The collect sentence, as plain prose.
    /// - Returns: The envelope's JSON wire form.
    private static func rendered(forCompletionToken completionToken: String, next: String) -> String {
        renderedPrefix + completionToken + renderedMidfix + jsonStringBody(of: next) + renderedSuffix
    }

    /// The body of the JSON string literal for `text`: `"` and `\` escaped,
    /// a control character written as its JSON escape, every other scalar
    /// verbatim.
    ///
    /// A `JSONDecoder` reads this body back to `text`, and re-encoding what
    /// it read gives the same body, which is what lets ``isRendered(text:)``
    /// decode an envelope and re-render it.
    ///
    /// - Parameter text: The plain text to write as a JSON string body.
    /// - Returns: The escaped body, without the surrounding quotes.
    private static func jsonStringBody(of text: String) -> String {
        var body = ""
        body.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": body += "\\\""
            case "\\": body += "\\\\"
            case "\n": body += "\\n"
            case "\r": body += "\\r"
            case "\t": body += "\\t"
            default:
                if scalar.value < firstUnescapedScalarValue {
                    body += String(format: "\\u%04x", scalar.value)
                } else {
                    body.unicodeScalars.append(scalar)
                }
            }
        }
        return body
    }

    /// The envelope rendered as its JSON wire form.
    public var rendered: String {
        Self.rendered(forCompletionToken: completionToken, next: next)
    }

    /// Whether `text` is exactly a rendered pending envelope: the fixed
    /// ``rendered`` frame around a valid ULID `completionToken` and a `next`
    /// field, whatever sentence that field carries.
    ///
    /// This is what lets a decorator outside the detachment layer — today
    /// ``TokenCappingTool`` — recognize control-plane wire data and pass it
    /// through untouched, without JSON-parsing arbitrary tool output: the
    /// frame is checked byte for byte first — the prefix, a valid ULID in
    /// the token slot, the `next` field's opening, and the closing — and
    /// only text that holds the whole frame is decoded. Recognition is then
    /// defined as re-rendering: `text` must equal what this envelope renders
    /// for the token in its slot and the `next` it decoded, so an unclosed or
    /// malformed `next` field and any text outside the frame are rejections
    /// by construction.
    ///
    /// - Parameter text: The rendered tool output to test.
    /// - Returns: `true` iff `text` is a rendered pending envelope.
    public static func isRendered(text: String) -> Bool {
        guard text.hasPrefix(renderedPrefix), text.hasSuffix(renderedSuffix) else {
            return false
        }
        let afterPrefix = text.dropFirst(renderedPrefix.count)
        let completionToken = String(afterPrefix.prefix(ULID.stringLength))
        guard
            ULID(completionToken) != nil,
            afterPrefix.dropFirst(ULID.stringLength).hasPrefix(renderedMidfix),
            let decoded = try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
        else {
            return false
        }
        return text == rendered(forCompletionToken: completionToken, next: decoded.next)
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
///    A `nil` timeout starts no watcher at all, so the work is bounded by
///    nothing this engine adds. In
///    ``DetachConfiguration/Mode/runToCompletion`` the call runs to
///    completion — same engine, detachment off — and on
///    ``DetachConfiguration/runToCompletionMount`` it does so under no
///    clock, so only a real failure of the wrapped tool ever reaches the
///    model.
/// 6. Refuses, before any work starts, a call whose resolved clocks cannot
///    both mean what they say (`clockRelationFailure(tool:mode:waitSeconds:timeout:)`),
///    and refuses to park a run the timeout has already claimed — the two
///    clocks decide one at a time, never by race.
/// 7. Runs under the mount the wrapped tool declares for itself
///    (``DetachmentParameterProviding/detachmentMount``) when it declares
///    one, and under the configuration its composition site passed
///    otherwise. So one session mounts a tool that must never park beside
///    one that must, each behaving its own way.
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

    /// The mount every call of this tool runs under: the tool's own
    /// ``DetachmentParameterProviding/detachmentMount`` when it declares
    /// one, and the configuration the composition site passed otherwise.
    /// Per-call values from
    /// ``DetachmentParameterProviding/detachmentClocks(from:)`` override its
    /// clocks.
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
    ///   - configuration: The mode and clock defaults to mount `wrapped`
    ///     under, unless `wrapped` declares a mount of its own through
    ///     ``DetachmentParameterProviding/detachmentMount``.
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
        // The tool's own declaration wins, and it is read here rather than
        // per call because a mode is a property of the tool: a session
        // mounts tools that no single policy fits, and each of them must
        // behave its own way on that one session.
        self.configuration =
            (wrapped as? any DetachmentParameterProviding)?.detachmentMount ?? configuration
    }

    /// Runs one call through the engine — see the type doc for the full
    /// behavior.
    ///
    /// Around the wrapped call this also posts a ``ToolInvocationRecord``
    /// pair to ``sink``: the open record is awaited to delivery before the
    /// work starts, and the close record is posted when the wrapped call
    /// returns — before this method returns for an in-band settlement, or
    /// late (self-attributed by its `correlationID`) for a detached run.
    ///
    /// - Parameter arguments: The call's arguments, forwarded to the
    ///   wrapped tool untouched.
    /// - Returns: The wrapped tool's rendered output when the call settles
    ///   in-band, or ``PendingRunEnvelope/rendered`` when it detaches.
    /// - Throws: Whatever the wrapped tool throws, unmodified, when the
    ///   call settles in-band with an error;
    ///   ``DetachingToolError/timedOut(tool:timeoutSeconds:)`` when the
    ///   per-call timeout ends an in-band call, or when it claims a call
    ///   the soft deadline was about to detach;
    ///   ``DetachingToolError/invalidClocks(tool:waitSeconds:timeout:)``
    ///   when the resolved clocks cannot both mean what they say, in which
    ///   case no work starts at all.
    public func call(arguments: Arguments) async throws -> String {
        let clocks = perCallClocks(from: arguments)
        let waitSeconds = clocks.waitSeconds ?? configuration.waitSeconds
        let timeoutSeconds = clocks.timeout ?? configuration.timeout
        // Judged before anything runs, so a refused call leaves no run, no
        // parked token, and no event behind it.
        if let failure = DetachConfiguration.clockRelationFailure(
            tool: wrapped.name,
            mode: configuration.mode,
            waitSeconds: waitSeconds,
            timeout: timeoutSeconds
        ) {
            throw failure
        }

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

        // The open record, awaited to delivery before the work starts, so a
        // live consumer sees the invocation while the tool still runs. Posted
        // straight to the upstream sink, never through the funnel: invocation
        // records are delivery-only and take no part in the funnel's
        // staging/terminal synthesis.
        let openRecord = ToolInvocationRecord(
            tool: context.tool,
            op: context.op,
            correlationID: completionToken,
            sessionID: sessionID,
            openedAt: Date()
        )
        await sink.post(invocation: openRecord)

        let wrapped = self.wrapped
        let sink = self.sink
        let workTask = Task { () async -> RunSettlement in
            let settlement = await ToolContext.$current.withValue(context) {
                await Self.settle(
                    calling: wrapped,
                    arguments: arguments,
                    context: context,
                    funnel: funnel,
                    timeoutSeconds: timeoutSeconds,
                    cancellationFlag: cancellationFlag
                )
            }
            // The close record: awaited before this task's value resolves, so
            // an in-band settlement delivers it before `call` returns. A
            // detached run posts it late, when its work really ends —
            // self-attributed by the record's `correlationID`.
            await sink.post(invocation: openRecord.closed(at: Date()))
            return settlement
        }

        // Each await below that the model is genuinely suspended on is marked as
        // a tool-call window, so a turn the body starts on another session over
        // the same resident model may run on this turn's generation permit (see
        // ``withGenerationSuspendedForToolCall(_:)``). Nothing after a detach is
        // marked: once the pending envelope goes back the turn resumes, and its
        // permit is no longer free to lend.
        switch configuration.mode {
        case .runToCompletion:
            return try await withTaskCancellationHandler {
                let settlement = await withGenerationSuspendedForToolCall {
                    await workTask.value
                }
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
            let raced = await withGenerationSuspendedForToolCall {
                await Self.raceSettlement(of: workTask, deadlineNanoseconds: deadline)
            }
            switch raced {
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

    /// The wrapped tool as the declarer of its own detachment parameters, or
    /// `nil` when it does not conform to ``DetachmentParameterProviding``.
    private var parameterProvider: (any DetachmentParameterProviding)? {
        wrapped as? any DetachmentParameterProviding
    }

    /// The per-call clocks the wrapped tool supplies through
    /// ``DetachmentParameterProviding``, or all-`nil` when it does not
    /// conform (or its arguments cannot round-trip to `GeneratedContent`).
    private func perCallClocks(
        from arguments: Arguments
    ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
        guard
            let provider = parameterProvider,
            let convertible = arguments as? any ConvertibleToGeneratedContent
        else {
            return (nil, nil)
        }
        return provider.detachmentClocks(from: convertible.generatedContent)
    }

    /// The `next` sentence of the pending envelope for `completionToken`:
    /// the wrapped tool's own through
    /// ``DetachmentParameterProviding/detachmentCollectInstruction(forCompletionToken:)``,
    /// or ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``
    /// when it does not conform.
    private func collectInstruction(forCompletionToken completionToken: String) -> String {
        guard let provider = parameterProvider else {
            return PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
        }
        return provider.detachmentCollectInstruction(forCompletionToken: completionToken)
    }

    // MARK: - Detachment

    /// Detaches a call whose window elapsed: parks the still-running work
    /// in the mailbox, posts the synthesized progress iff the run has been
    /// silent, and returns the pending envelope.
    ///
    /// The funnel decides, so the two clocks never race: a run that settled
    /// in the instants between the window elapsing and detachment, and a run
    /// the timeout claimed in that same window, are both refused here, and
    /// this returns the in-band result instead. A model is therefore handed
    /// a completion token only for a run that is really still going.
    private func detach(
        workTask: Task<RunSettlement, Never>,
        funnel: RunEventFunnel,
        context: ToolContext,
        cancellationFlag: CancellationRequestFlag
    ) async throws -> String {
        let envelope = PendingRunEnvelope(
            completionToken: context.completionToken,
            next: collectInstruction(forCompletionToken: context.completionToken)
        )
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
        timeoutSeconds: TimeInterval?,
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
    ///
    /// A `nil` `timeoutSeconds` is no clock at all: no watcher is started,
    /// there is nothing to race, and the call ends when the inner call
    /// ends. That is what
    /// ``DetachConfiguration/runToCompletionMount`` mounts a tool under, so
    /// only a real failure of the wrapped tool can reach the model.
    private static func raceInnerAgainstTimeout(
        inner: Task<String, any Error>,
        timeoutSeconds: TimeInterval?,
        funnel: RunEventFunnel,
        cancellationFlag: CancellationRequestFlag,
        tool: String
    ) async -> Result<String, any Error> {
        guard let timeoutSeconds else {
            return await inner.result
        }
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
    /// A window that really elapsed claims the run through
    /// `RunEventFunnel.beginTimeout()` before this reports it, so a soft
    /// deadline elapsing in the same instant can no longer park a run this
    /// watcher is about to kill: `RunEventFunnel.markDetached(postingIfSilent:)`
    /// refuses a claimed run, and the caller takes the in-band timeout
    /// instead of handing the model a token for a dead run.
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
            await funnel.beginTimeout()
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
/// layers `ToolOutputCapping` over ``wrapping(tool:sessionID:mailbox:sink:configuration:)``,
/// and lives beside the capping layer so this file carries no dependency
/// on it.
public enum ToolDetachment {
    /// Wraps `tool` on the session plane an ambient ``ToolContext`` already
    /// names — the entry point for a binder outside this package that mounts
    /// its own inner calls under a tool of its own (`FoundationModelsMultitool`
    /// gives every `tools.*` call inside one `runCode` snippet its own
    /// correlation this way).
    ///
    /// ``ToolContext/mailbox`` is internal (task ^j0pp9yp), so such a binder
    /// cannot call ``wrapping(tool:sessionID:mailbox:sink:configuration:)``
    /// itself. It has no need to name either value: a captured ambient
    /// context already carries the session identity and the mailbox, and
    /// this reads both off it. The decision, the decorators, and every
    /// guarantee are that method's, unchanged.
    ///
    /// `sink` stays a parameter rather than being read off `context`,
    /// because the two are not the same route: a binder that re-stamps an
    /// inner run's events onto its own outer correlation posts through
    /// ``ToolContext/post(_:)``, which the context's own sink would bypass.
    ///
    /// - Parameters:
    ///   - tool: The tool to consider for detachment.
    ///   - context: The enclosing call's ambient context, captured while its
    ///     binding was still in scope.
    ///   - sink: The upstream sink the run's events are posted to.
    ///   - configuration: The mode and clock defaults to mount `tool` under,
    ///     unless it declares a mount of its own through
    ///     ``DetachmentParameterProviding/detachmentMount``.
    /// - Returns: The detaching decorator around `tool` when it qualifies;
    ///   the binding-only ``ContextBindingTool`` around it otherwise.
    public static func wrapping(
        tool: any Tool,
        inheriting context: ToolContext,
        sink: any OperationEventSink,
        configuration: DetachConfiguration
    ) -> any Tool {
        wrapping(
            tool: tool,
            sessionID: context.sessionID,
            mailbox: context.mailbox,
            sink: sink,
            configuration: configuration
        )
    }

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
    ///   - configuration: The mode and clock defaults to mount `tool` under,
    ///     unless it declares a mount of its own through
    ///     ``DetachmentParameterProviding/detachmentMount``.
    /// - Returns: The detaching decorator around `tool` when it qualifies;
    ///   the binding-only ``ContextBindingTool`` around it otherwise.
    public static func wrapping(
        tool: any Tool,
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
    /// Around the wrapped call this also posts a ``ToolInvocationRecord``
    /// pair to ``sink``: the open record is awaited to delivery before the
    /// call starts, and the close record before this method returns — on the
    /// success path and the throwing path alike, since a call always runs
    /// in-band here.
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
        let openRecord = ToolInvocationRecord(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            sessionID: sessionID,
            openedAt: Date()
        )
        await sink.post(invocation: openRecord)
        return try await withTaskCancellationHandler {
            // Captured as a `Result` rather than rethrown directly so the
            // close record is posted on the throwing path too — `defer`
            // cannot await.
            let outcome: Result<Output, any Error>
            do {
                // A call here always runs in-band, so the model is suspended on
                // it for its whole length: the window a turn's generation permit
                // may be lent across (see
                // ``withGenerationSuspendedForToolCall(_:)``).
                outcome = .success(
                    try await withGenerationSuspendedForToolCall {
                        try await ToolContext.$current.withValue(context) {
                            try await wrapped.call(arguments: arguments)
                        }
                    })
            } catch {
                outcome = .failure(error)
            }
            await sink.post(invocation: openRecord.closed(at: Date()))
            return try outcome.get()
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
///
/// It is also where the two clocks are kept from racing: the timeout claims
/// the run here (``beginTimeout()``) and detachment asks here
/// (``markDetached(postingIfSilent:)``), so exactly one of them decides what
/// happens to a run, whichever order they arrive in.
///
/// Internal rather than file-private so that one decision can be tested
/// directly; nothing outside this file constructs one.
actor RunEventFunnel: OperationEventSink {
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

    /// Whether the timeout has claimed the run — set the moment a whole
    /// timeout window is known to have elapsed, and never cleared.
    private var hasTimedOut = false

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
    func post(event: OperationEvent) async {
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

    /// Claims the run for the timeout, so no later detachment can park it.
    ///
    /// Called the moment a whole timeout window is known to have elapsed —
    /// before the timeout resolves its race — so the claim always lands
    /// ahead of the cancellation it is about to request. A soft deadline
    /// that elapses in the same instant then finds a claimed run and takes
    /// the in-band timeout rather than handing the model a token for a run
    /// this claim has killed.
    func beginTimeout() {
        hasTimedOut = true
    }

    /// Marks the run detached and, iff it has posted nothing yet, delivers
    /// the one synthesized progress event.
    ///
    /// - Parameter progress: The synthesized progress to deliver when the
    ///   run has been silent.
    /// - Returns: `true` when the run is (now) detached; `false` when it
    ///   already settled, or when the timeout has claimed it — the caller
    ///   returns the in-band result instead of parking a run that is
    ///   finished or being killed.
    func markDetached(postingIfSilent progress: OperationEvent) async -> Bool {
        guard case .running = phase, !hasTimedOut else {
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
        return deliveryChain.enqueue { await upstream.post(event: event) }
    }
}
