import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^mq1js23: a `.progress` event of a run goes live to the host
/// as ``SessionEvent/runProgress(_:)``, its plan (`OperationEvent.plan`) never
/// goes into model input, and a progress event that has a plan goes to the
/// transcript at once.
///
/// Everything runs against the scripted backend of ``SessionMessagePumpTests``
/// and an ``InMemoryRecorder``, so the suite needs no network and no GPU.
@Suite("The live delivery of run progress and the plan of a run")
struct RunProgressDeliveryTests {
    /// The scripted backend of each test.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// One session over a ``Backend``, with what a test reads.
    struct Fixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on. It keeps each prompt it gets.
        let backend: Backend

        /// The recorder of the session.
        let recorder: InMemoryRecorder

        /// The feed of the session's events.
        let events: SessionEventLog

        /// The task that drains ``events``.
        let drain: Task<Void, Never>

        /// The profile that keeps the models of the session resident.
        let profile: LanguageModelProfile

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The prompt of the first caller message. Its answer attaches the outbox
    /// of the session to the journal, so later events are journaled.
    private static let firstPrompt = "start the plan"

    /// The prompt of the caller message after the events.
    private static let nextPrompt = "how is the plan"

    // MARK: - Fixtures

    /// Makes a session over a new backend, answers ``firstPrompt``, and
    /// watches the events of the session.
    ///
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile or the first answer throws.
    private static func makeFixture() async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "RunProgressDeliveryTests")
        let backend = Backend(script: [:])
        let recorder = InMemoryRecorder()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory, recorder: recorder,
            loader: StubModelLoader(
                container: SessionMessagePumpTests.PumpProbeContainer(backend: backend),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        let (events, drain) = await SessionEventLog.watch(session)
        _ = try await session.respond(to: firstPrompt)
        return Fixture(
            session: session, backend: backend, recorder: recorder, events: events, drain: drain,
            profile: profile, directory: directory)
    }

    /// Ends the fixture: stops the event drain and removes the directory.
    ///
    /// - Parameter fixture: The fixture to end.
    private static func tearDown(_ fixture: Fixture) {
        fixture.drain.cancel()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.profile) {}
    }

    /// Posts each of `events` to the outbox of the session, in order.
    ///
    /// - Parameters:
    ///   - events: The events to post.
    ///   - fixture: The fixture whose session gets the events.
    private static func post(_ events: [OperationEvent], to fixture: Fixture) async {
        for event in events {
            await fixture.session.outbox.post(event: event)
        }
    }

    /// The operation events of each journaled `.toolOutput` row, in recorded
    /// order.
    ///
    /// - Parameter fixture: The fixture whose recorder to read.
    /// - Returns: One array of events for each row.
    private static func journaledRows(of fixture: Fixture) async -> [[OperationEvent]] {
        await fixture.recorder.events.filter { $0.kind == .toolOutput }.map(\.operationEvents)
    }

    /// The prompt that `entry` holds.
    ///
    /// - Parameter entry: A transcript entry.
    /// - Returns: The prompt, or `nil` when `entry` is no `.prompt` entry.
    private static func prompt(of entry: Transcript.Entry) -> Transcript.Prompt? {
        guard case .prompt(let prompt) = entry else { return nil }
        return prompt
    }

    /// The structured segment that `segment` holds.
    ///
    /// - Parameter segment: A transcript segment.
    /// - Returns: The structured segment, or `nil` when `segment` is no
    ///   `.structure` segment.
    private static func structure(of segment: Transcript.Segment) -> Transcript.StructuredSegment? {
        guard case .structure(let structure) = segment else { return nil }
        return structure
    }

    // MARK: - Live delivery

    @Test("each progress event of a run arrives on streamSessionEvents() as runProgress, in post order")
    func eachProgressEventArrivesLive() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        // The second and the third event go into the open progress row, which
        // writes nothing now. They must still go live.
        let posted = [
            PlanFixtures.textProgress("first output"),
            PlanFixtures.textProgress("second output"),
            PlanFixtures.textProgress("third output"),
        ]

        await Self.post(posted, to: fixture)

        #expect(
            await BoundedWait.conditionReached("each progress event on the session feed") {
                await fixture.events.runProgress == posted
            })
    }

    @Test("the runProgress event of a plan carries the whole plan to the host")
    func aPlanArrivesLiveWithItsPlan() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let planEvent = PlanFixtures.planProgress()

        await Self.post([planEvent], to: fixture)

        #expect(
            await BoundedWait.conditionReached("the plan event on the session feed") {
                await fixture.events.runProgress.map(\.plan) == [PlanFixtures.plan()]
            })
    }

    // MARK: - The plan stays out of the model input

    @Test("the rendered line of a plan event holds its detail and no plan entry")
    func theRenderedLineHoldsNoPlan() {
        let planEvent = PlanFixtures.planProgress()
        let line = OperationEventSegment.renderedLine(for: planEvent)

        #expect(line == OperationEventSegment.renderedLine(for: PlanFixtures.textProgress(PlanFixtures.planDetail)))
        #expect(PlanFixtures.holdsPlanText(line) == false)
    }

    @Test("removing the plans of a prompt entry keeps its id, its text and each event, with no plan")
    func removingThePlansOfAPromptKeepsEverythingElse() throws {
        let planEvent = PlanFixtures.planProgress()
        let eventSegment = OperationEventSegment(content: planEvent)
        let prompt = Transcript.Prompt(
            segments: [.text(Transcript.TextSegment(content: Self.nextPrompt)), eventSegment.transcriptSegment])

        let stripped = OperationEventSegment.removingPlans(from: .prompt(prompt))

        let strippedPrompt = try #require(Self.prompt(of: stripped))
        #expect(strippedPrompt.id == prompt.id)
        #expect(strippedPrompt.segments.first == prompt.segments.first)
        let structure = try #require(strippedPrompt.segments.last.flatMap(Self.structure(of:)))
        let strippedSegment = try #require(try OperationEventSegment(structuredSegment: structure))
        #expect(strippedSegment == eventSegment.withoutPlan)
        #expect(strippedSegment.content.plan == nil)
        #expect(strippedSegment.content.detail == planEvent.detail)
    }

    @Test("the prompt of the next answer carries the detail of a plan event and no plan entry")
    func theNextPromptHoldsNoPlan() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let planEvent = PlanFixtures.planProgress()
        await Self.post([planEvent], to: fixture)

        _ = try await fixture.session.respond(to: Self.nextPrompt)

        let prompt = try #require(fixture.backend.prompts.last)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: planEvent)))
        #expect(PlanFixtures.holdsPlanText(prompt) == false)
    }

    // MARK: - Durability

    @Test("a plan event goes to the transcript at once, and does not wait in the open progress row")
    func aPlanEventIsWrittenAtOnce() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let start = PlanFixtures.textProgress("first output")
        let merged = PlanFixtures.textProgress("second output")
        let planEvent = PlanFixtures.planProgress()

        // No close: the rows on the recorder are the rows that a stop of the
        // process keeps.
        await Self.post([start, merged, planEvent], to: fixture)

        #expect(await Self.journaledRows(of: fixture) == [[start], [merged], [planEvent]])
    }

    @Test("each plan event of one run goes to the transcript at once, also after a plan event")
    func consecutivePlanEventsAreEachWrittenAtOnce() async throws {
        let fixture = try await Self.makeFixture()
        defer { Self.tearDown(fixture) }
        let firstPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .inProgress))
        let secondPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .completed))

        await Self.post([firstPlan, secondPlan], to: fixture)

        #expect(await Self.journaledRows(of: fixture) == [[firstPlan], [secondPlan]])
    }
}

extension SessionEventLog {
    /// Every run progress event delivered so far, in delivery order.
    var runProgress: [OperationEvent] {
        events.compactMap { event in
            guard case .runProgress(let progress) = event else { return nil }
            return progress
        }
    }
}
