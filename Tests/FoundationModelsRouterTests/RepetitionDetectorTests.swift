import Foundation
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

    /// How many lines the loop of short numbered lines holds, as the report
    /// of the defect states it (task ^ez2g5gw).
    private static let numberedLoopLineCount = 1_000

    /// The first number of the loop of short numbered lines.
    private static let numberedLoopFirstNumber = 38_692

    /// The step from one number of the loop to the next.
    private static let numberedLoopStep = 8

    /// How many code blocks the normal reasoning holds: more than
    /// ``RepetitionDetection/defaultShortLineRepeatThreshold``, so each short
    /// line of a block repeats past the threshold.
    private static let codeBlockCount = 30

    /// A line long enough to count, with `label` in it.
    private static func longLine(_ label: String) -> String {
        "The reasoning checks the branch named \(label)."
    }

    /// The line of the loop of the report of the defect, with `number` in it.
    private static func numberedLine(_ number: Int) -> String {
        #"- "Fixed #\#(number)""#
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

    @Test("short lines that occur up to the threshold do not fill the window")
    func shortLinesUpToTheThresholdDoNotCount() {
        var detector = Self.makeDetector()
        let shortLines = Array(
            repeating: ["```", "\"\"\"", ")", "..."], count: RepetitionDetection.defaultShortLineRepeatThreshold
        ).flatMap { $0 }
        let lines = [Self.longLine("alpha")] + shortLines
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        #expect(finding == nil)
    }

    @Test("a loop of short lines that differ only in their digits stops within one window")
    func numberedShortLoopStops() throws {
        var detector = Self.makeDetector()
        let numbers = (0..<Self.numberedLoopLineCount).map { Self.numberedLoopFirstNumber + $0 * Self.numberedLoopStep }
        let lines = numbers.map(Self.numberedLine)
        let longestLineTokens = try #require(lines.map { $0.count + 1 }.max())

        let observed = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        let finding = try #require(observed)

        #expect(finding.newLines == 0)
        #expect(finding.tokensWithoutNewLine >= Self.window)
        #expect(finding.tokensWithoutNewLine < Self.window + longestLineTokens)
        #expect(finding.keptUTF8Lengths[Self.reasoningId] == 0)
    }

    @Test("long lines that differ only in their digits are repeats")
    func longLinesThatDifferOnlyInDigitsRepeat() throws {
        var detector = Self.makeDetector()
        let lines = (0..<Self.differentLineCount).map { Self.longLine("step \($0)") }
        let observed = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        let finding = try #require(observed)
        #expect(finding.newLines == 1)
    }

    @Test("lines that differ in text, and not only in digits, stay new")
    func linesThatDifferInTextStayNew() {
        var detector = Self.makeDetector()
        let lines = (0..<Self.differentLineCount).map { Self.longLine("\(DigitFreeLabel.spelling($0)) at step \($0)") }
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        #expect(finding == nil)
    }

    @Test("normal reasoning with code blocks does not stop")
    func reasoningWithCodeBlocksDoesNotStop() {
        var detector = Self.makeDetector()
        let lines = (0..<Self.codeBlockCount).flatMap { index in
            [Self.longLine(DigitFreeLabel.spelling(index)), "```swift", "let x = \(index)", "```", "\"\"\"", ")"]
        }
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        #expect(finding == nil)
    }

    @Test("with shape comparison off, long lines that differ only in their digits stay new")
    func shapeComparisonOffKeepsDigits() {
        var detector = RepetitionDetector(
            detection: RepetitionDetection(windowTokens: Self.window, comparesLineShapes: false),
            tokenCounter: CharacterTokenCounter())
        let lines = (0..<Self.differentLineCount).map { Self.longLine("step \($0)") }
        let finding = detector.observe([WatchedText(entryId: Self.reasoningId, text: Self.text(lines))])
        #expect(finding == nil)
    }

    @Test("a stored form with no shape keys decodes with the default of each one")
    func storedFormWithoutShapeKeysDecodesDefaults() throws {
        let stored = """
            {"isEnabled": true, "windowTokens": \(Self.window), "minimumLineLength": \
            \(RepetitionDetection.defaultMinimumLineLength), "recoveriesPerTurn": \
            \(RepetitionDetection.defaultRecoveriesPerAnswer), "passTokenLimit": \
            \(RepetitionDetection.defaultPassTokenLimit)}
            """
        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: Data(stored.utf8))
        #expect(decoded.comparesLineShapes == RepetitionDetection.defaultComparesLineShapes)
        #expect(decoded.shortLineRepeatThreshold == RepetitionDetection.defaultShortLineRepeatThreshold)
        #expect(decoded == RepetitionDetection(windowTokens: Self.window))
    }

    @Test("a detection with no default value decodes as it was encoded")
    func detectionWithNoDefaultValueRoundTrips() throws {
        let detection = RepetitionDetection(
            isEnabled: !RepetitionDetection.defaultIsEnabled,
            windowTokens: Self.window,
            minimumLineLength: RepetitionDetection.defaultMinimumLineLength + 1,
            recoveriesPerAnswer: RepetitionDetection.defaultRecoveriesPerAnswer + 1,
            passTokenLimit: RepetitionDetection.defaultPassTokenLimit + 1,
            comparesLineShapes: !RepetitionDetection.defaultComparesLineShapes,
            shortLineRepeatThreshold: RepetitionDetection.defaultShortLineRepeatThreshold + 1,
            reasoningTokenLimit: RepetitionDetection.defaultReasoningTokenLimit + 1)

        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: JSONEncoder().encode(detection))

        #expect(decoded.comparesLineShapes == !RepetitionDetection.defaultComparesLineShapes)
        #expect(decoded.shortLineRepeatThreshold == RepetitionDetection.defaultShortLineRepeatThreshold + 1)
        #expect(decoded == detection)
    }

    @Test("the log line names each shape setting")
    func logLineNamesTheShapeSettings() {
        let values = RepetitionDetection().loggedValues
        #expect(values.contains("comparesLineShapes = \(RepetitionDetection.defaultComparesLineShapes)"))
        #expect(values.contains("shortLineRepeatThreshold = \(RepetitionDetection.defaultShortLineRepeatThreshold)"))
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
        let lines = (0..<Self.differentLineCount).map { Self.longLine("step \(DigitFreeLabel.spelling($0))") }
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
