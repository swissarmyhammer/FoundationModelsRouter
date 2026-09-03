import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The wall-clock ceiling this suite runs under.
///
/// Every test drives a scripted turn, and one of them reads the turn's stream
/// until the report arrives. A turn that never produced the report would
/// suspend on the gated second round for ever, so the suite states a bound.
private let mountedRunAttachmentCarrierTimeLimitMinutes = 1

/// The document ``MountFixtures/firstAttachment`` carries, decoded back into
/// the shape its ``ToolCallAttachment/schemaName`` names.
///
/// The Router treats `contentJSON` as opaque, so this type stands for the
/// `FileChangeSet` a host decodes on the far end of the carrier.
private struct FileChangeSetProbe: Decodable, Equatable {
    /// One changed path, and what happened to it.
    struct Change: Decodable, Equatable {
        /// The path that changed.
        let path: String

        /// What the verb did to it.
        let kind: String
    }

    /// Every change the record names, in the order the record holds them.
    let changes: [Change]
}

/// Proves the carrier a mounted (nested) tool call's records ride to an ACP
/// client — the route ``ToolContext/mount(_:op:as:)`` gives a file verb that a
/// `runCode` call dispatches.
///
/// Two facts have to hold for a record a mounted call attaches to reach a wire
/// client, and each test below holds one of them:
///
/// 1. **Live delivery.** The record reaches ``SessionEvent/toolCallReport(_:)``
///    on the turn's own stream, DURING the turn, and not only through the
///    recording.
/// 2. **The correct key.** That report carries the MOUNTING run's
///    `completionToken` — the outer call's token, the one `toolCallId` a wire
///    client knows. A report keyed to the inner verb's own token would reach no
///    visible tool call.
///
/// `ToolContextMountTests` proves the correlation at the decorator level,
/// against a recording sink with no session behind it, and
/// `ToolInvocationLivenessTests` proves live delivery for a call that attaches
/// on its OWN context. This suite is the join: a real session turn whose tool
/// mounts another tool, read off `streamEvents(to:)`.
@Suite(
    "Mounted-run attach carrier: a nested call's records ride the mounting run's live report",
    .timeLimit(.minutes(mountedRunAttachmentCarrierTimeLimitMinutes))
)
struct MountedRunAttachmentCarrierTests {
    private typealias Fixtures = MountFixtures

    /// The temp directory prefix every fixture of this suite is built with, so
    /// a leaked directory is attributable.
    private static let tempDirPrefix = "MountedRunAttachmentCarrierTests"

    /// The scripted id of the call that reaches the mounting tool. It is Apple's
    /// `Transcript.ToolCall.id` space, never a run's `completionToken`.
    private static let mountingCallID = "call-mounting"

    /// The scripted id of the call that holds the turn open.
    private static let gatedCallID = "call-gated"

    /// The tool the mounting call names: it mounts ``MountFixtures/AttachingTool``
    /// on its own context and calls it in band, so every record on its run came
    /// from the mounted call.
    private static let mountingTool = Fixtures.NestingAttachingTool()

    /// One scripted round that calls `tool` one time, naming
    /// ``ScriptedToolFixture/firstStepName``.
    ///
    /// - Parameters:
    ///   - id: The call's own `Transcript.ToolCall.id`.
    ///   - tool: The tool the call names.
    /// - Returns: The one round.
    private static func round(id: String, calling tool: any Tool) -> [ScriptedToolCall] {
        [
            ScriptedToolCall(
                id: id, toolName: tool.name,
                argument: .literal(ScriptedToolFixture.firstStepName))
        ]
    }

