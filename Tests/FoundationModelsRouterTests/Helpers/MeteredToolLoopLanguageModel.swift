import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Tracing

@testable import FoundationModelsRouter

/// The usage one generation call of a ``MeteredToolLoopLanguageModel``
/// reports.
struct MeteredGenerationCall: Sendable, Hashable {
    /// The input token count the call reports.
    let tokensIn: Int

    /// The output token count the call reports.
    let tokensOut: Int

    /// The part of ``tokensIn`` the call reports its prompt cache reused, as
    /// the MLX executor reports its `cachedTokenCount`.
    var tokensCached: Int = 0

    /// How the call paces its output, or `nil` (the default) for a call that
    /// sends its output at once.
    var pacing: MeteredCallPacing?
}

/// The pace of one generation call of a ``MeteredToolLoopLanguageModel``, as
/// a real model paces a call: it prefills, sends its first output token, and
/// then decodes the rest.
///
/// The call does not wait in real time. It moves a ``MeteredPaceClock``
/// forward by each of the two durations.
struct MeteredCallPacing: Sendable, Hashable {
    /// The text of the first output token, which the call sends after
    /// ``prefill``. The rest of the output follows after ``decode``.
    static let firstTokenText = "Looking. "

    /// How far the call moves the clock before it sends its first output
    /// token.
    let prefill: Duration

    /// How far the call moves the clock after its first output token, before
    /// it sends the rest of its output and its usage.
    let decode: Duration

    /// What the first output of the call is.
    var firstOutput: MeteredFirstOutput = .responseText
}

/// What the first output of a paced ``MeteredToolLoopLanguageModel`` call is.
enum MeteredFirstOutput: Sendable, Hashable {
    /// Response text (``MeteredCallPacing/firstTokenText``), then the tool
    /// call or the answer of the call.
    case responseText

    /// The first part of the arguments of the tool call
    /// (``MeteredToolLoopLanguageModel/Executor/argumentsHead``), and the rest
    /// of them after the decode. A call that answers with text sends response
    /// text first, as ``responseText`` does.
    case toolCallArguments

    /// Nothing until the end of the call: the call moves the clock by its
    /// prefill and its decode, then sends its whole output at once, as the
    /// allowed-tool path of the MLX executor sends a tool call.
    case nothingUntilTheEnd
}

/// The clock that paces the calls of a ``MeteredToolLoopLanguageModel``, in
/// place of a real wait.
///
/// The session reads the times of a generation call on its run clock
/// (``GenerationPassObserver/clock``). ``MeteredToolLoopSessionFixture``
/// gives ``clock`` to its router as that run clock
/// (``Router/useRunClock(_:)``). A paced call moves the clock forward by its
/// prefill and by its decode, so each time that the session reads is the
/// scripted time, and no test waits in real time.
///
/// The relay of a pass (``PassOutputRelay``) reads the clock for the first
/// output event of the pass. That read can come after the send of the event
/// returns. Thus a paced call sends its first output with
/// ``sendFirstOutput(_:into:)``, which waits until the pass observer of the
/// session recorded that event. Only then does the call move the clock by its
/// decode. The fixture gives the observer of its session to ``bind(_:)``
/// before the first prompt.
///
/// Two values are equal only when they are the same object, because the
/// executor configuration that holds a value is the cache key of the
/// executor.
final class MeteredPaceClock: Sendable, Hashable {
    /// The failure of a paced call when no pass observer is bound.
    struct UnboundObserver: Error {}

    /// The run clock of the session. Only the paced calls move it.
    let clock = ManualRunClock()

    /// The pass observer of the session, or `nil` before ``bind(_:)``.
    private let observer = Mutex<GenerationPassObserver?>(nil)

    /// Binds the pass observer of the session that runs the paced calls.
    ///
    /// - Parameter observer: The pass observer of the session.
    func bind(_ observer: GenerationPassObserver) {
        self.observer.withLock { $0 = observer }
    }

    /// Moves the clock forward by `duration`.
    ///
    /// - Parameter duration: How far the clock moves.
    func advance(by duration: Duration) {
        clock.advance(by: duration)
    }

