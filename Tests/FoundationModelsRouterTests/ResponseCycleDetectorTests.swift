import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The response text of the evidence of task ^bsz6wn6.
///
/// The fixture `Fixtures/ApologyLoopResponse/response.txt` is the first
/// 16,000 characters of the response at seq 707 of the SWE-bench run of
/// Recursive Flint on django-13447 (2026-11-14, transcript
/// `01M7DNSKBHGQ8K547VC8M5638S`). The model wrote a status line, a stray
/// `</think>`, a fabricated router message, a few near-identical apology
/// sentences, and then a cycle of two apology lines to its token ceiling of
/// 16,384 tokens. The test target excludes `Fixtures`, so each suite reads
/// the file from disk at a path relative to this file.
private enum ApologyLoopFixture {
    /// The path of the fixture.
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ApologyLoopResponse/response.txt")

    /// The number of lines of the cycle of the fixture.
    static let cycleLines = 2

    /// The response text of the fixture.
    static func text() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

/// Task ^bsz6wn6: a response text that falls into a cycle of a few long lines
/// stops within a few hundred tokens of the cycle, and not only when one
/// window of ``RepetitionDetection/windowTokens`` holds no new line.
///
/// The text is ``ApologyLoopFixture``. The counter is the
/// ``CharacterTokenCounter``: one token per character.
@Suite("A response text that cycles through a few lines stops within a few hundred tokens")
struct ResponseCycleDetectorTests {
    /// The entry id of the watched response entry.
    private static let responseId = "response"

    /// The first line of the fixture that the model wrote a second time: the
    /// cycle starts at its second occurrence.
    private static let firstRepeatedLine = "I am sorry. I need to stop. I am not going to do anything else."

    /// One line of the two-line cycle that runs to the ceiling.
    private static let cycleLine = "Okay, I am stopping now. I am sorry for the confusion. I am not going to do anything else."

    /// The most characters the call may write after the end of the second
    /// occurrence of ``firstRepeatedLine`` before the stop: a few hundred
    /// tokens, about 300 tokens of a real tokenizer at about four characters
    /// a token.
    private static let stopBudget = 1_200

    /// How many items the list of similar lines holds.
    private static let listItemCount = 30

    /// The two lines of the block of the synthetic cycles.
    private static let block = [
        "The plan checker approved the plan for the admin view.",
        "I am waiting for the coder agent to finish its work.",
    ]

    /// One item of a numbered list: the items differ only in their number.
    private static func listItem(_ number: Int) -> String {
        "\(number). Check the admin view of the model class."
    }

    /// `lines`, each followed by a line feed.
    private static func text(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// ``block`` written `count` times in a row, after one line of its own.
    private static func cycle(count: Int) -> String {
        text(["The session started the plan checker agent."] + (0..<count).flatMap { _ in block })
    }

    /// The lines of `text`, each with its line feed.
    private static func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { $0 + "\n" }
    }

    /// The UTF-8 offset in `text` of the end of the second occurrence of
    /// `line` as a whole line, with its line feed.
    private static func endOfSecondOccurrence(of line: String, in text: String) throws -> Int {
        let ends = lines(of: text).reduce(into: (offset: 0, ends: [Int]())) { state, next in
            state.offset += next.utf8.count
            if next == line + "\n" { state.ends.append(state.offset) }
        }.ends
        return try #require(ends.dropFirst().first)
    }

    /// Feeds `text` to `detector` one line at a time, as the model writes it,
    /// and gives the finding with the UTF-8 length of the text read at the
    /// stop.
    ///
    /// - Parameters:
    ///   - text: The response text.
    ///   - detector: The detector to feed.
    /// - Returns: The finding and the length of the text it read, or `nil`
    ///   when the text never stops.
    private static func stop(
        of text: String, by detector: inout RepetitionDetector
    ) -> (finding: RepetitionFinding, readUTF8Length: Int)? {
        var written = ""
        for line in lines(of: text) {
            written += line
            if let finding = detector.observe([WatchedText(entryId: responseId, text: written)]) {
                return (finding, written.utf8.count)
            }
        }
        return nil
    }

