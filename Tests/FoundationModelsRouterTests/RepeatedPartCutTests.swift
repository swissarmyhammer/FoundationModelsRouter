import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^0dcsd3t: after a repetition stop, the render keeps only the lines of
/// a watched entry that are not repeats, also when the loop puts a new line
/// between its repeats. The counter is the ``CharacterTokenCounter``: one
/// token per character.
@Suite("The cut of a repetition stop keeps only the new lines")
struct RepeatedPartCutTests {
    /// The window of every detector of this suite.
    private static let window = 100

    /// The entry id of the watched reasoning entry.
    private static let reasoningId = "reasoning"

    /// A line long enough to count, with `label` in it.
    private static func longLine(_ label: String) -> String {
        "The reasoning checks the branch named \(label)."
    }

    /// `lines`, each followed by a line feed.
    private static func text(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// A reasoning entry with `text`, under ``reasoningId``.
    private static func reasoningEntry(_ text: String) -> Transcript.Entry {
        .reasoning(Transcript.Reasoning(id: reasoningId, segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// The text of the reasoning entry among `entries`.
    private static func reasoningText(in entries: [Transcript.Entry]) -> String? {
        entries.lazy.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return WatchedText.text(of: reasoning.segments)
        }.first
    }

    /// A loop that puts a new line between its repeats: one repeat, then a
    /// new line, then one repeat, then a new line, then repeats that fill the
    /// window. Each repeat is shorter than the window, so only the last
    /// repeats stop the call.
    private static var loopWithNewLinesBetween: (lines: [String], newLines: [String]) {
        let first = longLine("alpha")
        let second = longLine("beta")
        let third = longLine("gamma")
        let fourth = longLine("delta")
        let lines = [first, second, first, third, second, fourth, first, second, third]
        return (lines, [first, second, third, fourth])
    }

    @Test("a loop with a new line between its repeats keeps only the new lines in the render")
    func loopWithNewLinesBetweenKeepsOnlyNewLines() throws {
        var detector = RepetitionDetector(
            detection: RepetitionDetection(windowTokens: Self.window), tokenCounter: CharacterTokenCounter())
        let loop = Self.loopWithNewLinesBetween
        let text = Self.text(loop.lines)

        let observed = detector.observe([WatchedText(entryId: Self.reasoningId, text: text, isReasoning: true)])
        let finding = try #require(observed)
        let lastNewLineEnd = Self.text(Array(loop.lines.prefix(6))).utf8.count
        #expect(finding.keptUTF8Lengths[Self.reasoningId] == lastNewLineEnd)

        let render = RepeatedPartRemoval.renderAfterStop(
            of: [Self.reasoningEntry(text)], keptUTF8Lengths: finding.keptUTF8Lengths,
            keptUTF8Ranges: finding.keptUTF8Ranges, closureText: RoutedSessionActor.reasoningClosureText)
        #expect(Self.reasoningText(in: render.entries) == Self.text(loop.newLines))
    }

    @Test("a restore makes the same cut from the recorded change, and a change from before the ranges keeps a prefix")
    func recordedChangeCutsAsTheLiveRender() throws {
        var detector = RepetitionDetector(
            detection: RepetitionDetection(windowTokens: Self.window), tokenCounter: CharacterTokenCounter())
        let loop = Self.loopWithNewLinesBetween
        let text = Self.text(loop.lines)
        let observed = detector.observe([WatchedText(entryId: Self.reasoningId, text: text, isReasoning: true)])
        let finding = try #require(observed)
        let recorded = Self.reasoningEntry(text)
        let live = RepeatedPartRemoval.renderAfterStop(
            of: [recorded], keptUTF8Lengths: finding.keptUTF8Lengths,
            keptUTF8Ranges: finding.keptUTF8Ranges, closureText: RoutedSessionActor.reasoningClosureText)

        let stored = try JSONEncoder().encode(live.change)
        var cut = RenderCut()
        cut.add(try JSONDecoder().decode(RepeatedPartRemovalSegment.Content.self, from: stored))
        #expect(RepeatedPartRemoval.render(of: [recorded], applying: cut) == live.entries)

        let oldJournal = Data(#"{"keptUTF8Lengths": {"reasoning": 20}}"#.utf8)
        var oldCut = RenderCut()
        oldCut.add(try JSONDecoder().decode(RepeatedPartRemovalSegment.Content.self, from: oldJournal))
        let oldRender = RepeatedPartRemoval.render(of: [recorded], applying: oldCut)
        #expect(Self.reasoningText(in: oldRender) == String(decoding: text.utf8.prefix(20), as: UTF8.self))
    }

    @Test("a render whose last pass wrote only reasoning gets a closing response after it")
    func reasoningOnlyRenderIsClosed() throws {
        let prompt = Transcript.Entry.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "go"))]))
        let reasoning = Self.reasoningEntry(Self.text([Self.longLine("alpha")]))

        let render = RepeatedPartRemoval.renderAfterStop(
            of: [prompt, reasoning], keptUTF8Lengths: [:], keptUTF8Ranges: [:],
            closureText: RoutedSessionActor.reasoningClosureText)

        let closure = try #require(render.change.reasoningClosure)
        #expect(closure.afterEntryId == reasoning.id)
        #expect(render.entries == [prompt, reasoning, closure.response])
        var cut = RenderCut()
        cut.add(render.change)
        #expect(RepeatedPartRemoval.render(of: [prompt, reasoning], applying: cut) == render.entries)
    }
}