    /// Sends `event`, the first output event of the running pass, and waits
    /// until the pass observer recorded it.
    ///
    /// The pass observer records the start of the running pass before the
    /// executor runs the pass. Thus the first phase that it records after
    /// the read of its change count is the first output event of the pass,
    /// at the instant that the relay read on ``clock``.
    ///
    /// - Parameters:
    ///   - event: The first output event of the pass.
    ///   - channel: The generation channel of the pass.
    /// - Throws: ``UnboundObserver`` when no pass observer is bound, and
    ///   `CancellationError` when the call is cancelled in the wait.
    func sendFirstOutput(
        _ event: LanguageModelExecutorGenerationChannel.Event, into channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard let observer = observer.withLock({ $0 }) else { throw UnboundObserver() }
        let seen = observer.phaseChanges.changeCount
        await channel.send(event)
        // The wait ends when the relay records the event, or when the call is
        // cancelled. No other event ends it. If this wait hangs, take the
        // stacks of the test process: the relay of the pass did not report
        // the event to the observer.
        guard await observer.phaseChanges.waitForChange(after: seen) else { throw CancellationError() }
    }

    /// Whether `lhs` and `rhs` are the same object.
    ///
    /// - Parameters:
    ///   - lhs: A pace clock.
    ///   - rhs: A pace clock.
    /// - Returns: `true` when the two are the same object.
    static func == (lhs: MeteredPaceClock, rhs: MeteredPaceClock) -> Bool {
        lhs === rhs
    }

    /// Hashes the identity of this object.
    ///
    /// - Parameter hasher: The hasher.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// A deterministic `LanguageModel` that makes one generation call for each
/// entry of ``calls``, in order. Every call but the last asks for the marker
/// tool. The last call answers with text. Each call reports the usage its
/// entry names, on its own response entry, as the MLX executor reports the
/// usage of one call.
///
/// It carries no generation state of its own: each executor call reads the
/// count of tool rounds out of the transcript it is handed, and that count is
/// the position of the call in ``calls``.
struct MeteredToolLoopLanguageModel: LanguageModel {
    /// The usage of each generation call, in call order.
    let calls: [MeteredGenerationCall]

    /// The clock that the paced calls move. The default is a new clock that
    /// no observer is bound to, which only a script with no paced call can
    /// use.
    var pace = MeteredPaceClock()

    /// Declares tool calling, because a tool-mounted session refuses a model
    /// without it.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// Builds the executor cache key from the scripted calls and the pace
    /// clock.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(calls: calls, pace: pace)
    }

    /// The executor that plays out the scripted calls.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// The usage of each generation call, in call order.
            let calls: [MeteredGenerationCall]