    /// A detector with the default settings, or with `detection`.
    private static func makeDetector(_ detection: RepetitionDetection = RepetitionDetection()) -> RepetitionDetector {
        RepetitionDetector(detection: detection, tokenCounter: CharacterTokenCounter())
    }

    /// The finding of a default detector over `text` in one entry.
    ///
    /// - Parameters:
    ///   - text: The text of the entry.
    ///   - isReasoning: Whether the entry is a `.reasoning` entry.
    /// - Returns: The finding, or `nil`.
    private static func finding(of text: String, isReasoning: Bool = false) -> RepetitionFinding? {
        var detector = makeDetector()
        return detector.observe([WatchedText(entryId: responseId, text: text, isReasoning: isReasoning)])
    }

    @Test("the apology loop of the evidence stops within a few hundred tokens of its first repeat")
    func apologyLoopStopsSoon() throws {
        let text = try ApologyLoopFixture.text()
        let cycleStart = try Self.endOfSecondOccurrence(of: Self.firstRepeatedLine, in: text)
        var detector = Self.makeDetector()

        let stop = try #require(Self.stop(of: text, by: &detector))

        #expect(stop.readUTF8Length <= cycleStart + Self.stopBudget)
    }

    @Test("the stop of the apology loop names its block of two lines")
    func apologyLoopStopNamesItsBlock() throws {
        var detector = Self.makeDetector()

        let stop = try #require(Self.stop(of: try ApologyLoopFixture.text(), by: &detector))

        #expect(stop.finding.repeatedCycleLines == ApologyLoopFixture.cycleLines)
    }

    @Test("the stop of the apology loop keeps one copy of each line of the cycle")
    func apologyLoopKeepsOneCopyOfTheCycle() throws {
        let text = try ApologyLoopFixture.text()
        var detector = Self.makeDetector()
        let stop = try #require(Self.stop(of: text, by: &detector))
        let keptLength = try #require(stop.finding.keptUTF8Lengths[Self.responseId])

        let kept = String(decoding: text.utf8.prefix(keptLength), as: UTF8.self)

        #expect(kept.components(separatedBy: Self.cycleLine).count - 1 == 1)
    }

    @Test("with no cycle limit, the apology loop stops only when the window fills")
    func noCycleLimitLeavesTheWindow() throws {
        var detector = Self.makeDetector(RepetitionDetection(responseCycleRepeatLimit: nil))

        let stop = try #require(Self.stop(of: try ApologyLoopFixture.text(), by: &detector))

        #expect(stop.finding.repeatedCycleLines == nil)
    }

    @Test("a numbered list of similar lines in a response does not stop")
    func similarListLinesDoNotStop() {
        let list = Self.text((1...Self.listItemCount).map(Self.listItem))

        #expect(Self.finding(of: list) == nil)
    }

    @Test("a block written one time less than the limit does not stop")
    func blockBelowTheLimitDoesNotStop() {
        let cycle = Self.cycle(count: RepetitionDetection.defaultResponseCycleRepeatLimit - 1)

        #expect(Self.finding(of: cycle) == nil)
    }

    @Test("a block written as often as the limit stops")
    func blockAtTheLimitStops() {
        let cycle = Self.cycle(count: RepetitionDetection.defaultResponseCycleRepeatLimit)

        #expect(Self.finding(of: cycle)?.repeatedCycleLines == Self.block.count)
    }

    @Test("a cycle in a reasoning entry is left to the window")
    func reasoningCycleIsLeftToTheWindow() {
        let cycle = Self.cycle(count: RepetitionDetection.defaultResponseCycleRepeatLimit)

        #expect(Self.finding(of: cycle, isReasoning: true) == nil)
    }

