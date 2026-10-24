import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises the read and the restore of a recording that holds forks.
///
/// The router has no live API that forks a session now, but a recording that
/// an earlier build made can hold forks: a fork has its folder in the folder
/// of its parent, and its `index.md` holds the fork parent and the cut. The
/// readers (``TranscriptTree``) and
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:)``
/// must still load such a recording. ``RecordedForkFixtures`` writes each
/// fork on disk in the format of the recorder, from the events of real
/// recorded sessions.
///
/// Everything runs against stubs: a stub loader, a stub container and a
/// ``JSONLRecorder`` in a temp directory. A second router with the same id
/// and the same recorder restores what the first router recorded, as a new
/// process does.
@Suite("Recorded fork trees: the read and the restore of a recording that holds forks")
struct RecordedForkTreeRestoreTests {
    // MARK: - Fixtures

    /// The prefix of each temp directory of this suite.
    private static let tempDirPrefix = "RecordedForkTreeRestoreTests"

    /// The model that the standard slot of the stub profile resolves to.
    private static let standardModelRef = "org/std-a"

    /// A recording root and the router that records into it.
    private struct Recording {
        /// The temp directories of the test.
        let directories: TestDirectories

        /// The one writer of the recording root. The restoring router shares
        /// it, because a recording root admits one live writer.
        let recorder: JSONLRecorder

        /// The router that records. The test keeps it alive.
        let router: Router

        /// The profile that the router resolved.
        let profile: LanguageModelProfile

        /// The recording root of the router: the folder that holds the root
        /// session folders.
        var routerDirectory: URL {
            RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: directories.recordingsDir)
        }

        /// Resolves a second router with the id and the recorder of this
        /// recording, as a new process that continues the recording does.
        ///
        /// - Parameters:
        ///   - container: The container of the second router.
        ///   - tracer: The tracer of the second router, or `nil` (the default).
        /// - Returns: The second router and its profile. The caller keeps the
        ///   router alive.
        /// - Throws: What the resolve throws.
        func restoringProfile(
            over container: any LoadedLLMContainer = BasicLLMContainer(), tracer: (any Tracer)? = nil
        ) async throws -> (router: Router, profile: LanguageModelProfile) {
            let router = RouterTestFixtures.makeRouter(
                id: router.id, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir,
                recorder: recorder,
                loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
                tracer: tracer)
            let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return (router, profile)
        }

