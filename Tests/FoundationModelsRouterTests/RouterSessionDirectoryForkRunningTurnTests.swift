import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// A turn cut of a source whose answer runs (D205): the mail of the running
/// submission gives the turns of that submission
/// (``RunningSubmission/deliveredMail``).
///
/// The source runs over the production backend and a scripted model that
/// plays two rounds in each turn: a call of ``MountFixtures/FastTool``, then
/// a call of ``TurnCutForkingTool``, and then it answers. The result of the
/// first call is a settled point of the source, so the settled transcript
/// holds the prompt of the running submission when the second call forks.
/// The fork comes from inside the running answer, where the SDK waits in the
/// tool call, so the turn runs while the fork reads it, with no clock.
@Suite struct RouterSessionDirectoryForkRunningTurnTests {
    /// The fixture of this suite: the production backend over a scripted
    /// model.
    private typealias Fixture = ForkFixture<LiveBackendContainer<ScriptedRoundsModel>>

    /// The prompt of the complete turn of each source (turn 0).
    private static let firstPrompt = "first"

    /// The prompt of the answer that runs while the tool forks (turn 1).
    private static let runningPrompt = "second"

    /// The text of the run message whose mail-only answer runs while the
    /// tool forks.
    private static let runMessage = "run news"

    /// The arguments of each scripted call.
    private static let callArguments = #"{"value":"here"}"#

    /// The history position of the prompt of turn 1: the instructions, and
    /// turn 0 with its prompt, its two rounds with their outputs and its
    /// response, come before it.
    private static let runningPromptPosition = 7

    /// A source with one complete turn, with its fixture and its forking
    /// tool.
    private struct Source {
        /// The fixture of the source.
        let fixture: Fixture

        /// The source session.
        let session: any RoutedSession

        /// The tool that forks the source in the running answer.
        let tool: TurnCutForkingTool

        /// The outcome of the fork of the armed call.
        ///
        /// - Returns: The outcome.
        /// - Throws: The `#require` failure when no armed call ran.
        func outcome() throws -> Result<SessionSummary, SessionDirectoryError> {
            try #require(tool.outcome)
        }

        /// Closes the source and the fork that the tool made, and removes
        /// the folders.
        func end() async {
            let fork = (try? tool.outcome?.get()).flatMap { fixture.directory.session(id: $0.id) }
            await fixture.end([session] + (fork.map { [$0] } ?? []))
        }
    }

    /// Makes a source with the two tools, and lets it answer
    /// ``firstPrompt`` with no armed cut.
    ///
    /// - Returns: The source with one complete turn.
    /// - Throws: What the resolve of the profile or the answer throws.
    private static func sourceWithOneTurn() async throws -> Source {
        let model = ScriptedRoundsModel(
            log: RenderProbeLog(),
            rounds: [
                [ScriptedRoundCall(name: MountFixtures.FastTool().name, arguments: callArguments)],
                [ScriptedRoundCall(name: TurnCutForkingTool.toolName, arguments: callArguments)],
            ],
            replaysEachTurn: true)
        let fixture = try await Fixture.make(over: LiveBackendContainer(model: model))
        let tool = TurnCutForkingTool(directory: fixture.directory)
        let session = fixture.profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [MountFixtures.FastTool(), tool]))
        _ = try await session.respond(to: firstPrompt)
        return Source(fixture: fixture, session: session, tool: tool)
    }

    /// The production change that makes this test fail: a running
    /// submission whose delivered mail the fork does not read, so the
    /// running turn does not exist and the cut is out of range.
    @Test func aCutBeforeTheRunningTurnIsThePromptOfTheRunningSubmission() async throws {
        let source = try await Self.sourceWithOneTurn()
        source.tool.arm(.beforeTurn(1))

        _ = try await source.session.respond(to: Self.runningPrompt)

        let fork = try #require(source.fixture.directory.session(id: try source.outcome().get().id))
        let record = try #require(try SessionIndexFile.read(in: fork.recordingDirectory))
        #expect(record.forkedAtHistoryOrdinal == Self.runningPromptPosition)
        await source.end()
    }

    /// The production change that makes this test fail: a turn of the
    /// running submission that counts as complete.
    @Test func aCutAfterTheRunningTurnIsOutOfRange() async throws {
        let source = try await Self.sourceWithOneTurn()
        source.tool.arm(.afterTurn(1))

        _ = try await source.session.respond(to: Self.runningPrompt)

        let error = await DirectoryErrorCapture.error { try source.outcome().get() }
        #expect(error == .forkCutOutOfRange(.afterTurn(1)))
        await source.end()
    }

    /// The production change that makes this test fail: a prompt of the
    /// running submission that starts a turn with no user message and no
    /// directory message in its mail.
    @Test func aCutBeforeATurnOfARunningRunMailAnswerIsOutOfRange() async throws {
        let source = try await Self.sourceWithOneTurn()
        source.tool.arm(.beforeTurn(1))
        let messaging = await MailOnlyAnswerFixtures.MessagingRun.start(on: source.session)

        await messaging.send(Self.runMessage)

        let error = await DirectoryErrorCapture.error { try source.outcome().get() }
        #expect(error == .forkCutOutOfRange(.beforeTurn(1)))
        await messaging.gate.open()
        await source.end()
    }
}