    @Test("a stored form with no cycle key decodes with the default limit")
    func storedFormWithoutCycleKeyDecodesTheDefault() throws {
        let stored = try JSONEncoder().encode(RepetitionDetection())
        var object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        object["responseCycleRepeatLimit"] = nil

        let decoded = try JSONDecoder().decode(
            RepetitionDetection.self, from: try JSONSerialization.data(withJSONObject: object))

        #expect(decoded.responseCycleRepeatLimit == RepetitionDetection.defaultResponseCycleRepeatLimit)
    }

    @Test("a stored null cycle limit decodes as no limit")
    func storedNullCycleLimitRoundTrips() throws {
        let detection = RepetitionDetection(responseCycleRepeatLimit: nil)

        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: JSONEncoder().encode(detection))

        #expect(decoded == detection)
    }

    @Test("the log line names the cycle limit")
    func logLineNamesTheCycleLimit() {
        #expect(
            RepetitionDetection().loggedValues.contains(
                "responseCycleRepeatLimit = \(RepetitionDetection.defaultResponseCycleRepeatLimit)"))
    }

    @Test("the stop report names the block of the cycle")
    func stopReportNamesTheBlock() {
        let stop = RepetitionStop(
            generatedTokens: 0, countedLines: 0, newLines: 0, tokensWithoutNewLine: 0,
            detection: RepetitionDetection(), recovery: nil, repeatedCycleLines: ApologyLoopFixture.cycleLines)

        #expect(
            stop.description.contains(
                "a block of \(ApologyLoopFixture.cycleLines) lines \(RepetitionDetection.defaultResponseCycleRepeatLimit) times"))
    }
}

/// Task ^bsz6wn6: the watch of a session stops a call whose response text
/// cycles, and the repetition recovery of the answer follows.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``StagedReasoningModel``, with no GPU in the loop. The script plays
/// one reasoning line, then the response text of ``ApologyLoopFixture``, and
/// holds until the session stops it. The model reasons only when asked to
/// (``ReasoningControl/switchable``), so the stray `</think>` of the text does
/// not stop the call (task ^07vtf4a), and the cycle does.
@Suite("The watch stops a response text that cycles, and the recovery follows")
struct ResponseCycleStopTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ResponseCycleStopTests"

    /// The prompt of the answer.
    private static let prompt = "check the plan"

    /// The model calls of the answer: the call that the session stops, and
    /// the one recovery after it.
    private static let callsWithRecovery = 2

    /// Runs one answer whose first call writes the apology loop and holds
    /// until the session stops it.
    ///
    /// - Returns: The fixture and the events of the answer.
    /// - Throws: What reading the fixture, the session fixture or the answer
    ///   throws.
    private static func runStoppedAnswer() async throws -> (
        fixture: StagedReasoningSessionFixture, events: [SessionEvent]
    ) {
        var script = RepeatingReasoningScript(reasoningLines: ["Now wait for the checker."], hold: .noHold)
        script.leadingText = try ApologyLoopFixture.text()
        script.leadingTextHold = .untilStopped
        return try await StagedReasoningSessionFixture.answer(
            to: prompt, scripts: [script], detection: RepetitionDetection(), tempDirPrefix: tempDirPrefix)
    }

    @Test("the call stops at the cycle of the response text")
    func callStopsAtTheCycle() async throws {
        let (fixture, events) = try await Self.runStoppedAnswer()
        defer { await fixture.end() }

        #expect(events.repetitionStops.map(\.repeatedCycleLines) == [ApologyLoopFixture.cycleLines])
    }

    @Test("a recovery call follows the stop")
    func recoveryFollowsTheStop() async throws {
        let (fixture, _) = try await Self.runStoppedAnswer()
        defer { await fixture.end() }

        #expect(fixture.log.renders.count == Self.callsWithRecovery)
    }
}
