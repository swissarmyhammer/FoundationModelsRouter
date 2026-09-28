import FoundationModels
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

    /// The entry id of a watched tool-calls entry.
    private static let toolCallsId = "tool-calls"

    /// How many different lines the snippet that does not stop holds.
    private static let differentLineCount = 30

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

    @Test("a JSON string with \\n escapes splits into lines, so its repeated lines fill the window")
    func escapedLineFeedsSplitIntoLines() throws {
        var detector = Self.makeDetector()
        let repeated = Array(repeating: Self.longLine("alpha"), count: Self.window)
        let escapedSnippet = ([Self.longLine("beta")] + repeated).map { $0 + #"\n"# }.joined()
        let argumentsJSON = #"{"code": ""# + escapedSnippet + #""}"#

        let text = ToolCallArgumentsText.text(ofArgumentsJSON: argumentsJSON)
        #expect(text == Self.text([Self.longLine("beta")] + repeated))

        let observed = detector.observe([WatchedText(entryId: Self.toolCallsId, text: text)])
        let finding = try #require(observed)
        #expect(finding.newLines == 2)
        #expect(finding.tokensWithoutNewLine >= Self.window)
    }

    @Test("30 different lines of a JSON string do not fill the window")
    func differentEscapedLinesDoNotStop() {
        var detector = Self.makeDetector()
        let lines = (0..<Self.differentLineCount).map { Self.longLine("step \($0)") }
        let argumentsJSON = #"{"code": ""# + lines.map { $0 + #"\n"# }.joined() + #""}"#

        let text = ToolCallArgumentsText.text(ofArgumentsJSON: argumentsJSON)
        #expect(detector.observe([WatchedText(entryId: Self.toolCallsId, text: text)]) == nil)
    }
}

/// The text of the arguments of a tool call, as the repetition watch reads
/// them (task ^dzw15st): the string values of the JSON, decoded, each on its
/// own lines.
@Suite("The repetition watch reads the string values of tool-call arguments")
struct ToolCallArgumentsTextTests {
    /// The name of the tool of each call of this suite.
    private static let toolName = "runCode"

    @Test("a key is not text, and a closed value ends with a line feed")
    func keysAreNotText() {
        #expect(ToolCallArgumentsText.text(ofArgumentsJSON: #"{"code": "x = 1"}"#) == "x = 1\n")
    }

    @Test("a value that ends with a line feed gets no second one")
    func valueWithTrailingLineFeedKeepsOne() {
        #expect(ToolCallArgumentsText.text(ofArgumentsJSON: #"{"code": "a\nb\n"}"#) == "a\nb\n")
    }

    @Test("each JSON escape is decoded")
    func escapesAreDecoded() {
        let json = #"{"code": "say \"hi\"\\path\ttab\r\/slash \u00e9 \ud83d\ude00\b\f"}"#
        let text = ToolCallArgumentsText.text(ofArgumentsJSON: json)
        #expect(text == "say \"hi\"\\path\ttab\r/slash \u{e9} \u{1F600}\u{8}\u{c}\n")
    }

    @Test("the values of nested objects and arrays are read in order, and numbers are not text")
    func nestedValuesAreRead() {
        let json = #"{"a": ["one", {"b": "two"}], "n": 3, "flag": true, "c": "three"}"#
        #expect(ToolCallArgumentsText.text(ofArgumentsJSON: json) == "one\ntwo\nthree\n")
    }

    @Test("a string that is not closed gives its text so far, with no line feed added")
    func openStringGivesItsTextSoFar() {
        #expect(ToolCallArgumentsText.text(ofArgumentsJSON: #"{"code": "line one\nline tw"#) == "line one\nline tw")
    }

    @Test("an escape cut at the end of the text gives the text before it")
    func cutEscapeIsDropped() {
        #expect(ToolCallArgumentsText.text(ofArgumentsJSON: #"{"code": "ab\"#) == "ab")
        #expect(ToolCallArgumentsText.text(ofArgumentsJSON: #"{"code": "ab\u00"#) == "ab")
    }

    @Test("the attempt texts hold the decoded arguments of a tool-calls entry")
    func attemptTextsReadToolCalls() throws {
        let arguments = try GeneratedContent(json: #"{"code": "first line\nsecond line\n"}"#)
        let calls = Transcript.ToolCalls([
            Transcript.ToolCall(id: "call-1", toolName: Self.toolName, arguments: arguments)
        ])
        let entry = Transcript.Entry.toolCalls(calls)

        let texts = WatchedText.attemptTexts(in: [entry], excluding: [])
        #expect(texts == [WatchedText(entryId: entry.id, text: "first line\nsecond line\n")])
        #expect(WatchedText.attemptTexts(in: [entry], excluding: [entry.id]).isEmpty)
    }

    @Test("the render keeps a watched tool-calls entry whole, also at a kept length of zero")
    func renderKeepsToolCallsWhole() throws {
        let arguments = try GeneratedContent(json: #"{"code": "print(1)\n"}"#)
        let entry = Transcript.Entry.toolCalls(
            Transcript.ToolCalls([Transcript.ToolCall(id: "call-1", toolName: Self.toolName, arguments: arguments)]))

        let render = RepeatedPartRemoval.render(of: [entry], keeping: [entry.id: 0])
        #expect(render == [entry])
    }
}
