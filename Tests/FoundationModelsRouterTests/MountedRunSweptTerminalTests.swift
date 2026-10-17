import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Tests what ``ToolContext/mount(_:op:as:postingTo:)``'s caller-supplied sink
/// does NOT carry. It also tests which correlation the journal keeps instead.
///
/// ``RoutedSession/close()`` sweeps a background run that is still tracked.
/// The sweep is a RUN PLANE operation. `RunPlane.sweep()` builds that run's
/// terminal event itself. `close()` then sends it to the journal. The run does
/// not post that event, so the caller's sink never receives it. This suite
/// tests that exception, so the doc comment is not its only record.
///
/// The sweep does not always build the terminal. It first runs the run's
/// canceler, and that call suspends the run plane. A run that settles in that
/// window keeps its own natural terminal, and that terminal did reach the sink.
/// The two tests below hold that window shut and then open.
///
/// The import is `@testable` for two reasons. The mount site under test is
/// reached from a running tool's own ``ToolContext``, and nothing public builds
/// one. The recorder this suite reads the journal from is also internal to the
/// router. The events themselves come off the public
/// `TranscriptEvent.operationEvents`, which is the expression a consumer
/// writes.
@Suite(
    "ToolContext.mount(postingTo:): a terminal the run plane builds reaches the journal, never the caller's sink"
)
struct MountedRunSweptTerminalTests {
    // MARK: - Vocabulary

    /// This suite builds every fixture directory with this prefix. A leaked
    /// directory then names this suite as its owner.
    private static let tempDirPrefix = "MountedRunSweptTerminalTests"

    /// The `tool` stamp the mounting context carries. Distinct from the mounted
    /// tool's own name, so an event's origin is legible in a failure message.
    private static let mountingToolStamp = "mounting_host"

    /// The `"verb noun"` op stamp the mounting context carries.
    private static let mountingOpStamp = "mount tool"

    /// The `value` argument the mounted call is made with.
    private static let callArgument = "swept"

    // MARK: - Tools

    /// Waits on a gate. Supplies a canceler that opens that gate and then waits
    /// for this run to settle.
    ///
    /// `RunPlane.sweep()` runs this canceler, and that call suspends the
    /// run plane. The canceler opens the gate, so the run's body finishes inside
    /// that window. The canceler returns only after the run plane retained the
    /// run's own natural terminal. The sweep therefore returns that natural
    /// terminal, and builds none of its own.
    private struct SettlesInsideCancelerTool: Tool, BackgroundTool {
        let name = "settles_inside_canceler_tool"
        let description = "settles while the sweep runs its canceler"

        /// The gate the body waits on and the canceler opens.
        let gate: RunLatch

        /// The run plane the canceler waits on for this run's settlement.
        let runPlane: RunPlane

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "settled: \(arguments.value)"
        }