    /// Builds a session whose only tools are `tools`, playing `script`.
    ///
    /// - Parameters:
    ///   - script: The turn shape the scripted model plays out.
    ///   - tools: The tools the session mounts.
    /// - Returns: The vended fixture. The caller removes its directory.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFixture(
        playing script: ScriptedTurnScript, mounting tools: [any Tool]
    ) async throws -> ScriptedSessionFixture {
        try await ScriptedSessionFixture.make(
            playing: script, mounting: tools, tempDirPrefix: tempDirPrefix)
    }

    /// Drives one turn whose single call reaches ``mountingTool``, and returns
    /// the turn's events in stream order.
    ///
    /// - Returns: Every event the turn's stream carried.
    /// - Throws: Whatever the fixture or the turn throws.
    private static func mountingTurnEvents() async throws -> [SessionEvent] {
        let fixture = try await makeFixture(
            playing: ScriptedTurnScript(rounds: [round(id: mountingCallID, calling: mountingTool)]),
            mounting: [mountingTool])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        return try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)
    }

    // MARK: - Fact 1: the report is delivered live, during the turn

    @Test(
        "a mounted call's records reach the turn's own stream as one toolCallReport, while the turn is still in flight"
    )
    @MainActor
    func mountedCallReportArrivesOnTheTurnStreamMidTurn() async throws {
        // The second round blocks until this test opens the gate, so the turn
        // cannot end before then. A report read off the stream above that line
        // was therefore delivered mid-turn, and not by the turn's completion.
        let gate = RunLatch()
        let gatedTool = Fixtures.GatedTool(gate: gate)
        let fixture = try await Self.makeFixture(
            playing: ScriptedTurnScript(rounds: [
                Self.round(id: Self.mountingCallID, calling: Self.mountingTool),
                Self.round(id: Self.gatedCallID, calling: gatedTool),
            ]),
            mounting: [Self.mountingTool, gatedTool])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stream = await fixture.session.streamEvents(to: ScriptedToolFixture.prompt)
        var events: [SessionEvent] = []
        var liveReport: ToolCallReport?
        var iterator = stream.makeAsyncIterator()
        while liveReport == nil, let event = try await iterator.next() {
            events.append(event)
            liveReport = event.carriedReport
        }

        // The report arrived with the gate still shut: the turn is in flight.
        let report = try #require(liveReport)
        #expect(report.attachments == Fixtures.attachmentsInCallOrder)

        await gate.open()
        while let event = try await iterator.next() {
            events.append(event)
        }

        // The premise of the reading above: the gated round really ran, so the
        // turn genuinely could not have ended before the gate opened.
        #expect(
            events.contains {
                if case .toolCall(let id, _, _) = $0 { return id == Self.gatedCallID }
                return false
            })

        // Exactly one report for the whole turn, and it follows the mounting
        // call's close record — the mounted call posted none of its own.
        let closeIndex = try #require(events.firstIndex { $0.isCloseInvocation })
        let reportIndex = try #require(events.firstIndex { $0.carriedReport != nil })
        #expect(closeIndex < reportIndex)
        #expect(events.compactMap(\.carriedReport) == [report])
    }

    // MARK: - Fact 2: the report is keyed to the mounting run

    @Test(
        "the live report carries the mounting run's completionToken and stamps, never the mounted verb's own"
    )
    @MainActor
    func liveReportIsKeyedToTheMountingRun() async throws {
        let events = try await Self.mountingTurnEvents()

        // Only the mounting call's own records reach a host: one open and one
        // close, both stamped with the mounting tool. The mounted call's
        // records go nowhere, so its correlation is never visible.
        let invocations = events.compactMap(\.carriedInvocation)
        #expect(invocations.map(\.tool) == [Self.mountingTool.name, Self.mountingTool.name])
        let close = try #require(invocations.last)
        #expect(close.closedAt != nil)

        let report = try #require(events.compactMap(\.carriedReport).first)
        #expect(report.correlationID == close.correlationID)
        #expect(report.tool == close.tool)
        #expect(report.op == close.op)
        #expect(report.sessionID == close.sessionID)
        // The decisive negative: a report keyed to the inner verb would carry
        // the mounted tool's stamp, and no wire client knows that call.
        #expect(report.tool != Fixtures.AttachingTool().name)
    }

    // MARK: - The record itself survives the carrier

    @Test("each record the mounted call attached decodes back unchanged from the live report")
    @MainActor
    func attachedRecordsDecodeBackUnchanged() async throws {
        let events = try await Self.mountingTurnEvents()

        let report = try #require(events.compactMap(\.carriedReport).first)
        // The records arrive whole, and in the order the mounted call attached
        // them: the carrier copies, it never rewrites.
        #expect(report.attachments == Fixtures.attachmentsInCallOrder)

        let record = try #require(report.attachments.first)
        #expect(record.schemaName == Fixtures.firstAttachment.schemaName)
        let decoded = try JSONDecoder().decode(
            FileChangeSetProbe.self, from: Data(record.contentJSON.utf8))
        #expect(
            decoded
                == FileChangeSetProbe(
                    changes: [FileChangeSetProbe.Change(path: "Sources/App.swift", kind: "modified")]
                ))
    }
}