        /// Loads the recorded tree.
        ///
        /// - Returns: The tree.
        /// - Throws: What the load throws.
        func tree() throws -> TranscriptTree {
            try TranscriptTree.load(under: routerDirectory)
        }
    }

    /// Makes the temp directories and a recording router over `container`.
    ///
    /// - Parameter container: The container of the router.
    /// - Returns: The recording. The caller removes its directories.
    /// - Throws: What the resolve throws.
    private static func makeRecording(over container: any LoadedLLMContainer = BasicLLMContainer()) async throws
        -> Recording
    {
        let directories = TestDirectories(prefix: tempDirPrefix)
        let recorder = JSONLRecorder(directory: directories.recordingsDir)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return Recording(directories: directories, recorder: recorder, router: router, profile: profile)
    }

    /// A closed recorded root session, and the cut that a fork of it takes.
    private struct RecordedSession {
        /// The id of the session.
        let id: ULID

        /// The folder of the session.
        let directory: URL

        /// The cut at the end of its history after its first answers.
        let cut: RecordedForkCut
    }

    /// Records a root session that answers each of `prompts` and then closes.
    /// The session also closes when a step throws.
    ///
    /// - Parameters:
    ///   - prompts: The prompts that the session answers, in order.
    ///   - answersBeforeCut: How many of `prompts` the session answers before
    ///     the cut is read, or `nil` (the default) for all of them.
    ///   - recording: The recording to record into.
    ///   - configuration: The configuration of the session.
    /// - Returns: The recorded session.
    /// - Throws: What an answer or the read of the cut throws.
    private static func recordClosedSession(
        answering prompts: [String],
        answersBeforeCut: Int? = nil,
        in recording: Recording,
        configuration: SessionConfiguration = SessionConfiguration()
    ) async throws -> RecordedSession {
        let session = recording.profile.standard.makeSession(configuration: configuration)
        do {
            let before = answersBeforeCut ?? prompts.count
            for prompt in prompts.prefix(before) {
                _ = try await session.respond(to: prompt)
            }
            let cut = try RecordedForkFixtures.cut(atEndOf: session.id, under: recording.routerDirectory)
            for prompt in prompts.dropFirst(before) {
                _ = try await session.respond(to: prompt)
            }
            await session.close()
            return RecordedSession(id: session.id, directory: session.recordingDirectory, cut: cut)
        } catch {
            await session.close()
            throw error
        }
    }

    /// The ids of a recorded branching tree: a root, its two forks `forkA`
    /// and `forkB`, and `grandfork`, the fork of `forkA`.
    private struct BranchingTree {
        /// The id of the root.
        let root: ULID
        /// The id of the first fork of the root.
        let forkA: ULID
        /// The id of the second fork of the root.
        let forkB: ULID
        /// The id of the fork of `forkA`.
        let grandfork: ULID
    }

    /// Records a branching tree of four sessions. Each prompt is the text
    /// `<session>-message-<n>`, so a test can find each answer.
    ///
    /// Each fork is cut after the first answer of its parent. The later
    /// answers of a parent come after the cut, so no fork inherits them.
    ///
    /// - Parameters:
    ///   - recording: The recording to record into.
    ///   - rootAnswersAfterForks: The answers of the root after the cut.
    ///   - forkAAnswersAfterGrandfork: The answers of `forkA` after the cut
    ///     of `grandfork`.
    ///   - forkBAnswers: The answers of `forkB`.
    /// - Returns: The ids of the tree.
    /// - Throws: What an answer, a read or a write throws.
    private static func recordBranchingTree(
        in recording: Recording,
        rootAnswersAfterForks: Int = 0,
        forkAAnswersAfterGrandfork: Int = 0,
        forkBAnswers: Int = 1
    ) async throws -> BranchingTree {
        func prompts(_ session: String, _ count: Int) -> [String] {
            (0..<count).map { "\(session)-message-\($0 + 1)" }
        }
        let root = try await recordClosedSession(
            answering: prompts("root", 1 + rootAnswersAfterForks), answersBeforeCut: 1, in: recording)
        let forkA = try await recordClosedSession(
            answering: prompts("forkA", 1 + forkAAnswersAfterGrandfork), answersBeforeCut: 1, in: recording)
        let forkB = try await recordClosedSession(answering: prompts("forkB", forkBAnswers), in: recording)
        let grandfork = try await recordClosedSession(answering: prompts("grandfork", 1), in: recording)

        let forkADirectory = try RecordedForkFixtures.nest(donor: forkA.directory, under: root.directory, cut: root.cut)
        try RecordedForkFixtures.nest(donor: forkB.directory, under: root.directory, cut: root.cut)
        try RecordedForkFixtures.nest(
            donor: grandfork.directory, under: forkADirectory, cut: forkA.cut.following(root.cut))
        return BranchingTree(root: root.id, forkA: forkA.id, forkB: forkB.id, grandfork: grandfork.id)
    }

    /// The entry ids of the own recorded entry events of a session: what the
    /// session appended after its cut.
    ///
    /// - Parameters:
    ///   - tree: The loaded tree.
    ///   - sessionId: The id of the session.
    /// - Returns: The entry ids, in order.
    /// - Throws: What the read of the events throws.
    private static func ownEntryIds(in tree: TranscriptTree, of sessionId: ULID) throws -> [String] {
        try tree.events(forSession: sessionId).filter(\.kind.isEntryKind).compactMap { $0.entry?.entryId }
    }

    // MARK: - The shape of the tree

    /// The production change that makes this test fail: a load that does
    /// not read the parent of a session from the folder it is in.
    @Test("each recorded session is found by its id, and the roots, the children and the parents match the folders")
    @MainActor
    func treeShapeMatchesTheNestedFolders() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(in: recording)

        let tree = try recording.tree()

        for id in [ids.root, ids.forkA, ids.forkB, ids.grandfork] {
            #expect(tree.session(id)?.id == id)
        }
        #expect(tree.session(.generate()) == nil)
        #expect(tree.roots.map(\.id) == [ids.root])
        #expect(try #require(tree.session(ids.root)).parentId == nil)
        // The children come in id order, which is the order of creation.
        let rootChildren = tree.children(of: ids.root).map(\.id)
        #expect(Set(rootChildren) == [ids.forkA, ids.forkB])
        #expect(rootChildren == rootChildren.sorted())
        let forkA = try #require(tree.session(ids.forkA))
        #expect(forkA.parentId == ids.root)
        #expect(forkA.record.forkParentId == ids.root)
        #expect(forkA.children.map(\.id) == [ids.grandfork])
        let forkB = try #require(tree.session(ids.forkB))
        #expect(forkB.parentId == ids.root)
        #expect(forkB.children.isEmpty)
        let grandfork = try #require(tree.session(ids.grandfork))
        #expect(grandfork.parentId == ids.forkA)
        #expect(grandfork.record.forkParentId == ids.forkA)
        #expect(tree.children(of: ids.grandfork).isEmpty)
    }

    /// The production change that makes this test fail: an
    /// `events(forSession:)` that reads the events of an ancestor too.
    @Test("events(forSession:) reads only the own transcript.jsonl of a fork, whose events name the fork and its parent")
    @MainActor
    func eventsOfAForkAreItsOwnDeltaOnly() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(in: recording)

        let tree = try recording.tree()

        let forkAEvents = try tree.events(forSession: ids.forkA).filter { $0.kind != .mail }
        #expect(forkAEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(forkAEvents.first { $0.kind == .prompt }?.text == "forkA-message-1")
        #expect(!forkAEvents.contains { $0.text == "root-message-1" })
        #expect(!forkAEvents.contains { $0.text == "grandfork-message-1" })
        #expect(forkAEvents.allSatisfy { $0.sessionId == ids.forkA && $0.parentId == ids.root })
        let rootEvents = try tree.events(forSession: ids.root).filter { $0.kind != .mail }
        #expect(rootEvents.map(\.kind) == [.session, .prompt, .response])
        #expect(rootEvents.allSatisfy { $0.sessionId == ids.root && $0.parentId == nil })
    }

    // MARK: - The effective history of a fork

    /// The production change that makes this test fail: a fork prefix that
    /// keeps the events of a parent after the cut, or a cut that is not
    /// taken in each ancestor.
    @Test("the effective entries of a grandfork are the root up to the first cut, forkA up to the second cut, and its own")
    @MainActor
    func effectiveEntriesOfAGrandforkAreCutAtEachForkPoint() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(
            in: recording, rootAnswersAfterForks: 1, forkAAnswersAfterGrandfork: 1, forkBAnswers: 0)

        let tree = try recording.tree()

        // One answer is one prompt entry and one response entry.
        #expect(try #require(tree.session(ids.forkA)).record.forkedAtHistoryOrdinal == 2)
        #expect(try #require(tree.session(ids.grandfork)).record.forkedAtHistoryOrdinal == 4)
        let effective = try tree.effectiveEntryEvents(forSession: ids.grandfork)
        #expect(
            effective.filter { $0.kind == .prompt }.map(\.text)
                == ["root-message-1", "forkA-message-1", "grandfork-message-1"])
        #expect(effective.map(\.kind) == [.prompt, .response, .prompt, .response, .prompt, .response])
        #expect(!effective.contains { $0.kind == .session })
        #expect(!effective.contains { $0.text == "root-message-2" })
        #expect(!effective.contains { $0.text == "forkA-message-2" })
        // The root and forkA keep their later answers.
        #expect(try tree.effectiveEntryEvents(forSession: ids.root).count == 4)
        #expect(try tree.effectiveEntryEvents(forSession: ids.forkA).count == 6)
    }

    /// The production change that makes this test fail: a reader that cuts
    /// at `forkedAtEntryCount` when the record holds
    /// `forkedAtHistoryOrdinal`, or that fails on a record that holds only
    /// the legacy count.
    @Test("a fork is cut at forkedAtHistoryOrdinal, and a legacy record with only forkedAtEntryCount is cut at that count")
    @MainActor
    func theCutIsTheHistoryOrdinalElseTheLegacyEntryCount() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let root = try await Self.recordClosedSession(
            answering: ["root-message-1", "root-message-2"], answersBeforeCut: 1, in: recording)
        // The cut after the first answer, in both forms.
        let current = try RecordedForkFixtures.writeFork(under: root.directory, cut: root.cut)
        let legacy = try RecordedForkFixtures.writeFork(under: root.directory, cut: root.cut.legacy)
        // A record whose two counts differ: the history ordinal names the
        // end of the second answer.
        let ordinalFirst = try RecordedForkFixtures.writeFork(
            under: root.directory, cut: RecordedForkCut(historyOrdinal: 4, entryCount: 2))
        let ids = [current, legacy, ordinalFirst].compactMap { ULID($0.lastPathComponent) }
        try #require(ids.count == 3)

        let tree = try recording.tree()
        let rootEntries = try tree.effectiveEntryEvents(forSession: root.id)
        #expect(try #require(tree.session(ids[1])).record.forkedAtHistoryOrdinal == nil)
        #expect(try tree.effectiveEntryEvents(forSession: ids[0]) == Array(rootEntries.prefix(2)))
        #expect(try tree.effectiveEntryEvents(forSession: ids[1]) == Array(rootEntries.prefix(2)))
        #expect(try tree.effectiveEntryEvents(forSession: ids[2]) == rootEntries)

        // The restore seeds each fork with the same cut.
        let (router2, profile2) = try await recording.restoringProfile()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer {
            await SessionFixtureLifecycle.close(restored)
            withExtendedLifetime(router2) {}
        }
        let rootTranscript = Array(try tree.effectiveTranscript(forSession: root.id))
        let expected = [Array(rootTranscript.prefix(2)), Array(rootTranscript.prefix(2)), rootTranscript]
        for (id, entries) in zip(ids, expected) {
            let fork = try #require(restored.session(id))
            #expect(Array(await fork.transcript) == entries)
        }
    }

    /// The production change that makes this test fail: a load that finds
    /// a session by its `transcript.jsonl` only.
    @Test("a fork whose root never answered reconstructs: the index.md of the root names it, with no transcript.jsonl")
    @MainActor
    func aForkWhoseRootNeverAnsweredReconstructs() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let root = try await Self.recordClosedSession(answering: [], in: recording)
        let fork = try await Self.recordClosedSession(answering: ["fork-message-1"], in: recording)
        try RecordedForkFixtures.nest(donor: fork.directory, under: root.directory, cut: root.cut)

        let tree = try recording.tree()

        #expect(root.cut == RecordedForkCut(historyOrdinal: 0, entryCount: 0))
        #expect(tree.roots.map(\.id) == [root.id])
        #expect(try tree.events(forSession: root.id).isEmpty)
        let forkNode = try #require(tree.session(fork.id))
        #expect(forkNode.parentId == root.id)
        #expect(forkNode.record.forkedAtEntryCount == 0)
        let effective = try tree.effectiveEntryEvents(forSession: fork.id)
        #expect(effective.map(\.kind) == [.prompt, .response])
        #expect(effective.first?.text == "fork-message-1")
    }

    /// The production change that makes this test fail: a load that makes a
    /// fork with no parent `index.md` a root.
    @Test("a deleted index.md of a parent fails the load with indexMissing naming its folder")
    @MainActor
    func aDeletedParentIndexFailsTheLoad() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(in: recording)
        let rootDirectory = try #require(try recording.tree().session(ids.root)).directory

        try FileManager.default.removeItem(at: RouterTestFixtures.indexURL(inSessionDirectory: rootDirectory))

        #expect(throws: TranscriptTreeError.indexMissing(directory: rootDirectory)) {
            _ = try recording.tree()
        }
    }

    /// The production change that makes this test fail: a load that fails,
    /// or a parent whose history changes, when a child folder is gone.
    @Test("a deleted child folder leaves no trace: the tree loads without it, and the parent reconstructs whole")
    @MainActor
    func aDeletedChildFolderLoadsCleanWithoutIt() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(in: recording)
        let before = try recording.tree()
        let rootCountBefore = try before.effectiveEntryEvents(forSession: ids.root).count

        try FileManager.default.removeItem(at: try #require(before.session(ids.forkB)).directory)

        let after = try recording.tree()
        #expect(after.session(ids.forkB) == nil)
        #expect(after.children(of: ids.root).map(\.id) == [ids.forkA])
        #expect(try after.effectiveEntryEvents(forSession: ids.root).count == rootCountBefore)
    }

    // MARK: - The restore of the tree

    /// The production change that makes this test fail: a restore that does
    /// not walk the recorded forks, that gives two nodes one work registry,
    /// or that starts the persisted count of a restored fork at zero.
    @Test("restoring a recorded 4-node tree reproduces its shape and the effective entry count of each node")
    @MainActor
    func restoringReproducesTreeShapeAndEntryCounts() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(in: recording, forkBAnswers: 0)
        let all = [ids.root, ids.forkA, ids.forkB, ids.grandfork]

        let (router2, profile2) = try await recording.restoringProfile()
        let restored = try await profile2.standard.restoreSessionTree(root: ids.root)
        defer {
            await SessionFixtureLifecycle.close(restored)
            withExtendedLifetime(router2) {}
        }

        #expect(restored.root.id == ids.root)
        #expect(restored.root.parentId == nil)
        #expect(Set(restored.children(of: ids.root).map(\.id)) == [ids.forkA, ids.forkB])
        #expect(restored.children(of: ids.forkA).map(\.id) == [ids.grandfork])
        #expect(restored.children(of: ids.forkB).isEmpty)
        #expect(restored.session(ids.forkA)?.parentId == ids.root)
        #expect(restored.session(ids.grandfork)?.parentId == ids.forkA)
        // Each restored node owns a work registry of its own, under its own id.
        let registries = all.compactMap { restored.session($0)?.runPlane.workRegistry }
        #expect(registries.map(\.sessionID) == all)
        #expect(Set(registries.map(ObjectIdentifier.init)).count == registries.count)

        // root 2, forkA 2 inherited + 2, forkB 2 inherited, grandfork 4
        // inherited + 2.
        let tree = try recording.tree()
        #expect(try all.map { try tree.effectiveEntryEvents(forSession: $0).count } == [2, 4, 2, 6])

        // A first answer of a restored fork that never answered persists
        // only its own entries: its persisted count starts at the count it
        // inherited, not at zero.
        let restoredForkB = try #require(restored.session(ids.forkB))
        _ = try await restoredForkB.respond(to: "forkB's first message, after the restore")
        #expect(try recording.tree().effectiveEntryEvents(forSession: ids.forkB).count == 4)
        #expect(try recording.tree().events(forSession: ids.forkB).filter(\.kind.isEntryKind).count == 2)
    }

    /// The production change that makes this test fail: a restore that
    /// seeds a fork with its own events only, or with the whole history of
    /// its parent.
    @Test("each restored node holds the parent's transcript at the cut followed by its own, as the live sessions held them")
    @MainActor
    func eachRestoredNodeHoldsItsEffectiveTranscript() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let root = recording.profile.standard.makeSession()
        let donor = recording.profile.standard.makeSession()
        let rootAtCut: [Transcript.Entry]
        let donorEntries: [Transcript.Entry]
        let rootCut: RecordedForkCut
        do {
            _ = try await root.respond(to: "root-message-1")
            rootAtCut = Array(await root.transcript)
            rootCut = try RecordedForkFixtures.cut(atEndOf: root.id, under: recording.routerDirectory)
            _ = try await root.respond(to: "root-message-2")
            _ = try await donor.respond(to: "fork-message-1")
            donorEntries = Array(await donor.transcript)
        } catch {
            await donor.close()
            await root.close()
            throw error
        }
        let rootEntries = Array(await root.transcript)
        await donor.close()
        await root.close()
        try RecordedForkFixtures.nest(donor: donor.recordingDirectory, under: root.recordingDirectory, cut: rootCut)

        let tree = try recording.tree()
        #expect(Array(try tree.effectiveTranscript(forSession: root.id)) == rootEntries)
        #expect(Array(try tree.effectiveTranscript(forSession: donor.id)) == rootAtCut + donorEntries)

        let (router2, profile2) = try await recording.restoringProfile()
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer {
            await SessionFixtureLifecycle.close(restored)
            withExtendedLifetime(router2) {}
        }
        #expect(Array(await restored.root.transcript) == rootEntries)
        let restoredFork = try #require(restored.session(donor.id))
        #expect(Array(await restoredFork.transcript) == rootAtCut + donorEntries)
    }

    /// The production change that makes this test fail: a restore that
    /// takes any session id as the root of a tree.
    @Test("restoring by the id of a recorded fork throws notARootSession")
    @MainActor
    func restoringByAForkIdThrowsNotARootSession() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let ids = try await Self.recordBranchingTree(in: recording)

        let (router2, profile2) = try await recording.restoringProfile()
        defer { withExtendedLifetime(router2) {} }
        await #expect(throws: SessionTreeRestorationError.notARootSession(ids.forkA)) {
            // A restore that does not throw fails the test; its nodes close.
            await SessionFixtureLifecycle.close(try await profile2.standard.restoreSessionTree(root: ids.forkA))
        }
    }

    /// The production change that makes this test fail: a restore that
    /// reads the configuration envelope of the root only, or that does not
    /// give its user presence to a fork.
    @Test("a restored fork re-applies the configuration of its own index.md, and a supplied user presence replaces its recorded one")
    @MainActor
    func aRestoredForkReappliesItsRecordedConfiguration() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        // Values that are not the defaults, so a restore cannot pass by
        // falling back to the defaults.
        let detection = RepetitionDetection(
            isEnabled: false, windowTokens: 512, minimumLineLength: 8, recoveriesPerAnswer: 1)
        let limit = SessionConfiguration.defaultMailOnlyAnswerLimit + 1
        let grace = ToolMount.defaultInlineSettleGrace / 4
        let configuration = SessionConfiguration(
            repetitionDetection: detection, mailOnlyAnswerLimit: limit, inlineSettleGrace: grace,
            userPresence: .headless)
        let root = try await Self.recordClosedSession(answering: ["hello"], in: recording, configuration: configuration)
        let forkDirectory = try RecordedForkFixtures.writeFork(under: root.directory, cut: root.cut)
        let forkId = try #require(ULID(forkDirectory.lastPathComponent))

        let (router2, profile2) = try await recording.restoringProfile()
        defer { withExtendedLifetime(router2) {} }
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        let settings = (restored.session(forkId) as? RoutedSessionActor).map {
            ($0.repetitionDetection, $0.mailOnlyAnswerLimit, $0.inlineSettleGrace, $0.runPlane.userPresence)
        }
        await SessionFixtureLifecycle.close(restored)
        let (restoredDetection, restoredLimit, restoredGrace, restoredPresence) = try #require(settings)
        #expect(restoredDetection == detection)
        #expect(restoredLimit == limit)
        #expect(restoredGrace == grace)
        #expect(restoredPresence == .headless)

        let overridden = try await profile2.standard.restoreSessionTree(root: root.id, userPresence: .interactive)
        defer { await SessionFixtureLifecycle.close(overridden) }
        let overriddenFork = try #require(overridden.session(forkId) as? RoutedSessionActor)
        #expect(overriddenFork.runPlane.userPresence == .interactive)
        // The restore writes no index.md: the record of the fork keeps its
        // recorded presence.
        let forkRecord = try #require(try SessionIndexFile.read(in: forkDirectory))
        #expect(forkRecord.configuration?.restoredUserPresence == .headless)
    }

    // MARK: - A fork after a compaction

    /// A canned answer long enough that six answers of it are much larger
    /// than one copy, so a summary makes the live context smaller.
    private static let longAnswer = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// The production change that makes this test fail: a cut read in the
    /// coordinates of the backend after a compaction, which gives the fork
    /// the oldest entries of the history in place of the live window.
    @Test("a fork cut after its parent compacted restores the live window of the compaction plus its own entries, never the compacted span")
    @MainActor
    func aForkAfterACompactionRestoresTheLiveWindow() async throws {
        let container = RetainingLLMContainer(responseText: Self.longAnswer)
        let recording = try await Self.makeRecording(over: container)
        defer { recording.directories.remove() }
        let root = recording.profile.standard.makeSession()
        let cut: RecordedForkCut
        do {
            try await driveAnswers(6, on: root)
            let rootBackend = try #require(container.lastBackend)
            let result = try await root.compactAndAwait(
                budget: summarizingCompactionBudget(for: rootBackend.transcriptEntries()))
            #expect(result.stagesApplied == [Summarization.stageName])
            cut = try RecordedForkFixtures.cut(atEndOf: root.id, under: recording.routerDirectory)
            // The parent goes on after the cut. The fork never inherits it.
            _ = try await root.respond(to: "root continues after the fork")
        } catch {
            await root.close()
            throw error
        }
        await root.close()
        let fork = try await Self.recordClosedSession(answering: ["fork continues after the compaction"], in: recording)
        try RecordedForkFixtures.nest(donor: fork.directory, under: root.recordingDirectory, cut: cut)

        let tree = try recording.tree()
        let checkpoint = try #require(
            TranscriptTree.newestCompactionCheckpoint(in: tree.effectiveEntryEvents(forSession: fork.id)))
        // The two coordinates differ: the history holds the compacted span,
        // the backend held the live window only.
        #expect(cut.entryCount == checkpoint.content.liveWindowEntryIds.count)
        #expect(try #require(cut.historyOrdinal) > cut.entryCount)
        let forkOwnIds = try Self.ownEntryIds(in: tree, of: fork.id)
        #expect(!forkOwnIds.isEmpty)
        let expectedIds = checkpoint.content.liveWindowEntryIds + forkOwnIds
        #expect(try tree.effectiveTranscript(forSession: fork.id).map(\.id) == expectedIds)

        let (router2, profile2) = try await recording.restoringProfile(
            over: RetainingLLMContainer(responseText: Self.longAnswer))
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer {
            await SessionFixtureLifecycle.close(restored)
            withExtendedLifetime(router2) {}
        }
        let restoredFork = try #require(restored.session(fork.id))
        let restoredIds = await restoredFork.transcript.map(\.id)
        #expect(restoredIds == expectedIds)
        #expect(Set(checkpoint.content.compactedEntryIds).isDisjoint(with: restoredIds))
    }

    // MARK: - What a restored fork reads back

    /// The production change that makes this test fail: a restore that
    /// gives a fork the facts of its root, or new facts.
    @Test("a restored fork reads its facts back from its own index.md, with origin fork")
    func aRestoredForkReadsItsFactsBack() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let source = profile.standard.makeSession(
                configuration: SessionFactsFixtures.configuration(startedBy: ULID.generate()))
            let sourceDirectory = source.recordingDirectory
            await source.close()
            let forkDirectory = try RecordedForkFixtures.writeFork(
                under: sourceDirectory, cut: RecordedForkCut(historyOrdinal: 0, entryCount: 0))
            let written = try #require(try SessionIndexFile.read(in: forkDirectory)).facts

            let tree = try await profile.standard.restoreSessionTree(root: source.id)
            let restoredFork = try #require(tree.children(of: source.id).first)
            let restoredFacts = restoredFork.facts
            await SessionFixtureLifecycle.close(tree)

            #expect(restoredFacts == written)
            #expect(restoredFacts.origin == .fork)
            #expect(restoredFacts.agentID == SessionFactsFixtures.agentID)
            #expect(restoredFacts.agentName == SessionFactsFixtures.agentName)
            #expect(restoredFacts.tags == SessionFactsFixtures.tags)
            #expect(restoredFacts.title == nil)
            #expect(restoredFacts.startedBy == nil)
        }
    }

    /// The production change that makes this test fail: a restore that
    /// registers a recorded fork as a root, or not at all.
    @Test("a restored fork is in the session directory as a fork of its source")
    func aRestoredForkIsInTheDirectoryAsAForkOfItsSource() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let directory = try #require(profile.standard.sessionDirectory)
            let source = profile.standard.makeSession(configuration: SessionConfiguration())
            let sourceDirectory = source.recordingDirectory
            await source.close()
            let forkDirectory = try RecordedForkFixtures.writeFork(
                under: sourceDirectory, cut: RecordedForkCut(historyOrdinal: 0, entryCount: 0))
            let forkId = try #require(ULID(forkDirectory.lastPathComponent))

            let tree = try await profile.standard.restoreSessionTree(root: source.id)
            let summary = try await SessionDirectorySummaries.summary(of: forkId, in: directory)
            await SessionFixtureLifecycle.close(tree)

            #expect(summary.kind == .fork)
            #expect(summary.parentID == source.id)
        }
    }

    /// The production change that makes this test fail: a restore that
    /// opens one span for the whole tree, or a span of a fork that names no
    /// parent.
    @Test("restoring a recorded tree opens one restored session span per node, and the span of the fork names its parent")
    @MainActor
    func restoringATreeOpensOneSpanPerNode() async throws {
        let recording = try await Self.makeRecording()
        defer { recording.directories.remove() }
        let root = try await Self.recordClosedSession(answering: ["remember 42"], in: recording)
        let forkDirectory = try RecordedForkFixtures.writeFork(under: root.directory, cut: root.cut)
        let forkId = try #require(ULID(forkDirectory.lastPathComponent))

        let tracer = InMemoryTracer()
        let (router2, profile2) = try await recording.restoringProfile(tracer: tracer)
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer {
            await SessionFixtureLifecycle.close(restored)
            withExtendedLifetime(router2) {}
        }

        let spans = tracer.finishedSpans.filter { $0.operationName == "FoundationModelsRouter.session" }
        #expect(spans.count == 2)
        func span(of id: ULID) throws -> FinishedInMemorySpan {
            let matching = spans.filter { $0.attributes.get("session.id") == .string(id.description) }
            try #require(matching.count == 1)
            return try #require(matching.first)
        }
        let rootSpan = try span(of: root.id)
        #expect(rootSpan.kind == .internal)
        #expect(rootSpan.attributes.get("router.id") == .string(recording.router.id.description))
        #expect(rootSpan.attributes.get("model.ref") == .string(Self.standardModelRef))
        #expect(rootSpan.attributes.get("session.origin") == .string("restored"))
        #expect(rootSpan.attributes.get("session.parent_id") == nil)
        #expect(rootSpan.errors.isEmpty)
        let forkSpan = try span(of: forkId)
        #expect(forkSpan.attributes.get("session.origin") == .string("restored"))
        #expect(forkSpan.attributes.get("session.parent_id") == .string(root.id.description))
    }

    /// The production change that makes this test fail: a restore that
    /// reads the context fill of a fork from its own events only.
    @Test("a restored fork with no answers of its own reports the context fill of its parent at the cut")
    @MainActor
    func aRestoredForkInheritsTheContextFillOfItsParent() async throws {
        let recording = try await Self.makeRecording(over: BasicLLMContainer(usageIncrement: (input: 100, output: 50)))
        defer { recording.directories.remove() }
        let root = recording.profile.standard.makeSession()
        let liveFill: Double
        do {
            _ = try await root.respond(to: "first")
            liveFill = await root.contextFill
        } catch {
            await root.close()
            throw error
        }
        await root.close()
        let cut = try RecordedForkFixtures.cut(atEndOf: root.id, under: recording.routerDirectory)
        let forkDirectory = try RecordedForkFixtures.writeFork(under: root.recordingDirectory, cut: cut)
        let forkId = try #require(ULID(forkDirectory.lastPathComponent))

        let (router2, profile2) = try await recording.restoringProfile(
            over: BasicLLMContainer(usageIncrement: (input: 100, output: 50)))
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer {
            await SessionFixtureLifecycle.close(restored)
            withExtendedLifetime(router2) {}
        }

        #expect(liveFill > 0)
        #expect(await restored.root.contextFill == liveFill)
        let restoredFork = try #require(restored.session(forkId))
        #expect(await restoredFork.contextFill == liveFill)
    }
}
