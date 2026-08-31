import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises what ``ToolContext/mount(_:op:as:postingTo:)``'s caller-supplied
/// sink does NOT carry, and which correlation the journal keeps instead.
///
/// A background run still tracked when ``RoutedSession/close()`` runs is swept.
/// The sweep is a MAILBOX operation: `SessionMailbox.sweep()` builds that run's
/// terminal event itself, and `close()` writes it straight to the journal. The
/// run never posts that event, so the caller's sink never sees it. This suite
/// holds the exception in place, rather than leaving the doc comment to
/// describe it alone.
///
/// The import is `@testable` for two reasons. The mount site under test is
/// reached from a running tool's own ``ToolContext``, and nothing public builds
/// one; and the recorder this suite reads the journal back off is internal to
/// the router. The events themselves come off the public
/// `TranscriptEvent.operationEvents`, which is the expression a consumer
/// writes.
///
/// `.timeLimit` because the mounted run is deliberately held on a gate. A
/// regression that stopped the sweep from settling that run would suspend the
/// suite forever and hang the whole `swift test` run, rather than failing the
/// test that caught it.
@Suite(
    "ToolContext.mount(postingTo:): a swept terminal reaches the journal, never the caller's sink",
    .timeLimit(.minutes(1))
)
struct MountedRunSweptTerminalTests {
    // MARK: - Vocabulary

    /// The temp-directory prefix every fixture in this suite is built with, so
    /// a leaked directory is attributable to this suite.
    private static let tempDirPrefix = "MountedRunSweptTerminalTests"

    /// The `tool` stamp the mounting context carries. Distinct from the mounted
    /// tool's own name, so an event's origin is legible in a failure message.
    private static let mountingToolStamp = "mounting_host"

    /// The `"verb noun"` op stamp the mounting context carries.
    private static let mountingOpStamp = "mount tool"

    /// The `value` argument the mounted call is made with.
    private static let callArgument = "swept"

    // MARK: - Harness

    /// Vends a real ``RoutedSession`` over a stub container that is never
    /// driven, recording through `recorder`.
    ///
    /// Never driven because this suite runs no turn at all: it needs the
    /// session only for its mailbox, its outbox, and its `close()`.
    ///
    /// - Parameter recorder: The recorder the vended session journals through.
    /// - Returns: The vended session and the temp directory to clean up.
    /// - Throws: Whatever profile resolution throws.
    private static func makeSession(
        recorder: any TranscriptRecorder
    ) async throws -> (session: RoutedSession, directory: URL) {
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

    /// The context a binder mounts from: one run's identity over `session`'s
    /// own mailbox and outbox.
    ///
    /// Hand-built deliberately. A real mounting context comes from a running
    /// tool inside a turn, and a turn cannot serve this suite: the run-plane
    /// drain in `RoutedSessionActor.respond(to:maxTokens:)` waits for every
    /// tracked background run to settle, so a run held open past its turn would
    /// stall that call rather than survive to `close()`. What `mount` reads off
    /// a context is the session identity and the session mailbox, and both are
    /// this session's own here.
    ///
    /// - Parameter session: The session the mounted run is tracked on.
    /// - Returns: The mounting context.
    private static func mountingContext(on session: RoutedSession) -> ToolContext {
        ToolContext(
            sessionID: session.id,
            mailbox: session.mailbox,
            sink: session.outbox,
            tool: mountingToolStamp,
            op: mountingOpStamp,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { false }
        )
    }

    // MARK: - The swept terminal

    @Test("a background run swept by close() reaches the journal under its own token, and its terminal never reaches the caller's sink")
    func sweptTerminalReachesTheJournalAndNotTheCallerSink() async throws {
        let recorder = InMemoryRecorder()
        let (session, directory) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sink = MountFixtures.RecordingSink()
        let gate = RunLatch()
        let mounted = Self.mountingContext(on: session).mount(
            MountFixtures.GatedTool(gate: gate),
            as: ToolMount(mode: .background, timeout: nil),
            postingTo: sink)

        // The call hands its envelope back at once and the body goes on behind
        // it, held on the shut gate — so the run is still tracked, and has
        // posted no terminal of its own, when the session closes.
        let rendered = try await mounted.call(
            arguments: MountArguments(value: Self.callArgument))
        let token = try MountFixtures.decodeEnvelope(rendered).completionToken

        await session.close()

        let atClose = await sink.events

        // The launch's own progress event proves the sink really was this run's
        // upstream, and that it carried the run's OWN correlation. Without it
        // the absence of a terminal below would prove nothing.
        #expect(atClose.contains { $0.kind == .progress && $0.correlationID == token })

        // The documented exception: the sweep's terminal never passed through
        // the run, so the caller's sink holds no terminal at all.
        #expect(!atClose.contains { $0.kind == .completed })

        // The journal is where that terminal is read, under the MOUNTED run's
        // own completion token, with the outcome the sweep's canceler reported.
        let journaled = await recorder.events.flatMap(\.operationEvents)
        let terminals = journaled.filter { $0.kind == .completed }
        #expect(terminals.count == 1)
        #expect(terminals.first?.correlationID == token)
        #expect(terminals.first?.outcome == .cancelled)

        // The other half of the matrix: nothing the run POSTED reached the
        // journal, because under this overload `sink` is the run's whole
        // upstream, and this sink forwards nowhere.
        #expect(!journaled.contains { $0.kind == .progress })

        // Open the gate so the held body resumes rather than leaking its
        // suspended continuation. Cancelling a `RunKind.swiftTask` run is
        // cooperative, so the run finishes after the sweep and posts a terminal
        // of its OWN — same correlation, and an outcome the journal never saw.
        await gate.open()
        let ownTerminal = try #require(
            await MountFixtures.poll {
                await sink.events.first { $0.kind == .completed }
            })
        #expect(ownTerminal.correlationID == token)
        #expect(ownTerminal.outcome == .succeeded)
    }
}
