import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^5aky6xr: seeding a ``SessionProjection`` from a cold
/// `Transcript`, so a restored session's UI does not start blank.
///
/// The pure grouping (``SessionProjection/transcriptRows(from:)``) is driven
/// with hand-built `Transcript.Entry` values, and the end-to-end claim — the
/// seeded rows equal the rows a live projection produced during the original
/// run, row for row by id — runs through a real recorded tool turn, a
/// fresh-process ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``,
/// and the new read-only ``RoutedSession/transcript`` accessor.
@Suite("SessionProjection seeding from a cold Transcript (task ^5aky6xr)")
struct SessionProjectionSeedingTests {
    // MARK: - Fixtures

    /// The temp-directory prefix, so a leaked directory is attributable.
    private static let tempDirPrefix = "SessionProjectionSeedingTests"

    /// The step name the second scripted call names, distinct from
    /// ``ScriptedToolFixture/firstStepName`` so the two calls in the round
    /// stay distinguishable by content.
    private static let secondStepName = "TWO"

    /// The pre-fold token count the compaction fixtures record.
    private static let foldTokensBefore = 1000

    /// The post-fold token count the compaction fixtures record.
    private static let foldTokensAfter = 400

    /// The shared boundary-entry fixture with this suite's token counts
    /// applied — see ``TranscriptFixtures/makeCompactionEntry(entryId:segmentId:summaryText:tokensBefore:tokensAfter:)``.
    ///
    /// - Parameters:
    ///   - entryId: The boundary entry's own `Transcript.Entry.id`.
    ///   - segmentId: The persisted ``CompactionSegment/id``.
    ///   - summaryText: The model-visible summary text; empty for a
    ///     deterministic-only fold.
    /// - Returns: The boundary entry.
    private static func makeBoundaryEntry(
        entryId: String, segmentId: String, summaryText: String
    ) -> Transcript.Entry {
        TranscriptFixtures.makeCompactionEntry(
            entryId: entryId,
            segmentId: segmentId,
            summaryText: summaryText,
            tokensBefore: foldTokensBefore,
            tokensAfter: foldTokensAfter)
    }

    // MARK: - The pure grouping

