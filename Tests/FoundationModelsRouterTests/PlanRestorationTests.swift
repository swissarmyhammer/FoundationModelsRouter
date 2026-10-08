import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^mq1js23 on the restore path: the journal keeps the plan of
/// a run (`OperationEvent.plan`) on disk, so the last plan of each plan id is
/// available for replay after a restore, and the transcript that a restore
/// gives to the model holds no plan.
///
/// A recorded session posts its events and is not closed, as a process that
/// stops does. A second router over the same recording root restores the
/// session, as a new process does. Everything runs against stubs, so the
/// suite needs no network and no GPU.
@Suite("The plan of a run across a restore")
struct PlanRestorationTests {
    // MARK: - Stub container

    /// Vends a plain ``StubSessionBackend`` for every session. A restored
    /// backend holds the transcript that the restore seeds it with.
    private struct BasicLLMContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: "stub response")
        }
    }

    // MARK: - Fixtures

    /// The prompt the recorded session answers. Its answer attaches the
    /// outbox of the session to the journal, so later events are journaled.
    private static let recordedPrompt = "start the plan"

    /// The text progress that starts the progress row of the run.
    private static let startOutput = PlanFixtures.textProgress("first output")

    /// The first plan of ``PlanFixtures/planID``. A later plan with the same
    /// id replaces it.
    private static let replacedPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .inProgress))

    /// The last plan of ``PlanFixtures/planID``.
    private static let lastPlan = PlanFixtures.planProgress(PlanFixtures.plan(firstStatus: .completed))

    /// The one plan of ``PlanFixtures/secondPlanID``.
    private static let otherPlan = PlanFixtures.planProgress(PlanFixtures.plan(id: PlanFixtures.secondPlanID))

    /// The events the recorded run posts, in post order. Each text progress
    /// after the start goes into the open progress row, which only memory
    /// holds, so the stop of the process loses it.
    private static let postedEvents = [
        startOutput,
        replacedPlan,
        PlanFixtures.textProgress("second output"),
        lastPlan,
        otherPlan,
        PlanFixtures.textProgress("third output"),
    ]

    /// One recorded session, restored by a second router over the same
    /// recording root.
    private struct Restoration {
        /// The restored session.
        let restored: RestoredSession

        /// The recording root that ``TranscriptTree/load(under:)`` reads.
        let routerDirectory: URL

        /// The profile that the restore ran against. It keeps the restored
        /// session alive.
        let resumingProfile: LanguageModelProfile
    }

    /// Records one session that posts ``postedEvents`` and is not closed,
    /// and restores it with a second router over the same recording root.
    ///
    /// - Parameters:
    ///   - cacheDir: The per-test cache directory.
    ///   - recordingsDir: The per-test durable transcripts root.
    /// - Returns: The restoration.
    /// - Throws: What the resolve, the answer or the restore throws.
    private static func recordAndRestore(cacheDir: URL, recordingsDir: URL) async throws -> Restoration {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let loader = StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension)
        let recordingRouter = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder, loader: loader)
        let recordingProfile = try await recordingRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let recorded = recordingProfile.standard.makeSession()
        _ = try await recorded.respond(to: recordedPrompt)
        for event in postedEvents {
            await recorded.outbox.post(event: event)
        }

        let resumingRouter = RouterTestFixtures.makeRouter(
            id: recordingRouter.id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder,
            loader: loader)
        let resumingProfile = try await resumingRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await resumingProfile.standard.restoreSession(id: recorded.id)
        return Restoration(
            restored: restored,
            routerDirectory: RouterTestFixtures.routerDirectory(
                routerId: recordingRouter.id, recordingsDir: recordingsDir),
            resumingProfile: resumingProfile)
    }

    /// Runs `body` over a new restoration in new temporary directories, and
    /// removes the directories after.
    ///
    /// - Parameter body: The checks of the test.
    /// - Throws: What the restoration or `body` throws.
    private static func withRestoration(_ body: (Restoration) async throws -> Void) async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "PlanRestorationTests-cache")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "PlanRestorationTests-recordings")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let restoration = try await recordAndRestore(cacheDir: cacheDir, recordingsDir: recordingsDir)
        try await body(restoration)
        withExtendedLifetime(restoration.resumingProfile) {}
    }

    /// The transcript that the restore seeded the backend of the restored
    /// session with: the transcript the model gets.
    ///
    /// - Parameter restoration: The restoration.
    /// - Returns: The entries of the seed transcript.
    /// - Throws: When the restored session is no ``RoutedSessionActor``.
    private static func seedEntries(of restoration: Restoration) async throws -> [Transcript.Entry] {
        let session = try #require(restoration.restored.session as? RoutedSessionActor)
        return await session.backend.transcriptEntries()
    }

    /// The text that a backend can send to the model for `entries`: the text
    /// of each text segment, and the JSON of each structured segment.
    ///
    /// - Parameter entries: The entries of a transcript.
    /// - Returns: The text of each segment, in order.
    private static func segmentTexts(of entries: [Transcript.Entry]) -> [String] {
        entries.flatMap(segments(of:)).compactMap { segment in
            if case .text(let text) = segment { return text.content }
            if case .structure(let structure) = segment { return structure.content.jsonString }
            return nil
        }
    }

    /// The segments of `entry`, or none for an entry that has no segments.
    ///
    /// - Parameter entry: A transcript entry.
    /// - Returns: The segments of the entry.
    private static func segments(of entry: Transcript.Entry) -> [Transcript.Segment] {
        switch entry {
        case .instructions(let instructions):
            return instructions.segments
        case .prompt(let prompt):
            return prompt.segments
        case .response(let response):
            return response.segments
        case .reasoning(let reasoning):
            return reasoning.segments
        case .toolOutput(let output):
            return output.segments
        case .toolCalls:
            return []
        @unknown default:
            return []
        }
    }

    /// The operation events that the structured segments of `entries` carry.
    ///
    /// - Parameter entries: The entries of a transcript.
    /// - Returns: The decoded events, in order.
    private static func operationEvents(in entries: [Transcript.Entry]) -> [OperationEvent] {
        entries.flatMap(segments(of:)).compactMap { segment in
            guard case .structure(let structure) = segment else { return nil }
            return (try? OperationEventSegment(structuredSegment: structure))??.content
        }
    }

    // MARK: - The last plan stays on disk

    @Test("after a restore, the recorded events of the session hold the last plan of each plan id")
    func theLastPlanOfEachIdIsOnDiskAfterARestore() async throws {
        try await Self.withRestoration { restoration in
            let tree = try TranscriptTree.load(under: restoration.routerDirectory)
            let events = try tree.events(forSession: restoration.restored.session.id)
            let plans = events.flatMap(\.operationEvents).compactMap(\.plan)

            let lastPlanByID = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            #expect(
                lastPlanByID == [
                    PlanFixtures.planID: Self.lastPlan.plan, PlanFixtures.secondPlanID: Self.otherPlan.plan,
                ])
            #expect(plans == [Self.replacedPlan, Self.lastPlan, Self.otherPlan].compactMap(\.plan))
        }
    }

    // MARK: - The plan stays out of the model input

    @Test("the transcript a restore gives to the model holds no plan entry")
    func theRestoredSeedHoldsNoPlan() async throws {
        try await Self.withRestoration { restoration in
            let texts = Self.segmentTexts(of: try await Self.seedEntries(of: restoration))

            #expect(texts.contains { $0.contains(PlanFixtures.planDetail) })
            #expect(texts.contains(where: PlanFixtures.holdsPlanText) == false)
        }
    }

    @Test("the transcript a restore gives to the model keeps each journaled plan event, with its detail and no plan")
    func theRestoredSeedKeepsEachPlanEventWithoutItsPlan() async throws {
        try await Self.withRestoration { restoration in
            let seeded = Self.operationEvents(in: try await Self.seedEntries(of: restoration))
            let planDetails = seeded.filter { $0.detail == PlanFixtures.planDetail }

            #expect(planDetails.count == [Self.replacedPlan, Self.lastPlan, Self.otherPlan].count)
            #expect(seeded.allSatisfy { $0.plan == nil })
        }
    }

    @Test("the lost terminal that a restore makes from a plan event carries its detail and no plan")
    func theLostTerminalOfAPlanRunHoldsNoPlan() async throws {
        try await Self.withRestoration { restoration in
            let pending = await restoration.restored.session.outbox.pending().events.map(\.event)

            let lost = try #require(pending.first { $0.outcome == .lost })
            #expect(lost.kind == .completed)
            #expect(lost.detail == PlanFixtures.planDetail)
            #expect(lost.plan == nil)
        }
    }
}
