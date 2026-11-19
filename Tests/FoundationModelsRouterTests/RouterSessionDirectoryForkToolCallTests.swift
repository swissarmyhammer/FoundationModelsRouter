import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// A fork that a tool of the source asks for at its own call
/// (``SessionForkCut/callingToolCall``, D205): the fork gets the history up
/// to the call and not the call, and the call gets its result in the source.
///
/// The source runs over the production backend and a scripted model that
/// calls one ``ForkingTool`` in its first submission, then answers.
@Suite struct RouterSessionDirectoryForkToolCallTests {
    /// The fixture of this suite: the production backend over a scripted
    /// model.
    private typealias Fixture = ForkFixture<LiveBackendContainer<ScriptedRoundsModel>>

    /// The prompt of the turn that calls the tool.
    private static let prompt = "fork from here"

    /// The arguments of the scripted call of the tool.
    private static let callArguments = #"{"value":"here"}"#

    /// A source that called the tool in its one turn, with its fixture and
    /// its tool.
    private struct Answered {
        /// The fixture of the source.
        let fixture: Fixture

        /// The source session.
        let source: any RoutedSession

        /// The tool that forked the source.
        let tool: ForkingTool

        /// The fork that the tool made.
        ///
        /// - Returns: The live fork.
        /// - Throws: The `#require` failure when the tool made no fork, or
        ///   the fork is not live.
        func fork() throws -> any RoutedSession {
            let summary = try #require(tool.forkSummaries.first)
            return try #require(fixture.directory.session(id: summary.id))
        }

        /// Closes the source and each fork, and removes the folders.
        func end() async {
            let forks = tool.forkSummaries.compactMap { fixture.directory.session(id: $0.id) }
            await fixture.end([source] + forks)
        }
    }

    /// Makes a source with the tool, and lets it answer ``prompt``.
    ///
    /// - Returns: The answered source.
    /// - Throws: What the resolve of the profile or the answer throws.
    private static func answer() async throws -> Answered {
        let model = ScriptedRoundsModel(
            log: RenderProbeLog(), rounds: [[ScriptedRoundCall(name: ForkingTool.toolName, arguments: callArguments)]])
        let fixture = try await Fixture.make(over: LiveBackendContainer(model: model))
        let tool = ForkingTool(directory: fixture.directory)
        let source = fixture.profile.standard.makeSession(configuration: SessionConfiguration(tools: [tool]))
        _ = try await source.respond(to: prompt)
        return Answered(fixture: fixture, source: source, tool: tool)
    }

    /// The history position of the `.toolOutput` entry of the answered
    /// source: the instructions, the prompt and the round come before it.
    private static let toolOutputPosition = 3

    /// The history position of the round of the answered source.
    private static let roundPosition = 2

    @Test func aPositionInsideAnOpenRoundMovesBackBeforeTheRound() async throws {
        let answered = try await Self.answer()

        let fork = try await answered.fixture.fork(
            answered.source, at: .historyPosition(Self.toolOutputPosition))

        let record = try #require(try SessionIndexFile.read(in: fork.recordingDirectory))
        #expect(record.forkedAtHistoryOrdinal == Self.roundPosition)
        await fork.close()
        await answered.end()
    }

    @Test func theForkHasNoToolCall() async throws {
        let answered = try await Self.answer()

        let transcript = try await answered.fork().transcript

        #expect(transcript.contains { ForkCutHistory.Entry($0) == .toolCalls } == false)
        await answered.end()
    }

    @Test func theForkEndsWithThePromptOfTheCallingTurn() async throws {
        let answered = try await Self.answer()

        let transcript = try await answered.fork().transcript

        #expect(transcript.promptTexts == [Self.prompt])
        await answered.end()
    }

    @Test func theSourceGetsTheResultOfTheCall() async throws {
        let answered = try await Self.answer()

        let fork = try answered.fork()

        let outputs = ScriptedToolCallingModel.Executor.toolOutputTexts(in: await answered.source.transcript)
        #expect(outputs == [ForkingTool.outputPrefix + fork.id.description])
        await answered.end()
    }
}
