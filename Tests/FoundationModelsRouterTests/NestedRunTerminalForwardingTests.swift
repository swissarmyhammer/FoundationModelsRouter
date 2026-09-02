import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Tests that a background run mounted inside another run's ``ToolContext``
/// through ``ToolContext/mount(_:op:as:)`` still reports its own settlement.
///
/// That overload re-stamps each event the nested run posts with the mounting
/// run's token. The mounting run of a `String`-output tool posts through its
/// own `RunEventFunnel`, and that funnel admits one `.completed` and drops
/// every later one. A background mount returns its envelope at once, so the
/// mounting run settles first, and the funnel then drops the nested run's
/// re-stamped terminal. Before this fix, only `close()` wrote that run's
/// ending. Now the mailbox forwards the run's own terminal to the journal
/// under the run's own token at settlement, so ``SessionEvent/runSettled(_:)``
/// fires for a nested run without `close()`.
///
/// The import is `@testable` because the runner, the mailbox, and the outbox
/// the suite wires by hand are internal to the router. The journal is read
/// through the public `TranscriptEvent.operationEvents`.
///
/// Each test declares `.timeLimit` because a gate holds each nested run. A
/// regression that stopped a settlement from reaching the stream would suspend
/// the test forever, and the whole `swift test` run with it.
@Suite("Nested run terminal forwarding: a mounted run's own settlement reaches the journal and the session stream")
struct NestedRunTerminalForwardingTests {
    // MARK: - Vocabulary

    /// This suite builds every fixture directory with this prefix.
    private static let tempDirPrefix = "NestedRunTerminalForwardingTests"

    /// The `value` argument every mounted call is made with.
    private static let callArgument = "nested"

    /// The prompt of the one stub turn that attaches the session's journal.
    private static let attachingPrompt = "attach the journal"

    /// The mount every background fixture in this suite is mounted as.
    private static let backgroundMount = ToolMount(mode: .background, timeout: nil)

    // MARK: - Tools

    /// Mounts a ``MountFixtures/GatedTool`` on its own run's context through the
    /// re-stamping overload, calls it, and returns the nested envelope.
    ///
    /// The body returns at once, so the run that hosts it settles before the
    /// nested run does. Its terminal detail is the nested envelope, which is
    /// how a test reads the nested run's token.
    private struct NestingTool: Tool {
        let name = "nesting_tool"
        let description = "mounts a gated tool in the background on its own context"

        /// The output when no context is bound. A test never sees it.
        static let noContextOutput = "no context"