            /// The clock that the paced calls move.
            let pace: MeteredPaceClock
        }

        /// The failure a generation call past the end of the script raises.
        struct UnscriptedCall: Error {
            /// The zero-based position of the call the script does not name.
            // A test failure shows this error through `String(describing:)`, which reads this property by
            // reflection. Periphery cannot see that read.
            // periphery:ignore
            let callIndex: Int
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = MeteredToolLoopLanguageModel

        /// The answer text the last call sends.
        static let answerText = "The lookups are done."

        /// The name of the tool each call but the last asks for. The session
        /// mounts a ``MarkerEmittingTool`` under it.
        static let toolName = MarkerEmittingTool.toolName

        /// The token count every emitted fragment reports. The usage of a call
        /// comes from its `.updateUsage` action, not from this count.
        private static let emittedTokenCount = 1

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The scripted calls.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// The step name the call at `callIndex` gives the tool as its `value`
        /// argument.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The step name.
        static func toolStep(callIndex: Int) -> String {
            "lookup-\(callIndex)"
        }

        /// The zero-based position of the call `transcript` asks for: the
        /// count of `.toolCalls` entries the earlier calls left in it.
        ///
        /// - Parameter transcript: The transcript this call was handed.
        /// - Returns: The position of the call in the script.
        private static func callIndex(of transcript: Transcript) -> Int {
            transcript.filter { entry in
                if case .toolCalls = entry { return true }
                return false
            }.count
        }

        /// Moves `pace` by the prefill of `pacing`, sends `firstOutput` as the
        /// first output of the call, and then moves `pace` by the decode of
        /// `pacing`.
        ///
        /// - Parameters:
        ///   - firstOutput: The first output event of the call.
        ///   - pacing: The pace of the call.
        ///   - pace: The clock that the call moves.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: What ``MeteredPaceClock/sendFirstOutput(_:into:)`` throws.
        private static func send(
            firstOutput: LanguageModelExecutorGenerationChannel.Event, after pacing: MeteredCallPacing,
            on pace: MeteredPaceClock, into channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            pace.advance(by: pacing.prefill)
            try await pace.sendFirstOutput(firstOutput, into: channel)
            pace.advance(by: pacing.decode)
        }

        /// The event that sends the first output token of a call as response
        /// text.
        ///
        /// - Parameter entryID: The id of the response entry of the call.
        /// - Returns: The event.
        private static func firstTokenEvent(entryID: String) -> LanguageModelExecutorGenerationChannel.Event {
            .response(
                entryID: entryID, action: .appendText(MeteredCallPacing.firstTokenText, tokenCount: emittedTokenCount))
        }

        /// The first part of the arguments of a tool call that streams its
        /// arguments (``MeteredFirstOutput/toolCallArguments``).
        static let argumentsHead = #"{"value":"#

        /// The rest of the arguments of the tool call of the call at
        /// `callIndex`, after ``argumentsHead``.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The rest of the arguments.
        static func argumentsTail(callIndex: Int) -> String {
            #""\#(toolStep(callIndex: callIndex))"}"#
        }

        /// The event that sends `arguments` as a part of the arguments of the
        /// tool call of the call at `callIndex`.
        ///
        /// - Parameters:
        ///   - arguments: The part of the arguments.
        ///   - callIndex: The zero-based position of the call.
        /// - Returns: The event.
        private static func argumentsEvent(
            _ arguments: String, callIndex: Int
        ) -> LanguageModelExecutorGenerationChannel.Event {
            .toolCalls(
                entryID: "metered-tool-calls-\(callIndex)",
                action: .toolCall(
                    id: "metered-call-\(callIndex)",
                    name: toolName,
                    action: .appendArguments(arguments, tokenCount: emittedTokenCount)))
        }

        /// Sends `arguments` as a part of the arguments of the tool call of the
        /// call at `callIndex`.
        ///
        /// - Parameters:
        ///   - arguments: The part of the arguments.
        ///   - callIndex: The zero-based position of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendArguments(
            _ arguments: String, callIndex: Int, into channel: LanguageModelExecutorGenerationChannel
        ) async {
            await channel.send(argumentsEvent(arguments, callIndex: callIndex))
        }

        /// Sends the whole output of the call at `callIndex`: the answer text
        /// for the last call, and the tool call for each other call.
        ///
        /// - Parameters:
        ///   - callIndex: The zero-based position of the call.
        ///   - isAnswer: Whether the call is the last call, which answers.
        ///   - responseEntryID: The id of the response entry of the call.
        ///   - channel: The generation channel this call emits into.
        private static func sendOutput(
            callIndex: Int, isAnswer: Bool, responseEntryID: String,
            into channel: LanguageModelExecutorGenerationChannel
        ) async {
            guard !isAnswer else {
                await channel.send(
                    .response(
                        entryID: responseEntryID, action: .appendText(answerText, tokenCount: emittedTokenCount)))
                return
            }
            await sendArguments(argumentsHead + argumentsTail(callIndex: callIndex), callIndex: callIndex, into: channel)
        }

        /// Sends the scripted call at the position `request` asks for.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript this
        ///     call branches on.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: ``UnscriptedCall`` when the SDK asks for a call past the
        ///   end of the script, and what
        ///   ``MeteredPaceClock/sendFirstOutput(_:into:)`` throws for a paced
        ///   call.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: MeteredToolLoopLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = Self.callIndex(of: request.transcript)
            guard callIndex < configuration.calls.count else {
                throw UnscriptedCall(callIndex: callIndex)
            }
            let responseEntryID = "metered-response-\(callIndex)"
            let call = configuration.calls[callIndex]
            let isAnswer = callIndex == configuration.calls.count - 1
            let pace = configuration.pace
            switch call.pacing {
            case .some(let pacing) where pacing.firstOutput == .toolCallArguments && !isAnswer:
                try await Self.send(
                    firstOutput: Self.argumentsEvent(Self.argumentsHead, callIndex: callIndex), after: pacing,
                    on: pace, into: channel)
                await Self.sendArguments(Self.argumentsTail(callIndex: callIndex), callIndex: callIndex, into: channel)
            case .some(let pacing) where pacing.firstOutput == .nothingUntilTheEnd:
                pace.advance(by: pacing.prefill + pacing.decode)
                await Self.sendOutput(callIndex: callIndex, isAnswer: isAnswer, responseEntryID: responseEntryID, into: channel)
            case .some(let pacing):
                try await Self.send(
                    firstOutput: Self.firstTokenEvent(entryID: responseEntryID), after: pacing, on: pace, into: channel)
                await Self.sendOutput(callIndex: callIndex, isAnswer: isAnswer, responseEntryID: responseEntryID, into: channel)
            case .none:
                await Self.sendOutput(callIndex: callIndex, isAnswer: isAnswer, responseEntryID: responseEntryID, into: channel)
            }
            await channel.send(
                .response(
                    entryID: responseEntryID,
                    action: .updateUsage(
                        input: .init(totalTokenCount: call.tokensIn, cachedTokenCount: call.tokensCached),
                        output: .init(totalTokenCount: call.tokensOut, reasoningTokenCount: 0))))
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``MeteredToolLoopLanguageModel``, with the tool it mounts, the recorder
/// that holds its run journal, and the directory the router cached into.
///
/// A test ends the fixture with ``SessionDirectoryFixture/end(opening:)``.
struct MeteredToolLoopSessionFixture: SessionDirectoryFixture {
    /// The vended session a test drives its answer on.
    let session: any RoutedSession

