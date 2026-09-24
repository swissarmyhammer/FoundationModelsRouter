import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The line rule of ``RepetitionDetector`` (task ^1hcwaqy), over text alone.
/// The counter is the ``CharacterTokenCounter``: one token per character.
@Suite("The repetition detector reads the share of new lines")
struct RepetitionDetectorTests {
    /// The window of every detector of this suite.
    private static let window = 100

    /// The entry id of the watched reasoning entry.
    private static let reasoningId = "reasoning"

    /// The entry id of the watched response entry.
    private static let responseId = "response"

    /// A line long enough to count, with `label` in it.
    private static func longLine(_ label: String) -> String {
        "The reasoning checks the branch named \(label)."
    }

    /// A detector with ``window`` and the default minimum line length.
    private static func makeDetector() -> RepetitionDetector {
        RepetitionDetector(detection: RepetitionDetection(windowTokens: window), tokenCounter: CharacterTokenCounter())
    }

    /// `lines`, each followed by a line feed.
    private static func text(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    @Test("repeated long lines that fill the window stop the call")
    func repeatedLongLinesFillTheWindow() throws {
        var detector = Self.makeDetector()
        let newLines = [Self.longLine("alpha"), Self.longLine("beta")]
        let repeated = Array(repeating: Self.longLine("alpha"), count: Self.window)
        let observed = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(newLines + repeated))])
        let finding = try #require(observed)

        #expect(finding.newLines == newLines.count)
        #expect(finding.tokensWithoutNewLine >= Self.window)
        #expect(finding.tokensWithoutNewLine < Self.window + Self.longLine("alpha").count + 1)
        #expect(finding.countedLines == finding.newLines + finding.tokensWithoutNewLine / (Self.longLine("alpha").count + 1))
        #expect(finding.keptUTF8Lengths[Self.reasoningId] == Self.text(newLines).utf8.count)
    }

    @Test("a text that grows one line at a time stops at the same point")
    func growingTextStopsWhenTheWindowFills() {
        var detector = Self.makeDetector()
        var lines = [Self.longLine("alpha")]
        var finding: RepetitionFinding?
        while finding == nil, lines.count < Self.window {
            lines.append(Self.longLine("alpha"))
            finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        }
        #expect(finding?.tokensWithoutNewLine ?? 0 >= Self.window)
        #expect(finding?.keptUTF8Lengths[Self.reasoningId] == Self.text([Self.longLine("alpha")]).utf8.count)
    }

    @Test("short lines that repeat never fill the window")
    func shortLinesDoNotCount() {
        var detector = Self.makeDetector()
        let shortLines = Array(repeating: ["```", "\"\"\"", ")", "..."], count: Self.window).flatMap { $0 }
        let lines = [Self.longLine("alpha")] + shortLines + [Self.longLine("beta")] + shortLines
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        #expect(finding == nil)
    }

    @Test("a new line empties the window")
    func newLineRestartsTheWindow() {
        var detector = Self.makeDetector()
        let almostFull = Array(repeating: Self.longLine("alpha"), count: 2)
        let lines = [Self.longLine("alpha")] + almostFull + [Self.longLine("gamma")] + almostFull
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        #expect(finding == nil)
    }

    @Test("a line with no line feed yet does not count")
    func partialLineDoesNotCount() {
        var detector = Self.makeDetector()
        let repeated = Array(repeating: Self.longLine("alpha"), count: Self.window)
        let partial = Self.text([Self.longLine("alpha")]) + repeated.joined(separator: " ")
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: partial)])
        #expect(finding == nil)
    }

    @Test("an entry that starts after the last new line is kept at zero length")
    func laterEntryIsCutWhole() throws {
        var detector = Self.makeDetector()
        let reasoning = Self.text([Self.longLine("alpha"), Self.longLine("beta")])
        let response = Self.text(Array(repeating: Self.longLine("alpha"), count: Self.window))
        let observed = detector.observe([
            WatchedText(entryId: Self.reasoningId, text: reasoning),
            WatchedText(entryId: Self.responseId, text: response),
        ])
        let finding = try #require(observed)
        #expect(finding.keptUTF8Lengths[Self.reasoningId] == reasoning.utf8.count)
        #expect(finding.keptUTF8Lengths[Self.responseId] == 0)
    }
}