    @Test("a tool turn's entries group into rows in transcript order, pairing outputs to calls by id")
    func toolTurnEntriesGroupIntoRowsInTranscriptOrder() throws {
        let callA = Transcript.ToolCall(
            id: "call-a", toolName: "search", arguments: try GeneratedContent(json: #"{"city":"NYC"}"#))
        let callB = Transcript.ToolCall(
            id: "call-b", toolName: "search", arguments: try GeneratedContent(json: #"{"city":"SF"}"#))
        let outputSegmentA = Transcript.TextSegment(content: "NYC: sunny")
        let outputSegmentB = Transcript.TextSegment(content: "SF: foggy")
        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "weather?"))])),
            .toolCalls(Transcript.ToolCalls(id: "calls-1", [callA, callB])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "call-a", toolName: "search",
                    segments: [.text(outputSegmentA)])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "call-b", toolName: "search",
                    segments: [.text(outputSegmentB)])),
            .reasoning(
                Transcript.Reasoning(
                    id: "reasoning-1",
                    segments: [.text(Transcript.TextSegment(content: "thinking"))],
                    signature: nil)),
            .response(
                Transcript.Response(
                    id: "resp-1", segments: [.text(Transcript.TextSegment(content: "the answer"))])),
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        // The `.prompt` entry yields no row; each other entry yields its own.
        #expect(rows.map(\.id) == ["call-a", "call-b", "reasoning-1", "resp-1"])
        #expect(rows.map(\.sourceEntryId) == ["calls-1", "calls-1", "reasoning-1", "resp-1"])
        #expect(
            rows.map(\.kind) == [
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-a", name: "search", argumentsJSON: callA.arguments.jsonString,
                        status: .completed, summary: "NYC: sunny",
                        output: [.text(id: outputSegmentA.id, content: "NYC: sunny")])),
                .toolCall(
                    SessionProjection.ToolCallEntry(
                        id: "call-b", name: "search", argumentsJSON: callB.arguments.jsonString,
                        status: .completed, summary: "SF: foggy",
                        output: [.text(id: outputSegmentB.id, content: "SF: foggy")])),
                .reasoning("thinking"),
                .text("the answer"),
            ]
        )
    }

    @Test("a seeded output's full segments land on the row — plain text and both structured kinds — with summary staying the flattened text")
    func seededOutputCarriesFullSegments() throws {
        let structureContent = try GeneratedContent(json: #"{"tempF":72}"#)
        let noteSegment = TestNoteSegment(id: "s-note", content: TestNote(body: "hello"))
        let outputSegments: [Transcript.Segment] = [
            .text(Transcript.TextSegment(id: "s-text", content: "72F and sunny")),
            .structure(
                Transcript.StructuredSegment(id: "s-struct", schemaName: "Weather", content: structureContent)),
            noteSegment.transcriptSegment,
        ]
        let entries: [Transcript.Entry] = [
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [
                        Transcript.ToolCall(
                            id: "call-1", toolName: "search", arguments: try GeneratedContent(json: "{}"))
                    ])),
            .toolOutput(Transcript.ToolOutput(id: "call-1", toolName: "search", segments: outputSegments)),
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        guard case .toolCall(let call) = rows.first?.kind else {
            Issue.record("expected one .toolCall row, got \(rows)")
            return
        }
        // `summary` stays the flattened text — the `.text` segments alone.
        #expect(call.status == .completed)
        #expect(call.summary == "72F and sunny")
        // The full segments land on the row, through the same mapping the
        // live diff emits, so the two paths carry equal data.
        let output = try #require(call.output)
        #expect(output == outputSegments.map(TranscriptEntryMapper.segmentPayload))
        try #require(output.count == outputSegments.count)
        #expect(output[0] == .text(id: "s-text", content: "72F and sunny"))
        guard case .structure(let structureId, let schemaName, let contentJSON) = output[1] else {
            Issue.record("expected a .structure payload, got \(output[1])")
            return
        }
        #expect(structureId == "s-struct")
        #expect(schemaName == "Weather")
        #expect(contentJSON == structureContent.jsonString)
        guard case .structure(let noteId, let noteSchemaName, let noteContentJSON) = output[2] else {
            Issue.record("expected a .structure payload, got \(output[2])")
            return
        }
        #expect(noteId == "s-note")
        #expect(noteSchemaName == TestNoteSegment.schemaName)
        #expect(try TestNoteSegment(schemaName: noteSchemaName, contentJSON: noteContentJSON, id: noteId)?.content == TestNote(body: "hello"))
    }

    @Test("an output whose id names no announced call pairs by first-occurrence ordinal order, like the live path")
    func outputPairsByOrdinalOrderWhenItsIdNamesNoCall() throws {
        let entries: [Transcript.Entry] = [
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [
                        Transcript.ToolCall(
                            id: "call-a", toolName: "search", arguments: try GeneratedContent(json: "{}")),
                        Transcript.ToolCall(
                            id: "call-b", toolName: "search", arguments: try GeneratedContent(json: "{}")),
                    ])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "output-entry-1", toolName: "search",
                    segments: [.text(Transcript.TextSegment(content: "NYC: sunny"))])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "output-entry-2", toolName: "search",
                    segments: [.text(Transcript.TextSegment(content: "SF: foggy"))])),
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        #expect(rows.map(\.id) == ["call-a", "call-b"])
        let statuses = rows.map { row -> (ToolCallStatus, String?)? in
            guard case .toolCall(let call) = row.kind else { return nil }
            return (call.status, call.summary)
        }
        #expect(statuses[0]! == (.completed, "NYC: sunny"))
        #expect(statuses[1]! == (.completed, "SF: foggy"))
    }

    @Test("a call whose output never arrived reports .failed, like the live diff's closing sweep")
    func unansweredCallRowReportsFailed() throws {
        let entries: [Transcript.Entry] = [
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [
                        Transcript.ToolCall(
                            id: "call-1", toolName: "search", arguments: try GeneratedContent(json: "{}"))
                    ]))
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        guard case .toolCall(let call) = rows.first?.kind else {
            Issue.record("expected one .toolCall row, got \(rows)")
            return
        }
        #expect(call.status == .failed)
        #expect(call.summary == nil)
    }

    @Test("the pairing scope resets at each .prompt entry, so a stray later output cannot complete an earlier turn's failed call")
    func pairingScopeResetsAtEachPromptEntry() throws {
        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn one"))])),
            .toolCalls(
                Transcript.ToolCalls(
                    id: "calls-1",
                    [
                        Transcript.ToolCall(
                            id: "call-1", toolName: "search", arguments: try GeneratedContent(json: "{}"))
                    ])),
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn two"))])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "stray-output", toolName: "search",
                    segments: [.text(Transcript.TextSegment(content: "late result"))])),
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        // The stray output pairs to nothing: turn two announced no call, and
        // turn one's call is out of scope — so the call stays .failed and the
        // output yields no row, exactly as the live projection drops an
        // untracked ``SessionEvent/toolStatus(id:status:summary:output:)``.
        #expect(rows.map(\.id) == ["call-1"])
        guard case .toolCall(let call) = rows.first?.kind else {
            Issue.record("expected one .toolCall row, got \(rows)")
            return
        }
        #expect(call.status == .failed)
    }

    @Test("a compaction boundary becomes a .compaction row keyed on the persisted segment id")
    func compactionBoundaryBecomesACompactionRow() {
        let entries = [
            Self.makeBoundaryEntry(
                entryId: "boundary-1", segmentId: "segment-1", summaryText: "folded summary")
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        let expected = CompactionResult(
            id: "segment-1",
            summary: "folded summary",
            summaryEntryId: "boundary-1",
            tokensBefore: Self.foldTokensBefore,
            tokensAfter: Self.foldTokensAfter,
            stagesApplied: ["Summarization"])
        #expect(rows.map(\.id) == ["segment-1"])
        #expect(rows.map(\.sourceEntryId) == ["boundary-1"])
        #expect(rows.map(\.kind) == [.compaction(expected)])
    }

    @Test("a deterministic fold's boundary (empty summary text) yields a .compaction row with no summary and no join id")
    func deterministicBoundaryRowCarriesNoSummary() {
        let entries = [
            Self.makeBoundaryEntry(entryId: "boundary-1", segmentId: "segment-1", summaryText: "")
        ]

        let rows = SessionProjection.transcriptRows(from: entries)

        guard case .compaction(let result) = rows.first?.kind else {
            Issue.record("expected one .compaction row, got \(rows)")
            return
        }
        #expect(result.summary == nil)
        #expect(result.summaryEntryId == nil)
        #expect(rows.map(\.sourceEntryId) == [nil])
    }

    // MARK: - groupedRows: seeded and live agree (task ^8dc98vs)

    @Test("the grouped view of a seeded projection equals the grouped view of the live projection for the same turn")
    @MainActor
    func groupedRowsOfASeededProjectionEqualTheLiveProjections() throws {
        // One tool turn, in transcript order: reasoning, the superseded
        // pre-tool text, one call, its result, and the final answer.
        let call = Transcript.ToolCall(
            id: "call-1", toolName: "search", arguments: try GeneratedContent(json: #"{"city":"NYC"}"#))
        let outputSegment = Transcript.TextSegment(id: "s-out", content: "NYC: sunny")
        let entries: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "weather?"))])),
            .reasoning(
                Transcript.Reasoning(
                    id: "reasoning-1",
                    segments: [.text(Transcript.TextSegment(content: "thinking"))],
                    signature: nil)),
            .response(
                Transcript.Response(
                    id: "resp-pre-tool",
                    segments: [.text(Transcript.TextSegment(content: "Let me check. "))])),
            .toolCalls(Transcript.ToolCalls(id: "calls-1", [call])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: "call-1", toolName: "search", segments: [.text(outputSegment)])),
            .response(
                Transcript.Response(
                    id: "resp-final",
                    segments: [.text(Transcript.TextSegment(content: "The final answer."))])),
        ]

        let seeded = SessionProjection()
        seeded.seed(from: Transcript(entries: entries))

        // The live projection observes the same turn in live order: the text
        // streams first, then the diff closes the entries in transcript order.
        let live = SessionProjection()
        live.apply(.textDelta("Let me check. "))
        live.apply(.textReset)
        live.apply(.textDelta("The final answer."))
        live.apply(.reasoningDelta("thinking"))
        live.apply(.entryRecorded(id: "reasoning-1", kind: .reasoning))
        live.apply(.entryRecorded(id: "resp-pre-tool", kind: .response))
        live.apply(.toolCall(id: "call-1", name: "search", argumentsJSON: call.arguments.jsonString))
        live.apply(.toolStatus(id: "call-1", status: .running, summary: nil, output: nil))
        live.apply(.entryRecorded(id: "calls-1", kind: .toolCalls))
        live.apply(
            .toolStatus(
                id: "call-1", status: .completed, summary: "NYC: sunny",
                output: [.text(id: "s-out", content: "NYC: sunny")]))
        live.apply(.entryRecorded(id: "resp-final", kind: .response))

        #expect(seeded.groupedRows == live.groupedRows)
        // Shape sanity: one call group holding the reasoning and the pre-tool
        // text, then the final answer top-level.
        #expect(seeded.groupedRows.map(\.id) == ["call-1", "resp-final"])
        guard case .toolCallGroup(let group) = seeded.groupedRows.first else {
            Issue.record("expected a leading call group, got \(seeded.groupedRows)")
            return
        }
        #expect(group.context.map(\.id) == ["reasoning-1", "resp-pre-tool"])
    }

    // MARK: - seed(from:)

    @Test("seed installs the grouped rows, and a live turn after the seed appends a new row without duplication")
    @MainActor
    func seedInstallsRowsAndLiveEventsAppendNormally() {
        let projection = SessionProjection()
        let entries: [Transcript.Entry] = [
            .response(
                Transcript.Response(
                    id: "resp-1", segments: [.text(Transcript.TextSegment(content: "restored answer"))]))
        ]

        projection.seed(from: Transcript(entries: entries))

        #expect(projection.transcript.map(\.id) == ["resp-1"])
        #expect(projection.phase == .idle)

        // A later live turn appends its own row: the seeded text row already
        // adopted its entry id, so the new fragment must not coalesce into it.
        projection.apply(.textDelta("new turn"))
        projection.apply(.entryRecorded(id: "resp-2", kind: .response))

        #expect(projection.transcript.map(\.id) == ["resp-1", "resp-2"])
        #expect(projection.transcript.map(\.kind) == [.text("restored answer"), .text("new turn")])
    }

    @Test("seed resets the projection to mirror the cold transcript alone")
    @MainActor
    func seedReplacesEarlierObservedState() {
        let projection = SessionProjection()
        projection.apply(.textDelta("stale live text"))
        projection.apply(.turnEnded(TokenUsage(tokensIn: 10, tokensOut: 5, contextFill: 0.5)))

        projection.seed(from: Transcript(entries: []))

        #expect(projection.transcript.isEmpty)
        #expect(projection.tokensIn == 0)
        #expect(projection.tokensOut == 0)
        #expect(projection.contextFill == 0)
        #expect(projection.currentTurn == nil)
        #expect(projection.phase == .idle)
    }

    // MARK: - Acceptance: restore a recorded tool turn and compare against the live projection

    @Test("a restored tool-turn session seeds a projection whose rows equal the live projection's rows by id, and a live turn after the seed appends without duplication")
    @MainActor
    func restoredToolTurnSeedsRowsEqualToTheLiveProjection() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // One round asking for two marker calls at once, with narrated
        // pre-tool text the SDK strands in a superseded `.response` entry,
        // then a `.reasoning` entry before the final answer — the tool-turn
        // shape the acceptance names, with two same-name calls so the id
        // pairing is load-bearing (tasks ^5aky6xr and ^8dc98vs).
        let script = ScriptedTurnScript(
            rounds: [
                [
                    ScriptedToolCall(
                        id: "call-one",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName)
                    ),
                    ScriptedToolCall(
                        id: "call-two",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(Self.secondStepName)
                    ),
                ]
            ],
            narration: "Let me look both of those up. ",
            reasoning: "scripted reasoning before the final answer"
        )
        let recorder = JSONLRecorder(directory: recordingsDir)
        let container1 = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: ScriptedTurnLog()))
        let router1 = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(container: container1, dimension: RouterTestFixtures.stubDimension)
        )
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        // The original run: a live projection mirrors the whole turn stream.
        let session = profile1.standard.makeSession(tools: [MarkerEmittingTool()])
        let liveProjection = SessionProjection()
        try await liveProjection.apply(eventsFrom: session.streamEvents(to: ScriptedToolFixture.prompt))

        // A fresh process restores the session tree, and the projection is
        // seeded from the restored session's own transcript accessor.
        let container2 = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: ScriptedTurnLog()))
        let router2 = RouterTestFixtures.makeRouter(
            id: router1.id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(container: container2, dimension: RouterTestFixtures.stubDimension)
        )
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: session.id)
        let restoredSession = restored.root

        let seeded = SessionProjection()
        seeded.seed(from: await restoredSession.transcript)

        // The seeded rows equal the live rows row for row, ids included. Row
        // ORDER deliberately differs for the one streamed row: the live
        // projection appended the answer's text row while it streamed, before
        // the diff appended the tool rows, while the seed installs rows in
        // transcript order — so the comparison joins the two sets by id.
        let liveById = Dictionary(uniqueKeysWithValues: liveProjection.transcript.map { ($0.id, $0) })
        let seededById = Dictionary(uniqueKeysWithValues: seeded.transcript.map { ($0.id, $0) })
        #expect(seededById.count == seeded.transcript.count)
        #expect(seededById == liveById)
        // Shape sanity: the turn produced the superseded narration row, two
        // tool rows, a reasoning row, and the answer's text row — all
        // adopted, none provisional.
        #expect(seeded.transcript.count == 5)

        // The grouped view agrees between the two paths, item for item —
        // the acceptance claim of task ^8dc98vs, over the real recorded
        // pipeline. The narration attaches to the first call's group; the
        // trailing reasoning and the answer stay top-level.
        #expect(seeded.groupedRows == liveProjection.groupedRows)
        guard case .toolCallGroup(let firstGroup) = seeded.groupedRows.first else {
            Issue.record("expected a leading call group, got \(seeded.groupedRows)")
            return
        }
        #expect(firstGroup.id == "call-one")
        #expect(firstGroup.context.map(\.kind) == [.text("Let me look both of those up. ")])

        // A live turn after the seed appends new rows without duplicating any
        // seeded row. The script's one round is already in the restored
        // transcript, so this turn is the answering turn: one new text row.
        let seededRows = seeded.transcript
        try await seeded.apply(eventsFrom: restoredSession.streamEvents(to: ScriptedToolFixture.prompt))

        #expect(Array(seeded.transcript.prefix(seededRows.count)) == seededRows)
        #expect(seeded.transcript.count == seededRows.count + 1)
        #expect(Set(seeded.transcript.map(\.id)).count == seeded.transcript.count)
        let expectedAnswer = ScriptedToolFixture.answer(fromToolOutputs: [
            ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName),
            ScriptedToolFixture.marker(for: Self.secondStepName),
        ])
        #expect(seeded.transcript.last?.kind == .text(expectedAnswer))
    }
}