        func canceler(
            forCompletionToken completionToken: String
        ) -> (@Sendable () async -> OperationOutcome)? {
            { [gate, runPlane] in
                await gate.open()
                _ = await runPlane.wait(completionToken: completionToken, seconds: nil)
                return .cancelled
            }
        }
    }

    // MARK: - Harness

    /// Vends a real ``RoutedSession`` over a stub container that is never
    /// driven, recording through `recorder`.
    ///
    /// The container is never driven because this suite runs no answer at all.
    /// The suite needs the session only for its run plane, its outbox, and its
    /// `close()`.
    ///
    /// - Parameter recorder: The recorder the vended session journals through.
    /// - Returns: The vended session and the temp directory to clean up.
    /// - Throws: Whatever profile resolution throws.
    private static func makeSession(
        recorder: any TranscriptRecorder
    ) async throws -> (session: any RoutedSession, directory: URL) {
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
        return (profile.standard.makeSession(), directory)
    }

    /// Builds the context a binder mounts from. That context is one run's
    /// identity over `session`'s own run plane and outbox.
    ///
    /// This suite builds the context by hand, and it does so deliberately. A
    /// real mounting context comes from a running tool inside a submission, and a
    /// submission cannot serve this suite. The run-plane drain in
    /// `RoutedSessionActor.respond(to:maxTokens:)` waits for every tracked
    /// background run to settle. A run held open past its answer would stall
    /// that call, rather than survive to `close()`. What `mount` reads off a
    /// context is the session identity and the session run plane. Both are this
    /// session's own here.
    ///
    /// - Parameter session: The session the mounted run is tracked on.
    /// - Returns: The mounting context.
    private static func mountingContext(on session: any RoutedSession) -> ToolContext {
        ToolContext(
            sessionID: session.id,
            runPlane: session.runPlane,
            sink: session.outbox,
            tool: mountingToolStamp,
            op: mountingOpStamp,
            completionToken: RunPlane.makeCompletionToken(),
            isCancelled: { false },
            // Each run of this suite continues past its call, so a settle
            // period of `0` gives the pending envelope at once.
            inlineSettleGrace: 0
        )
    }

    // MARK: - The terminal the run plane builds

    @Test("a background run swept by close() reaches the journal under its own token, and the terminal the run plane built never reaches the caller's sink")
    func builtTerminalReachesTheJournalAndNotTheCallerSink() async throws {
        let recorder = SignallingTranscriptRecorder()
        let (session, directory) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sink = MountFixtures.RecordingSink()
        let gate = RunLatch()
        defer {
            await gate.open()
            await session.close()
        }
        let mounted = Self.mountingContext(on: session).mount(
            MountFixtures.GatedTool(gate: gate),
            as: ToolMount(mode: .background, timeout: nil),
            postingTo: sink)

        // The call returns its envelope at once. The body continues behind it,
        // held on the shut gate. The run is therefore still tracked when the
        // session closes, and it has posted no terminal of its own.
        let rendered = try await mounted.call(
            arguments: MountArguments(value: Self.callArgument))
        let token = try MountFixtures.decodeEnvelope(rendered).completionToken

        // The close sweeps the run and journals the terminal of the sweep. Then
        // it waits for the body of the run, which the shut gate holds, so the
        // close runs in a task of its own until the test opens the gate.
        let closing = Task { await session.close() }
        try await recorder.changes.wait(until: {
            await recorder.events.flatMap(\.operationEvents).contains { $0.kind == .completed }
        })

        let atClose = await sink.events

        // The launch's own progress event proves the sink really was this run's
        // upstream. It also proves the sink carried the run's OWN correlation.
        // Without it, the absence of a terminal below would prove nothing.
        #expect(atClose.contains { $0.kind == .progress && $0.correlationID == token })

        // Here is the documented exception. The run never posted the terminal
        // the run plane built, so the caller's sink holds no terminal at all.
        #expect(!atClose.contains { $0.kind == .completed })

        // The journal is where a reader finds that terminal. It carries the
        // MOUNTED run's own token, and the outcome the canceler reported. The
        // count assertion cannot catch a doubled sweep, because the journal
        // admits one terminal for each correlation. It does catch a terminal
        // on any other correlation. This sink forwards nowhere, so the sweep
        // is the journal's only source here.
        let journaled = await recorder.events.flatMap(\.operationEvents)
        let terminals = journaled.filter { $0.kind == .completed }
        #expect(terminals.count == 1)
        #expect(terminals.first?.correlationID == token)
        #expect(terminals.first?.outcome == .cancelled)

        // Here is the other half of the matrix. Nothing the run POSTED reached
        // the journal. Under this overload `sink` is the run's whole upstream,
        // and this sink forwards nowhere.
        #expect(!journaled.contains { $0.kind == .progress })

        // Open the gate so the held body resumes. A shut gate would leak its
        // suspended continuation. The canceler of a `RunKind.swiftTask` run
        // only requests a stop, so the run finishes after the sweep. It then
        // posts a terminal of its OWN, on the same correlation. That terminal
        // carries an outcome the journal never saw.
        await gate.open()
        // The close returns only after the body of the run ended.
        await closing.value
        try await sink.changes.wait(until: { await sink.events.contains { $0.kind == .completed } })
        let ownTerminal = try #require(await sink.events.first { $0.kind == .completed })
        #expect(ownTerminal.correlationID == token)
        #expect(ownTerminal.outcome == .succeeded)
    }

    // MARK: - The natural terminal the sweep returns instead

    @Test("a run that settles inside the sweep's canceler window posts its own terminal to the caller's sink, and close() journals that same terminal")
    func naturalTerminalReachesTheSinkAndTheJournal() async throws {
        let recorder = SignallingTranscriptRecorder()
        let (session, directory) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }
        defer { await session.close() }

        let sink = MountFixtures.RecordingSink()
        let mounted = Self.mountingContext(on: session).mount(
            SettlesInsideCancelerTool(gate: RunLatch(), runPlane: session.runPlane),
            as: ToolMount(mode: .background, timeout: nil),
            postingTo: sink)

        let rendered = try await mounted.call(
            arguments: MountArguments(value: Self.callArgument))
        let token = try MountFixtures.decodeEnvelope(rendered).completionToken

        // The canceler opens the gate and waits, so the run settles while the
        // sweep is suspended on that canceler. The sweep then finds the run's
        // own natural terminal and returns it, and builds nothing.
        await session.close()

        // The run posted that terminal itself, so the caller's sink holds it.
        // This is the case the "never reaches the sink" claim excludes. These
        // three lines hold whatever the sweep does. A run posts its terminal
        // upstream before it settles, and the first test covers that already.
        let posted = try #require(await sink.events.first { $0.kind == .completed })
        #expect(posted.correlationID == token)
        #expect(posted.outcome == .succeeded)

        // `close()` journals the very same event. This session ran no answer, so
        // the journal and the settlement observer of the run plane attach only after
        // the sweep, and the sweep's write is the one write here. A session
        // that ran an answer would journal the natural terminal through the
        // forward of the run plane first, and the sweep's write would be refused. The
        // outcome assertion below is the one line this test adds. A sweep that
        // built a terminal instead would journal `.cancelled`, the outcome the
        // canceler reported. Keep that line. The count assertion cannot catch a
        // doubled write, because the journal admits one terminal for each
        // correlation.
        let journaled = await recorder.events.flatMap(\.operationEvents)
        let terminals = journaled.filter { $0.kind == .completed }
        #expect(terminals.count == 1)
        #expect(terminals.first?.correlationID == token)
        #expect(terminals.first?.outcome == .succeeded)
    }
}
