import FoundationModels
import Synchronization

/// The relay of the executor channel of one pass (task ^0m997jr): it gives the
/// wrapped executor a channel of its own, forwards each event to the channel
/// of the SDK unchanged and in order, and reports the first output event
/// (``GenerationPassObserver/passSentFirstOutputEvent()``) and the first
/// streamed output (``GenerationPassObserver/passProducedOutput(at:)``) of
/// the pass to the pass observer of the session.
///
/// The executor channel is the first place that any output of a pass shows:
/// response text, reasoning text and tool-call arguments. The transcript of
/// the session shows tool-call arguments only after the pass, so a watch of
/// the transcript never sees the first token of a call whose only output is a
/// tool call.
///
/// The first output event of a pass is its first token only when a later
/// output event of the same pass follows it. A pass that sends its whole
/// output in one event sent it after it generated it, so the time of that
/// event splits nothing: the pass reports its one output event and no first
/// output, so its call is buffered (``GenerationCallUsage/outputBuffered``,
/// task ^kg3yjc9) and has no split by design
/// (``GenerationCallUsage/firstTokenSeen`` is `false`). The
/// allowed-tool path of the MLX executor is such a pass: it keeps the
/// response text and the tool calls of the pass until the generation ends,
/// and then sends them. Its only signals inside the pass (its generation
/// observer and the end of its prefill) are internal to MLXFoundationModels.
///
/// A generation channel is a rendezvous channel with no public end, so the
/// relay has the shape of the generate relay of FoundationModelsExtras: a
/// pump reads the channel of the executor into a buffered stream, and a
/// forwarder sends the stream to the channel of the SDK. When the executor
/// returns, each of its sends returned, so each event is in the stream; the
/// relay then cancels the pump, which ends the stream. The forwarder is a
/// child of the pass, so a cancel of the pass reaches it: the SDK stops its
/// read of the channel of a cancelled call, and a forwarder that the cancel
/// did not reach would wait in its send for good, and the pass with it.
enum PassOutputRelay {
    /// The type of the events of a pass.
    typealias Event = LanguageModelExecutorGenerationChannel.Event

    /// The deepest level of the value tree of an event that ``isOutput(_:)``
    /// reads. The fragment of an append is at the fourth level.
    private static let deepestEventLevel = 8

    /// What the pump of one pass saw of its output, and the report of its
    /// first output event and its first streamed output.
    private final class OutputWatch: Sendable {
        /// What the pump saw of the output of the pass.
        private struct Seen {
            /// When the first output event of the pass came, or `nil` before it.
            var firstAt: ContinuousClock.Instant?

            /// Whether the pass reported its first output.
            var reported = false
        }

        /// The pass observer of the session.
        private let observer: GenerationPassObserver

        /// What the pump saw, under a lock: the pump and the relay run on
        /// two tasks.
        private let seen = Mutex(Seen())

        /// Makes the watch of one pass.
        ///
        /// - Parameter observer: The pass observer of the session.
        init(reportingTo observer: GenerationPassObserver) {
            self.observer = observer
        }

        /// What one output event of the pass reports to the observer.
        private enum Report {
            /// The first output event of the pass
            /// (``GenerationPassObserver/passSentFirstOutputEvent()``).
            case firstOutputEvent

            /// The first token of the pass, which the first output event
            /// gave at `at` (``GenerationPassObserver/passProducedOutput(at:)``).
            case firstToken(at: ContinuousClock.Instant)
        }

        /// Notes one event of the pass: the first output event starts the
        /// output and is reported at once, and the next output event reports
        /// it as the first token.
        ///
        /// The first output event is reported before the pump hands it to
        /// the forwarder, so the session has the report before the SDK sees
        /// the event, and before a tool call of the pass can open.
        ///
        /// - Parameter event: An event of the pass.
        func note(_ event: Event) {
            guard isOutput(event) else { return }
            let now = observer.clock.now
            let report: Report? = seen.withLock { seen in
                guard let firstAt = seen.firstAt else {
                    seen.firstAt = now
                    return .firstOutputEvent
                }
                guard !seen.reported else { return nil }
                seen.reported = true
                return .firstToken(at: firstAt)
            }
            switch report {
            case .firstOutputEvent:
                observer.passSentFirstOutputEvent()
            case .firstToken(let firstAt):
                observer.passProducedOutput(at: firstAt)
            case nil:
                break
            }
        }
    }

