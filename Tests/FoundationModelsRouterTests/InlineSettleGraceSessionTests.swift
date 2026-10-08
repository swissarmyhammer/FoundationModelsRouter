import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Tests the settle period of a session, ``SessionConfiguration/inlineSettleGrace``.
///
/// A background call waits for its own run up to the settle period. A run
/// that ends in that time answers with its own output, and its result is no
/// mail. A run that continues answers with a pending envelope, and its result
/// arrives later as mail, one time.
///
/// A scripted backend calls the background tool of the session in its first
/// answer, and a ``RunLatch`` holds the run. No assertion reads a clock: each
/// wait reads a state until it holds, and the `.timeLimit` of the suite ends
/// a wait for a state that never comes.
@Suite("The settle period of a session decides between the own output and a pending envelope", .timeLimit(.minutes(1)))
struct InlineSettleGraceSessionTests {
    // MARK: - Fixtures

    /// A background tool that states no settle period of its own, so each
    /// call waits for the settle period of the session. Its body waits for
    /// its gate, then returns ``InlineSettleGraceSessionTests/runOutput``.
    struct HostGraceBackgroundTool: Tool, BackgroundTool {
        let name = "host_grace_job"
        let description = "test-only background tool that waits for the settle period of its session"

        /// The latch the body of the run waits on.
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            await gate.waitUntilOpen()
            return InlineSettleGraceSessionTests.runOutput
        }
    }

    /// One session over a ``BackgroundingBackend``, with what a test reads.
    struct Fixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: BackgroundingBackend

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The output of the run of ``HostGraceBackgroundTool``.
    static let runOutput = "the job is done"

    /// The prompt of the caller message that starts the run.
    private static let jobPrompt = "run the job"

    /// A settle period much shorter than a run that waits for its gate until
    /// the call answered.
    private static let shortGrace: TimeInterval = 0.05

    // MARK: - Helpers

    /// Makes a session with one ``HostGraceBackgroundTool`` and the settle
    /// period `grace`.
    ///
    /// - Parameters:
    ///   - gate: The gate of the run of the tool.
    ///   - grace: The ``SessionConfiguration/inlineSettleGrace`` of the
    ///     session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(gate: RunLatch, grace: TimeInterval) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "InlineSettleGraceSessionTests")
        let container = BackgroundingLLMContainer()
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory)
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [HostGraceBackgroundTool(gate: gate)], inlineSettleGrace: grace))
        let backend = try #require(container.lastBackend)
        return Fixture(session: session, backend: backend, router: router, directory: directory)
    }

    /// Ends the fixture: closes the session and removes the directory.
    ///
    /// - Parameter fixture: The fixture to end.
    private static func end(_ fixture: Fixture) async {
        await fixture.session.close()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.router) {}
    }

    // MARK: - The setting

    @Test("a session configuration that names no settle period carries the default of Extras")
    func theConfigurationCarriesTheDefault() {
        #expect(SessionConfiguration().inlineSettleGrace == ToolMount.defaultInlineSettleGrace)
    }

    @Test("the sidecar form of a configuration keeps the settle period")
    func thePersistableFormKeepsTheGrace() throws {
        let persistable = SessionConfiguration(inlineSettleGrace: Self.shortGrace).persistable
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONEncoder().encode(persistable))
        #expect(decoded.inlineSettleGrace == Self.shortGrace)
    }

    @Test("a sidecar written before the settle period existed decodes with no value, which a restore reads as the default")
    func anOldSidecarDecodesWithNoGrace() throws {
        let encoded = try JSONEncoder().encode(SessionConfiguration().persistable)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "inlineSettleGrace")
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.inlineSettleGrace == nil)
    }

    @Test("a negative settle period acts as zero on the session")
    func aNegativeGraceActsAsZero() async throws {
        let fixture = try await Self.makeFixture(gate: RunLatch(), grace: -1)
        let actor = try #require(fixture.session as? RoutedSessionActor)
        #expect(actor.inlineSettleGrace == 0)
        await Self.end(fixture)
    }

    // MARK: - A run that continues past the settle period

    @Test("a run longer than the settle period gives a pending envelope, and its result arrives later as mail one time")
    @MainActor
    func aLongRunGivesAPendingEnvelopeAndOneMail() async throws {
        let gate = RunLatch()
        let fixture = try await Self.makeFixture(gate: gate, grace: Self.shortGrace)

        // The gate stays closed until the call answered, so the run continues
        // past the settle period.
        let answer = try await fixture.session.respond(to: Self.jobPrompt)
        let envelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: answer))
        #expect(envelope.pending)
        #expect(fixture.backend.toolOutputs == [answer])

        await gate.open()
        let outcome = await fixture.session.mailbox.wait(completionToken: envelope.completionToken, seconds: nil)
        guard case .settled(let terminal) = outcome else {
            Issue.record("expected run \(envelope.completionToken) to settle, got \(outcome)")
            await Self.end(fixture)
            return
        }
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == Self.runOutput)

        // The terminal is mail: it starts one more answer by itself, and its
        // line reaches the model one time over every prompt.
        try await BoundedWait.awaitPrompts(2, in: { fixture.backend.receivedPrompts })
        #expect(await BoundedWait.pumpStops(on: fixture.session))
        let prompts = fixture.backend.receivedPrompts
        #expect(prompts.count == 2)
        #expect(prompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
        let line = OperationEventSegment.renderedLine(for: terminal)
        #expect(prompts.joined(separator: "\n").components(separatedBy: line).count - 1 == 1)
        #expect(await fixture.session.outbox.pending().events.isEmpty)
        await Self.end(fixture)
    }

    // MARK: - A run that ends inside the settle period

    @Test("a run shorter than the settle period gives the own output of the tool in band, and no mail")
    @MainActor
    func aShortRunGivesItsOwnOutputAndNoMail() async throws {
        let gate = RunLatch()
        // The gate is open before the call, so the run ends at once, far
        // inside the settle period. The wait ends when the run settles, not
        // at the settle period.
        await gate.open()
        let fixture = try await Self.makeFixture(gate: gate, grace: MountFixtures.generousInterval)

        let answer = try await fixture.session.respond(to: Self.jobPrompt)

        #expect(answer == Self.runOutput)
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: answer) == nil)
        #expect(fixture.backend.toolOutputs == [Self.runOutput])
        // The run settled, and its staged events were withdrawn: no mail
        // waits, and no mail starts one more answer.
        #expect(await fixture.session.mailbox.backgroundRuns().isEmpty)
        #expect(await BoundedWait.pumpStops(on: fixture.session))
        #expect(fixture.backend.receivedPrompts == [Self.jobPrompt])
        #expect(await fixture.session.outbox.pending().events.isEmpty)
        await Self.end(fixture)
    }
}