    /// The tool every call but the last asks for.
    let tool: MarkerEmittingTool

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into. ``SessionDirectoryFixture/end(opening:)``
    /// removes it.
    let directory: URL

    /// Builds a router, resolves a profile at `context`, and vends a session
    /// over a model that plays out `calls`.
    ///
    /// The run clock of the router is the clock of a ``MeteredPaceClock``,
    /// and the pass observer of the session is bound to that pace clock. So
    /// a paced call moves the time that the session reads, with no real wait.
    ///
    /// - Parameters:
    ///   - calls: The usage of each generation call, in call order.
    ///   - context: The working context the profile resolves at.
    ///   - budget: The auto-compaction opt-in of the session, or `nil` (the
    ///     default) for manual compaction only.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws. Before it throws, it
    ///   removes the temp directory.
    static func make(
        calls: [MeteredGenerationCall],
        context: Int,
        budget: TokenBudget? = nil,
        tempDirPrefix: String,
        tracer: (any Tracer)? = nil
    ) async throws -> MeteredToolLoopSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let tool = MarkerEmittingTool()
        let pace = MeteredPaceClock()
        let container = LiveBackendContainer(model: MeteredToolLoopLanguageModel(calls: calls, pace: pace))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            tracer: tracer)
        await router.useRunClock(pace.clock)
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await router.resolve(
                profile: RouterTestFixtures.profile(context: context), reporting: ResolutionProgress())
        }
        let session = profile.standard.makeSession(tools: [tool], budget: budget)
        if let actor = session as? RoutedSessionActor {
            pace.bind(actor.generationPassObserver)
        }
        return MeteredToolLoopSessionFixture(
            session: session,
            tool: tool,
            recorder: recorder,
            directory: directory)
    }
}