    /// Whether `event` carries output of the model: response text, reasoning
    /// text, a replaced text segment, or a part of the arguments of a tool
    /// call. Metadata, usage and reasoning signatures carry none.
    ///
    /// The event type shows no public value, so the check reads its value
    /// tree by reflection and looks for a public fragment value in it, as
    /// FoundationModelsExtras reads the usage of an event.
    ///
    /// - Parameter event: An event of a pass.
    /// - Returns: `true` when the event holds an output fragment.
    static func isOutput(_ event: Event) -> Bool {
        holdsFragment(Mirror(reflecting: event), level: 1)
    }

    /// Whether the value tree under `mirror` holds an output fragment, up to
    /// ``deepestEventLevel``.
    ///
    /// - Parameters:
    ///   - mirror: The mirror of a value of an event.
    ///   - level: The level of the children of `mirror` in the value tree.
    /// - Returns: `true` when a child is an output fragment.
    private static func holdsFragment(_ mirror: Mirror, level: Int) -> Bool {
        guard level <= deepestEventLevel else { return false }
        return mirror.children.contains { child in
            isFragment(child.value) || holdsFragment(Mirror(reflecting: child.value), level: level + 1)
        }
    }

    /// Whether `value` is one of the public output fragments of an event.
    ///
    /// - Parameter value: A value of the value tree of an event.
    /// - Returns: `true` for a text fragment, a text segment replacement and
    ///   a fragment of tool-call arguments.
    private static func isFragment(_ value: Any) -> Bool {
        value is LanguageModelExecutorGenerationChannel.TextFragment
            || value is LanguageModelExecutorGenerationChannel.TextSegmentReplacement
            || value is LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.ArgumentsFragment
    }

    /// Runs `run` with a new channel, forwards each of its events to
    /// `channel`, and reports the first output event and the first streamed
    /// output of the pass to `observer`.
    ///
    /// - Parameters:
    ///   - channel: The channel of the SDK.
    ///   - observer: The pass observer of the session.
    ///   - run: Runs the wrapped executor with the channel that it gets.
    /// - Throws: The error of `run`.
    static func relay(
        into channel: LanguageModelExecutorGenerationChannel,
        reportingTo observer: GenerationPassObserver,
        _ run: (LanguageModelExecutorGenerationChannel) async throws -> Void
    ) async throws {
        let executorChannel = LanguageModelExecutorGenerationChannel()
        let (events, buffer) = AsyncStream.makeStream(of: Event.self)
        async let forwarded: Void = forward(events, into: channel)
        let watch = OutputWatch(reportingTo: observer)
        let failure = await withTaskGroup(of: Void.self) { group -> (any Error)? in
            group.addTask {
                await pump(executorChannel, into: buffer, observing: watch.note)
            }
            defer { group.cancelAll() }
            do {
                try await run(executorChannel)
                return nil
            } catch {
                return error
            }
        }
        await forwarded
        if let failure {
            throw failure
        }
    }

    /// Reads each event of `executorChannel` until the task is cancelled,
    /// gives it to `observe`, and puts it in `buffer`. Then ends `buffer`.
    ///
    /// - Parameters:
    ///   - executorChannel: The channel of the wrapped executor.
    ///   - buffer: The stream of the forwarder.
    ///   - observe: Sees each event.
    private static func pump(
        _ executorChannel: LanguageModelExecutorGenerationChannel,
        into buffer: AsyncStream<Event>.Continuation,
        observing observe: (Event) -> Void
    ) async {
        defer { buffer.finish() }
        do {
            for try await event in executorChannel {
                observe(event)
                buffer.yield(event)
            }
        } catch {
            // Only a failed channel throws, and nothing fails the new channel
            // of a pass. A failure is a defect, so the debug build stops.
            assertionFailure("the channel of a pass failed")
        }
    }

    /// Sends each event of `events` to `channel`, in order, until `events`
    /// ends.
    ///
    /// - Parameters:
    ///   - events: The stream of the pump.
    ///   - channel: The channel of the SDK.
    private static func forward(_ events: AsyncStream<Event>, into channel: LanguageModelExecutorGenerationChannel) async {
        for await event in events {
            await channel.send(event)
        }
    }
}
