import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^gg49g5e: a session restored from disk after a repetition stop gives
/// the model the render that the live session gave it after the stop, and the
/// same context counter. The recorded transcript keeps the full entry.
///
/// Each test drives a live session over a ``RepeatingReasoningModel`` that a
/// ``JSONLRecorder`` records to disk, then restores the recorded tree over a
/// second router that reads the same directory. No GPU is in the loop.
@Suite("A restored session keeps the repeated part of a stopped call out of its render")
struct RepetitionStopRestoreTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "RepetitionStopRestoreTests"

    /// The prompt of the answer that the live session stops.
    private static let prompt = "fix the failing test"

    /// The prompt of the first answer of the restored session.
    private static let nextPrompt = "now tell me what you changed"

    /// The window of the watch: small, so a short script fills it.
    private static let window = 200

    /// The detection of every session of this suite.
    private static let detection = RepetitionDetection(windowTokens: window)

    /// The lines the stopped call writes one time, before it repeats.
    private static let newLines = [
        "First I read the failing test and its fixture.",
        "The fixture builds the query with a stale alias.",
    ]

    /// The lines the stopped call writes again and again.
    private static let cycle = [
        "Maybe the alias is resolved in the compiler.",
        "Let me look at how the compiler resolves it.",
        "So the compiler keeps the alias from the join.",
    ]

    /// How many times the stopped call writes ``cycle``: far more than one
    /// ``window`` of tokens.
    private static let cycleCount = 40

    /// The hold of the stopped call. It ends only when the session cancels it.
    private static let stoppedHold = Duration.seconds(5)

    /// The script of the live model: its first call repeats and is stopped.
    private static let liveScript = RepeatingReasoningScript.repeating(
        newLines: newLines, cycle: cycle, cycleCount: cycleCount, hold: stoppedHold)

    /// The script of the model the restored session runs over: a call that
    /// writes no reasoning and answers at once.
    private static let restoredScript = RepeatingReasoningScript(reasoningLines: [], hold: .zero)

    /// The reasoning text the render keeps after the stop: each new line one
    /// time, with its line feed.
    private static var keptReasoning: String {
        (newLines + cycle).map { $0 + "\n" }.joined()
    }

    /// Resolves a profile over a ``RepeatingReasoningModel`` that plays
    /// `script`, recorded under `directories`.
    ///
    /// - Parameters:
    ///   - routerId: The id of the router. A restore passes the id of the
    ///     router that recorded the session.
    ///   - script: What the first call of each session writes.
    ///   - log: The log the model writes.
    ///   - directories: The cache and recording directories.
    /// - Returns: The router and its resolved profile.
    /// - Throws: Whatever profile resolution throws.
    private static func resolveProfile(
        routerId: ULID, script: RepeatingReasoningScript, log: RenderProbeLog, directories: TestDirectories
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        let model = RepeatingReasoningModel(log: log, script: script, repeatsAfterStop: false)
        let router = RouterTestFixtures.makeRouter(
            id: routerId,
            cacheDir: directories.cacheDir,
            recordingsDir: directories.recordingsDir,
            recorder: JSONLRecorder(directory: directories.recordingsDir),
            loader: StubModelLoader(
                container: LiveBackendContainer(model: model), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (router, profile)
    }

    /// A live session that ran one answer with one repetition stop, and the
    /// router that recorded it.
    private struct StoppedSession {
        /// The router that recorded the session.
        let router: Router

        /// The profile the session was made from, which keeps the session's
        /// handle alive.
        let profile: LanguageModelProfile

        /// The live session.
        let session: RoutedSessionActor
    }

    /// Makes a live session and runs one answer that the watch stops once.
    ///
    /// - Parameter directories: The cache and recording directories.
    /// - Returns: The live session and its router.
    /// - Throws: Whatever the answer throws, or a failed requirement.
    private static func runStoppedAnswer(directories: TestDirectories) async throws -> StoppedSession {
        let (router, profile) = try await resolveProfile(
            routerId: .generate(), script: liveScript, log: RenderProbeLog(), directories: directories)
        let session = try #require(
            profile.standard.makeSession(configuration: SessionConfiguration(repetitionDetection: detection))
                as? RoutedSessionActor)
        let events = try await collect(session.streamEvents(to: prompt))
        let stops = events.filter { event in
            guard case .repetitionStopped = event else { return false }
            return true
        }
        #expect(stops.count == 1)
        return StoppedSession(router: router, profile: profile, session: session)
    }

    /// Restores the tree that `stopped` recorded, over a model that plays
    /// ``restoredScript``.
    ///
    /// - Parameters:
    ///   - stopped: The live session and its router.
    ///   - log: The log the restored model writes.
    ///   - directories: The cache and recording directories.
    /// - Returns: The restored tree, and the profile that keeps it alive.
    /// - Throws: Whatever the restore throws.
    private static func restore(
        _ stopped: StoppedSession, log: RenderProbeLog, directories: TestDirectories
    ) async throws -> (tree: RestoredSessionTree, profile: LanguageModelProfile) {
        let (_, profile) = try await resolveProfile(
            routerId: stopped.router.id, script: restoredScript, log: log, directories: directories)
        let tree = try await profile.standard.restoreSessionTree(root: stopped.session.id)
        return (tree, profile)
    }

    /// Each entry of `entries` as its kind, id and text, which is what the
    /// model reads. Segment ids are left out: a cut entry gets a new segment.
    ///
    /// - Parameter entries: The render entries.
    /// - Returns: One line for each entry, in order.
    private static func renderLines(of entries: [Transcript.Entry]) -> [String] {
        entries.map { entry in
            let (kind, payload, text) = TranscriptEntryMapper.event(from: entry)
            return "\(kind.rawValue) \(payload.entryId): \(text ?? "")"
        }
    }

    /// The joined text of every `.reasoning` entry of `transcript`.
    ///
    /// - Parameter transcript: The transcript to read.
    /// - Returns: The text of each reasoning entry, in order.
    private static func reasoningText(of transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }

    /// The text of each recorded `.reasoning` event of the live session.
    ///
    /// - Parameters:
    ///   - stopped: The live session and its router.
    ///   - directories: The cache and recording directories.
    /// - Returns: The recorded reasoning texts, in order.
    /// - Throws: Whatever loading the recorded tree throws.
    private static func recordedReasoning(of stopped: StoppedSession, directories: TestDirectories) throws -> [String] {
        try TranscriptTree.load(under: routerDirectory(of: stopped, directories: directories))
            .events(forSession: stopped.session.id)
            .filter { $0.kind == .reasoning }
            .compactMap(\.text)
    }

    /// The recording root of the router that recorded `stopped`.
    ///
    /// - Parameters:
    ///   - stopped: The live session and its router.
    ///   - directories: The cache and recording directories.
    /// - Returns: The directory ``TranscriptTree/load(under:)`` reads.
    private static func routerDirectory(of stopped: StoppedSession, directories: TestDirectories) -> URL {
        RouterTestFixtures.routerDirectory(routerId: stopped.router.id, recordingsDir: directories.recordingsDir)
    }

    /// Writes the recorded transcript of the live session again, with each
    /// event passed through `transform`. An event that `transform` maps to
    /// `nil` leaves the journal.
    ///
    /// - Parameters:
    ///   - stopped: The live session and its router.
    ///   - directories: The cache and recording directories.
    ///   - transform: The change to make to each recorded event.
    /// - Throws: Whatever reading or writing the transcript throws.
    private static func rewriteJournal(
        of stopped: StoppedSession, directories: TestDirectories,
        _ transform: (TranscriptEvent) throws -> TranscriptEvent?
    ) throws {
        let routerDirectory = routerDirectory(of: stopped, directories: directories)
        let recorded = try TranscriptTree.load(under: routerDirectory).events(forSession: stopped.session.id)
        let lines = try recorded.compactMap(transform).map { event in
            try #require(String(data: try JSONEncoder().encode(event), encoding: .utf8))
        }
        let transcriptURL = routerDirectory
            .appendingPathComponent(stopped.session.id.description, isDirectory: true)
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        try (lines.joined(separator: "\n") + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    /// The reconstructed transcript of the live session in `view`.
    ///
    /// - Parameters:
    ///   - stopped: The live session and its router.
    ///   - directories: The cache and recording directories.
    ///   - view: The view to reconstruct.
    /// - Returns: The reconstructed transcript.
    /// - Throws: Whatever loading or reconstructing throws.
    private static func reconstructed(
        _ stopped: StoppedSession, directories: TestDirectories, view: TranscriptReconstructionView
    ) throws -> Transcript {
        try TranscriptTree.load(under: routerDirectory(of: stopped, directories: directories))
            .effectiveTranscript(forSession: stopped.session.id, view: view)
    }

    @Test("the full-history view keeps the full entry of a stopped call")
    func fullHistoryViewKeepsTheFullEntry() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)

        let fullHistory = try Self.reconstructed(stopped, directories: directories, view: .fullHistory)
        let reasoning = try #require(Self.reasoningText(of: fullHistory).first)

        #expect(reasoning.hasPrefix(Self.keptReasoning))
        #expect(reasoning.count > Self.keptReasoning.count + Self.window)
    }

    @Test("a journal with no record of the cut restores the full entry, as a journal recorded before the cut did")
    func journalWithNoCutRestoresAsBefore() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)
        let fullHistory = try Self.reconstructed(stopped, directories: directories, view: .fullHistory)

        try Self.rewriteJournal(of: stopped, directories: directories) { event in
            event.kind == .repeatedPartRemoval ? nil : event
        }
        let restored = try Self.reconstructed(stopped, directories: directories, view: .restore)

        #expect(Self.renderLines(of: Array(restored)) == Self.renderLines(of: Array(fullHistory)))
    }

    @Test("a record of the cut that does not decode refuses the restore, and names the event")
    func undecodableCutRefusesTheRestore() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)
        var cutSeq: Int?

        try Self.rewriteJournal(of: stopped, directories: directories) { event in
            guard event.kind == .repeatedPartRemoval, let payload = event.entry else { return event }
            cutSeq = event.seq
            let corrupt = TranscriptEntryPayload(
                entryId: payload.entryId,
                segments: [.structure(id: payload.entryId, schemaName: RepeatedPartRemovalSegment.schemaName, contentJSON: "{}")])
            return TranscriptEvent(
                routerId: event.routerId, sessionId: event.sessionId, parentId: event.parentId, slot: event.slot,
                model: event.model, seq: event.seq, ts: event.ts, kind: event.kind, grammar: event.grammar,
                text: event.text, entry: corrupt)
        }
        let seq = try #require(cutSeq)

        #expect {
            try Self.reconstructed(stopped, directories: directories, view: .restore)
        } throws: { error in
            guard case .entryReconstructionFailed(let session, let failedSeq, .invalidJSON) = error
                as? TranscriptReconstructionError
            else { return false }
            return session == stopped.session.id && failedSeq == seq
        }
    }

    @Test("the next call of a restored session does not receive the repeated part, and the record keeps the full entry")
    func restoredSessionKeepsTheRepeatedPartOutOfItsNextCall() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)

        let restoredLog = RenderProbeLog()
        let (restored, profile) = try await Self.restore(stopped, log: restoredLog, directories: directories)
        _ = try await restored.root.respond(to: Self.nextPrompt)
        withExtendedLifetime(profile) {}

        let nextCall = try #require(restoredLog.renders.first)
        #expect(nextCall.promptTexts.last == Self.nextPrompt)
        #expect(Self.reasoningText(of: nextCall) == [Self.keptReasoning])

        let recorded = try Self.recordedReasoning(of: stopped, directories: directories)
        let fullEntry = try #require(recorded.first)
        #expect(recorded.count == 1)
        #expect(fullEntry.hasPrefix(Self.keptReasoning))
        #expect(fullEntry.count > Self.keptReasoning.count + Self.window)
    }

    @Test("a restored session holds the render the live session held after the stop")
    func restoredRenderEqualsTheLiveRender() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)
        let liveRender = await stopped.session.backend.transcriptEntries()

        let (restored, profile) = try await Self.restore(stopped, log: RenderProbeLog(), directories: directories)
        let restoredRoot = try #require(restored.root as? RoutedSessionActor)
        let restoredRender = await restoredRoot.backend.transcriptEntries()
        withExtendedLifetime(profile) {}

        #expect(Self.renderLines(of: restoredRender) == Self.renderLines(of: liveRender))
    }

    @Test("a restored session reports the context counter the live session had after the stop")
    func restoredCounterEqualsTheLiveCounter() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)
        let liveUsage = await stopped.session.usageState

        let (restored, profile) = try await Self.restore(stopped, log: RenderProbeLog(), directories: directories)
        let restoredRoot = try #require(restored.root as? RoutedSessionActor)
        let restoredUsage = await restoredRoot.usageState
        withExtendedLifetime(profile) {}

        #expect(liveUsage.measuredTokens != nil)
        #expect(restoredUsage == liveUsage)
    }

    @Test("a restored fork of a session that had a stop holds the render the live fork held")
    func restoredForkRenderEqualsTheLiveForkRender() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let stopped = try await Self.runStoppedAnswer(directories: directories)
        let fork = try #require(try await stopped.session.fork(workingDirectory: nil) as? RoutedSessionActor)
        let liveForkRender = await fork.backend.transcriptEntries()
        #expect(Self.reasoningText(of: Transcript(entries: liveForkRender)) == [Self.keptReasoning])

        let (restored, profile) = try await Self.restore(stopped, log: RenderProbeLog(), directories: directories)
        let restoredFork = try #require(restored.session(fork.id) as? RoutedSessionActor)
        let restoredForkRender = await restoredFork.backend.transcriptEntries()
        withExtendedLifetime(profile) {}

        #expect(Self.renderLines(of: restoredForkRender) == Self.renderLines(of: liveForkRender))
    }

    @Test("the cut record travels under the schema name that an earlier build wrote, and its payload decodes back to the segment")
    func cutRecordKeepsItsSchemaNameAndRoundTrips() throws {
        let segment = RepeatedPartRemovalSegment(content: .init(keptUTF8Lengths: ["entry-1": 42]))
        let payload = segment.eventPayload
        let structure = try #require(payload.segments?.first?.persistedStructure)

        #expect(RepeatedPartRemovalSegment.schemaName == String(reflecting: RepeatedPartRemovalSegment.self))
        #expect(structure.schemaName == RepeatedPartRemovalSegment.schemaName)
        let decoded = try RepeatedPartRemovalSegment(
            schemaName: structure.schemaName, contentJSON: structure.contentJSON, id: payload.entryId)
        #expect(decoded == segment)
    }
}
