import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The turn cut of a fork of a source that compacted (D205): the turn index
/// counts the turns that the compaction folded, a cut after the compaction
/// gets the summary and the turns after it, and a cut in the folded range is
/// refused.
@Suite struct RouterSessionDirectoryForkCompactionTests {
    /// The fixture of this suite: stub backends that the test can compact.
    private typealias Fixture = ForkFixture<RetainingLLMContainer>

    /// The answer of each call: long, so that one summary makes the live
    /// context of six answers smaller.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// The turns of the source before its compaction: turns 0 to 5.
    private static let turnsBeforeCompaction = 6

    /// The index of the turn after the compaction: the folded turns count.
    private static let turnAfterCompaction = turnsBeforeCompaction

    /// The prompt of the turn after the compaction.
    private static let promptAfterCompaction = "after the compaction"

    /// The prompt of the last turn that the compaction folded
    /// (``driveAnswers(_:on:)``).
    private static let lastFoldedPrompt = "text \(turnsBeforeCompaction - 1)"

    /// Makes a source that answers six turns, compacts them, and answers one
    /// more turn.
    ///
    /// - Returns: The fixture and the compacted source.
    /// - Throws: What the resolve of the profile, an answer or the
    ///   compaction throws.
    private static func compactedSource() async throws -> (fixture: Fixture, source: any RoutedSession) {
        let fixture = try await Fixture.make(over: RetainingLLMContainer(responseText: cannedText))
        let source = fixture.profile.standard.makeSession()
        try await driveAnswers(turnsBeforeCompaction, on: source)
        let entries = try #require(fixture.container.lastBackend).transcriptEntries()
        _ = try await source.compactAndAwait(budget: summarizingCompactionBudget(for: entries))
        _ = try await source.respond(to: promptAfterCompaction)
        return (fixture, source)
    }

    @Test func aCutAfterTheCompactionGetsTheTurnAfterIt() async throws {
        let (fixture, source) = try await Self.compactedSource()

        let fork = try await fixture.fork(source, at: .afterTurn(Self.turnAfterCompaction))

        #expect(await fork.transcript.promptTexts.last == Self.promptAfterCompaction)
        await fixture.end([source, fork])
    }

    @Test func aCutAfterTheCompactionGetsNoFoldedTurn() async throws {
        let (fixture, source) = try await Self.compactedSource()

        let fork = try await fixture.fork(source, at: .afterTurn(Self.turnAfterCompaction))

        #expect(await fork.transcript.promptTexts.contains(Self.lastFoldedPrompt) == false)
        await fixture.end([source, fork])
    }

    @Test func aCutBeforeTheTurnAfterTheCompactionGetsNoLaterTurn() async throws {
        let (fixture, source) = try await Self.compactedSource()

        let fork = try await fixture.fork(source, at: .beforeTurn(Self.turnAfterCompaction))

        #expect(await fork.transcript.promptTexts.contains(Self.promptAfterCompaction) == false)
        await fixture.end([source, fork])
    }

    @Test func aCutInTheFoldedRangeIsRefused() async throws {
        let (fixture, source) = try await Self.compactedSource()
        let cut = SessionForkCut.beforeTurn(Self.turnsBeforeCompaction - 1)

        let error = await fixture.forkError(of: source.id, at: cut)

        #expect(error == .forkCutOutOfRange(cut))
        await fixture.end([source])
    }
}