        /// The gate the nested run's body waits on.
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            guard let context = ToolContext.current else { return Self.noContextOutput }
            let mounted = context.mount(
                MountFixtures.GatedTool(gate: gate), as: NestedRunTerminalForwardingTests.backgroundMount)
            return try await mounted.call(arguments: arguments)
        }
    }

    // MARK: - Harness

    /// Collects every ``SessionEvent/runSettled(_:)`` a session-wide
    /// subscription delivered, so a test can wait for one by token.
    private actor SettledRunLog {
        /// Every settled terminal delivered so far, in delivery order.
        private(set) var terminals: [OperationEvent] = []

        /// Appends one delivered terminal.
        func record(_ terminal: OperationEvent) {
            terminals.append(terminal)
        }

        /// The delivered terminals whose `correlationID` is `token`.
        func terminals(for token: String) -> [OperationEvent] {
            terminals.filter { $0.correlationID == token }
        }
    }

    /// One nested run that was launched and then settled.
    private struct SettledNesting {
        /// The token of the run that mounted the nested run.
        let outerToken: String

        /// The nested run's own token.
        let nestedToken: String

        /// The nested run's terminal, as `wait` returned it.
        let nestedTerminal: OperationEvent
    }

    /// One test's session, with a live subscription to its event stream.
    private struct Observation {
        /// The session under test.
        let session: RoutedSession

        /// The temp directory to clean up.
        let directory: URL

        /// The recorder the session journals through.
        let recorder: InMemoryRecorder

        /// The settled terminals the subscription delivered.
        let settledRuns: SettledRunLog

        /// The task that drains the subscription into ``settledRuns``.
        let collecting: Task<Void, Never>

        /// Waits, bounded, for one settled terminal under `token`.
        ///
        /// - Parameter token: The run's completion token.
        func awaitSettlement(of token: String) async {
            #expect(
                await BoundedWait.conditionReached("runSettled for \(token) on streamSessionEvents()") {
                    await settledRuns.terminals(for: token).count == 1
                })
        }

        /// Closes the session, which ends the subscription, then waits for
        /// the collector to drain it.
        func close() async {
            await session.close()
            await collecting.value
        }
    }

    /// Vends a real ``RoutedSession`` over a stub backend, runs one turn so
    /// the session attaches its journal, and subscribes to its event stream.
    ///
    /// The turn matters. A run can only be backgrounded from inside a turn,
    /// and the journal attaches at the top of the first one. Without it the
    /// mailbox would forward into no journal at all.
    ///
    /// - Returns: The observation to drive and then close.
    /// - Throws: Whatever profile resolution or the stub turn throws.
    private static func observe() async throws -> Observation {
        let recorder = InMemoryRecorder()
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(),
                dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        _ = try await session.respond(to: attachingPrompt)

        let settledRuns = SettledRunLog()
        let stream = await session.streamSessionEvents()
        let collecting = Task {
            for await event in stream {
                if case .runSettled(let terminal) = event {
                    await settledRuns.record(terminal)
                }
            }
        }
        return Observation(
            session: session,
            directory: directory,
            recorder: recorder,
            settledRuns: settledRuns,
            collecting: collecting
        )
    }

    /// Mounts `tool` as a top-level background run on `session`'s own mailbox
    /// and outbox, exactly as a session-registered tool is mounted.
    ///
    /// - Parameters:
    ///   - tool: The tool to run in the background.
    ///   - session: The session that tracks and journals the run.
    /// - Returns: The mounted runner.
    private static func backgroundRunner(
        wrapping tool: any Tool<MountArguments, String>, on session: RoutedSession
    ) -> BackgroundToolRunner<MountArguments> {
        BackgroundToolRunner(
            wrapping: tool,
            sessionID: session.id,
            mailbox: session.mailbox,
            sink: session.outbox,
            timeout: nil
        )
    }

    /// Launches a ``NestingTool`` run on `session`, lets the outer run settle,
    /// then opens the gate so the nested run settles too.
    ///
    /// The outer run settles first because its body returns the nested
    /// envelope at once. That is the branch in which the outer funnel drops
    /// the nested run's re-stamped terminal.
    ///
    /// - Parameter session: The session both runs are tracked on.
    /// - Returns: The tokens and the nested run's terminal.
    /// - Throws: When a run does not settle inside the mailbox wait.
    private static func settleNestedRun(on session: RoutedSession) async throws -> SettledNesting {
        let gate = RunLatch()
        let runner = backgroundRunner(wrapping: NestingTool(gate: gate), on: session)
        let rendered = try await runner.call(arguments: MountArguments(value: callArgument))
        let outerToken = try MountFixtures.decodeEnvelope(rendered).completionToken

        let outerTerminal = try await MountFixtures.settledTerminal(of: outerToken, in: session.mailbox)
        let nestedToken = try MountFixtures.decodeEnvelope(outerTerminal.detail).completionToken
        #expect(nestedToken != outerToken)

        await gate.open()
        let nestedTerminal = try await MountFixtures.settledTerminal(of: nestedToken, in: session.mailbox)
        return SettledNesting(outerToken: outerToken, nestedToken: nestedToken, nestedTerminal: nestedTerminal)
    }

    /// The journaled terminals under `token`, read through the public
    /// `TranscriptEvent.operationEvents`.
    ///
    /// - Parameters:
    ///   - recorder: The recorder the session journals through.
    ///   - token: The run's completion token.
    /// - Returns: Every `.completed` event under `token`, in journal order.
    private static func journaledTerminals(
        in recorder: InMemoryRecorder, for token: String
    ) async -> [OperationEvent] {
        await recorder.events.flatMap(\.operationEvents).filter {
            $0.kind == .completed && $0.correlationID == token
        }
    }

    // MARK: - A nested run settles on the session stream

    @Test(
        "a run mounted through mount(_:op:as:) produces exactly one runSettled under its own token, without close()",
        .timeLimit(.minutes(1))
    )
    func nestedRunSettlementReachesTheSessionStream() async throws {
        let observation = try await Self.observe()
        defer { try? FileManager.default.removeItem(at: observation.directory) }

        let nesting = try await Self.settleNestedRun(on: observation.session)
        await observation.awaitSettlement(of: nesting.nestedToken)

        // The stream carries the run's real outcome, and the very event `wait`
        // returned. The outer funnel dropped the re-stamped copy, so this
        // event can only have come through the mailbox.
        let delivered = await observation.settledRuns.terminals(for: nesting.nestedToken)
        #expect(delivered == [nesting.nestedTerminal])
        #expect(delivered.first?.outcome == .succeeded)
        #expect(delivered.first?.detail == "gated: \(Self.callArgument)")

        // The stream ends with the session, so the count is final.
        await observation.close()
        #expect(await observation.settledRuns.terminals(for: nesting.nestedToken).count == 1)
    }

    // MARK: - The transcript holds the nested terminal once

    @Test(
        "the transcript holds exactly one .completed event under the nested run's own token",
        .timeLimit(.minutes(1))
    )
    func nestedRunTerminalIsJournaledOnce() async throws {
        let observation = try await Self.observe()
        defer { try? FileManager.default.removeItem(at: observation.directory) }

        let nesting = try await Self.settleNestedRun(on: observation.session)
        await observation.awaitSettlement(of: nesting.nestedToken)

        // The journal appends before it delivers `runSettled`, so the write is
        // in the recorder by the time the stream carried the event.
        let journaled = await Self.journaledTerminals(in: observation.recorder, for: nesting.nestedToken)
        #expect(journaled == [nesting.nestedTerminal])

        await observation.close()
    }

    // MARK: - A top-level run is unchanged

    @Test(
        "a top-level background run still produces exactly one runSettled and exactly one journaled terminal",
        .timeLimit(.minutes(1))
    )
    func topLevelRunStillSettlesOnce() async throws {
        let observation = try await Self.observe()
        defer { try? FileManager.default.removeItem(at: observation.directory) }

        let gate = RunLatch()
        let runner = Self.backgroundRunner(wrapping: MountFixtures.GatedTool(gate: gate), on: observation.session)
        let rendered = try await runner.call(arguments: MountArguments(value: Self.callArgument))
        let token = try MountFixtures.decodeEnvelope(rendered).completionToken

        await gate.open()
        let terminal = try await MountFixtures.settledTerminal(of: token, in: observation.session.mailbox)
        await observation.awaitSettlement(of: token)

        // The funnel journaled the terminal before the mailbox forwarded it,
        // and the journal refused the second write. One event on each side.
        await observation.close()
        #expect(await observation.settledRuns.terminals(for: token) == [terminal])
        #expect(await Self.journaledTerminals(in: observation.recorder, for: token) == [terminal])
    }

    // MARK: - close() adds nothing after a natural settlement

    @Test(
        "close() after a natural settlement journals no second terminal for that run",
        .timeLimit(.minutes(1))
    )
    func closeAfterNaturalSettlementJournalsNoSecondTerminal() async throws {
        let observation = try await Self.observe()
        defer { try? FileManager.default.removeItem(at: observation.directory) }

        let nesting = try await Self.settleNestedRun(on: observation.session)
        await observation.awaitSettlement(of: nesting.nestedToken)

        await observation.close()

        // The sweep found nothing tracked, and both correlations were already
        // claimed, so the journal still holds one terminal for each run.
        #expect(await Self.journaledTerminals(in: observation.recorder, for: nesting.nestedToken).count == 1)
        #expect(await Self.journaledTerminals(in: observation.recorder, for: nesting.outerToken).count == 1)
    }
}
