import Foundation
import FoundationModels

/// One entry of a call in flight that the repetition detector reads: its id
/// and its text so far.
struct WatchedText: Sendable, Equatable {
    /// The `Transcript.Entry.id` of the entry.
    let entryId: String

    /// The joined text segments of the entry, as ``text(of:)`` joins them, or
    /// the text of the arguments of a `.toolCalls` entry, as
    /// ``ToolCallArgumentsText/text(of:)`` reads them.
    let text: String

    /// Whether the entry is a `.reasoning` entry, whose tokens count toward
    /// ``RepetitionDetection/reasoningTokenLimit`` (task ^hm9trt5).
    let isReasoning: Bool

    /// Whether the entry is a `.toolCalls` entry, which ends the first pass of
    /// the attempt (task ^qmewzw0).
    let isToolCalls: Bool

    /// Whether the entry is a `.response` entry: the text of the answer, and
    /// neither reasoning nor tool-call arguments.
    var isResponse: Bool {
        !isReasoning && !isToolCalls
    }

    /// Creates one watched entry.
    ///
    /// - Parameters:
    ///   - entryId: The `Transcript.Entry.id` of the entry.
    ///   - text: The text of the entry so far.
    ///   - isReasoning: Whether the entry is a `.reasoning` entry.
    ///   - isToolCalls: Whether the entry is a `.toolCalls` entry.
    init(entryId: String, text: String, isReasoning: Bool = false, isToolCalls: Bool = false) {
        self.entryId = entryId
        self.text = text
        self.isReasoning = isReasoning
        self.isToolCalls = isToolCalls
    }

    /// The joined text of the `.text` segments of `segments`. The detector
    /// and the removal of the repeated part both read an entry through this
    /// one join, so their offsets agree.
    ///
    /// The watch reads a growing entry again at each change of the
    /// transcript. An entry of one text segment, the usual shape of a
    /// reasoning entry, gives its content with no copy.
    ///
    /// - Parameter segments: The segments of a `.reasoning` or `.response` entry.
    /// - Returns: The text of the text segments, in order.
    static func text(of segments: [Transcript.Segment]) -> String {
        if segments.count == 1, case .text(let only) = segments[0] {
            return only.content
        }
        return segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }.joined()
    }

    /// The `.reasoning`, `.response` and `.toolCalls` entries of `entries`
    /// that are not in `entryIdsBeforeAttempt`, in transcript order: the text
    /// of the attempt in flight. The text of a `.toolCalls` entry is the
    /// decoded string values of the arguments of its calls
    /// (``ToolCallArgumentsText``, task ^dzw15st).
    ///
    /// - Parameters:
    ///   - entries: The live transcript of the backend.
    ///   - entryIdsBeforeAttempt: The ids of the entries from before the attempt.
    /// - Returns: The watched texts, in transcript order.
    static func attemptTexts(
        in entries: [Transcript.Entry], excluding entryIdsBeforeAttempt: Set<String>
    ) -> [WatchedText] {
        entries.compactMap { entry in
            guard !entryIdsBeforeAttempt.contains(entry.id) else { return nil }
            switch entry {
            case .reasoning(let reasoning):
                return WatchedText(entryId: entry.id, text: text(of: reasoning.segments), isReasoning: true)
            case .response(let response):
                return WatchedText(entryId: entry.id, text: text(of: response.segments))
            case .toolCalls(let calls):
                return WatchedText(entryId: entry.id, text: ToolCallArgumentsText.text(of: calls), isToolCalls: true)
            case .instructions, .prompt, .toolOutput, .data:
                return nil
            @unknown default:
                return nil
            }
        }
    }
}

/// What the detector found when one window of repeated lines filled: the
/// counts of the stop, and the length of each watched entry that holds no
/// repeated part.
struct RepetitionFinding: Sendable, Equatable {
    /// The tokens of the complete lines the detector read.
    let generatedTokens: Int

    /// The complete lines that count.
    let countedLines: Int

    /// The counted lines that were new.
    let newLines: Int

    /// The tokens of the repeated lines since the last new line.
    let tokensWithoutNewLine: Int

    /// For each watched entry id, the UTF-8 length of its text up to the end
    /// of the last new line. The text after it is the repeated part. An
    /// entry that got text only after the last new line has length `0`.
    let keptUTF8Lengths: [String: Int]

    /// For each watched entry id, the UTF-8 ranges of its lines before the
    /// end of the last new line that are not repeats: the new lines, and the
    /// short lines that do not count yet (task ^0dcsd3t). A loop can put a
    /// new line between its repeats, so the text up to the last new line can
    /// hold many repeats; the render keeps only these ranges.
    let keptUTF8Ranges: [String: [KeptUTF8Range]]

    /// The number of long lines of the block whose cycle in a `.response`
    /// entry filled ``RepetitionDetection/responseCycleRepeatLimit``, or
    /// `nil` when the line window filled or nothing stopped (task ^bsz6wn6).
    let repeatedCycleLines: Int?
}

/// What the detector found when the reasoning entry that the call writes now
/// reached ``RepetitionDetection/reasoningTokenLimit`` (task ^hm9trt5).
struct ReasoningLimitFinding: Sendable, Equatable {
    /// The tokens of the complete lines of the reasoning entry.
    let reasoningTokens: Int

    /// The limit in force: ``RepetitionDetection/reasoningTokenLimitInForce``,
    /// or the first-pass limit of a recovery of an always-reasoning model
    /// (task ^qmewzw0).
    let limit: Int
}

/// Reads the text of one call in flight line by line, and finds the moment
/// when one window of generated tokens holds no new line (task ^1hcwaqy).
///
/// A line is the text up to a line feed. The detector compares the shape of
/// each line (``RepetitionDetection/shape(of:)``): with the default settings,
/// two lines that differ only in their digits have the same shape (task
/// ^ez2g5gw). A line is long when its shape is at least
/// ``RepetitionDetection/minimumLineLength`` long. A long line always counts,
/// and it is new when the call did not write the same shape before, in any
/// watched entry. A short line is neither new nor repeated until its shape
/// occurred ``RepetitionDetection/shortLineRepeatThreshold`` times in the
/// call. After that, each occurrence of the shape counts as a repeat. The
/// tokens of each counted line that repeats fill the window, and a new line
/// empties it.
///
/// In a `.response` entry, the detector also stops at a cycle (task
/// ^bsz6wn6): the last long lines of the entry are one block of one to
/// ``RepetitionDetection/responseCycleMaximumLines`` lines, written
/// ``RepetitionDetection/responseCycleRepeatLimit`` times in a row with the
/// same text. A model that falls into a cycle of a few sentences, with a few
/// near-identical variants before it that each count as new, thus stops
/// within a few hundred tokens, and not only after one whole window.
///
/// The detector reads each entry from where it stopped the last time, so a
/// text that grows costs only its new part.
///
/// The detector also counts the tokens of the complete lines of each
/// `.reasoning` entry (task ^hm9trt5). ``reasoningLimitFinding()`` reports
/// the entry that the call writes now when its count reaches
/// ``RepetitionDetection/reasoningTokenLimit``.
struct RepetitionDetector {
    /// The settings in force.
    private let detection: RepetitionDetection

    /// The counter of the session, for the tokens of each line.
    private let tokenCounter: any TokenCounter

    /// The shapes of the long lines the call wrote.
    private var seenShapes: Set<String> = []

    /// For each short shape, how many times the call wrote it.
    private var shortShapeOccurrences: [String: Int] = [:]

    /// For each watched entry, the UTF-8 offset of its first unread line.
    private var lineStarts: [String: Int] = [:]

    /// The watched entry ids, in the order the detector first read them.
    private var watchedEntryIds: [String] = []

    /// ``lineStarts`` at the end of the last new line.
    private var lineStartsAtNewLine: [String: Int] = [:]

    /// The tokens of the complete lines read so far.
    private var generatedTokens = 0

    /// The counted lines read so far.
    private var countedLines = 0

    /// The counted lines that were new.
    private var newLines = 0

    /// The tokens of the repeated lines since the last new line.
    private var tokensWithoutNewLine = 0

    /// For each watched `.reasoning` entry, the tokens of its complete lines.
    private var reasoningTokens: [String: Int] = [:]

    /// For each watched `.response` entry, the text of its last long lines,
    /// without the white space at their two ends: as many as the longest
    /// cycle that ``RepetitionDetection/responseCycleRepeatLimit`` reads
    /// (task ^bsz6wn6).
    private var responseLongLines: [String: [String]] = [:]

    /// For each watched entry, the UTF-8 ranges of the lines read so far
    /// that are not repeats, with each two ranges that touch merged into one
    /// (task ^0dcsd3t).
    private var keptRanges: [String: [KeptUTF8Range]] = [:]

    /// The last watched entry with text in the last ``observe(_:)``: the
    /// entry that the call writes now, or `nil` before any text.
    private var entryInFlight: WatchedText?

    /// Whether the first pass of the call ended: the call wrote a tool call,
    /// and each later entry is the output of a later pass of its tool loop
    /// (task ^qmewzw0).
    private var firstPassEnded = false

    /// The byte that ends a line.
    private static let lineFeed = UInt8(ascii: "\n")

    /// The reasoning token limit of the first pass of the call, in place of
    /// ``RepetitionDetection/reasoningTokenLimitInForce``, or `nil` when the
    /// first pass keeps the limit of the session (task ^qmewzw0).
    private let firstPassReasoningTokenLimit: Int?

    /// Creates a detector for one call.
    ///
    /// - Parameters:
    ///   - detection: The settings in force.
    ///   - tokenCounter: The counter of the session.
    ///   - firstPassReasoningTokenLimit: The reasoning token limit of the
    ///     first pass of the call, or `nil` (the default) for the limit of
    ///     the session.
    init(detection: RepetitionDetection, tokenCounter: any TokenCounter, firstPassReasoningTokenLimit: Int? = nil) {
        self.detection = detection
        self.tokenCounter = tokenCounter
        self.firstPassReasoningTokenLimit = firstPassReasoningTokenLimit
    }

    /// Reads the complete lines that `texts` added since the last call.
    ///
    /// - Parameter texts: The watched entries of the call, in transcript order.
    /// - Returns: The finding when one window of repeated lines filled, else `nil`.
    mutating func observe(_ texts: [WatchedText]) -> RepetitionFinding? {
        entryInFlight = texts.last { !$0.text.isEmpty }
        firstPassEnded = firstPassEnded || texts.contains(where: \.isToolCalls)
        for watched in texts {
            if let finding = readCompleteLines(of: watched) {
                return finding
            }
        }
        return nil
    }

    /// The finding of the reasoning limit: the entry that the call writes now
    /// is a `.reasoning` entry, and the tokens of its complete lines reached
    /// its limit (``reasoningTokenLimitOfEntryInFlight``): the first-pass
    /// limit of the call in its first pass, else
    /// ``RepetitionDetection/reasoningTokenLimitInForce``.
    ///
    /// When a `.response` or `.toolCalls` entry with text follows the
    /// reasoning entry, the pass already acts, and the limit does not stop
    /// it.
    ///
    /// - Returns: The finding, or `nil` when no limit is in force or the
    ///   entry in flight is not a reasoning entry at the limit.
    func reasoningLimitFinding() -> ReasoningLimitFinding? {
        guard let limit = reasoningTokenLimitOfEntryInFlight, let entryInFlight, entryInFlight.isReasoning,
            let tokens = reasoningTokens[entryInFlight.entryId], tokens >= limit
        else { return nil }
        return ReasoningLimitFinding(reasoningTokens: tokens, limit: limit)
    }

    /// The reasoning token limit of the entry that the call writes now:
    /// ``firstPassReasoningTokenLimit`` while the first pass of the call runs,
    /// and ``RepetitionDetection/reasoningTokenLimitInForce`` after it, or when
    /// the call has no limit of its first pass (task ^qmewzw0).
    private var reasoningTokenLimitOfEntryInFlight: Int? {
        guard let firstPassReasoningTokenLimit, !firstPassEnded else { return detection.reasoningTokenLimitInForce }
        return firstPassReasoningTokenLimit
    }

    /// The counts of the lines read so far, as a finding that cuts nothing
    /// (task ^8eq31j0): its kept lengths and kept ranges are empty, so the
    /// render keeps each watched entry whole. A stop for a loop of identical
    /// tool calls uses it, because the window did not fill and no line is the
    /// repeated part.
    ///
    /// - Returns: The finding.
    func findingThatKeepsAll() -> RepetitionFinding {
        RepetitionFinding(
            generatedTokens: generatedTokens, countedLines: countedLines, newLines: newLines,
            tokensWithoutNewLine: tokensWithoutNewLine, keptUTF8Lengths: [:], keptUTF8Ranges: [:],
            repeatedCycleLines: nil)
    }

    /// Reads the complete lines of `watched` from its first unread line.
    ///
    /// A text shorter than the part already read is a new text under the
    /// same id, and the detector reads it from its start.
    ///
    /// - Parameter watched: One watched entry.
    /// - Returns: The finding when the window filled, else `nil`.
    private mutating func readCompleteLines(of watched: WatchedText) -> RepetitionFinding? {
        let utf8 = watched.text.utf8
        if lineStarts[watched.entryId] == nil {
            watchedEntryIds.append(watched.entryId)
        }
        var start = lineStarts[watched.entryId] ?? 0
        if start > utf8.count {
            start = 0
            reasoningTokens[watched.entryId] = nil
            keptRanges[watched.entryId] = nil
            responseLongLines[watched.entryId] = nil
        }
        var lineStart = utf8.index(utf8.startIndex, offsetBy: start)
        while let lineEnd = utf8[lineStart...].firstIndex(of: Self.lineFeed) {
            let line = String(decoding: utf8[lineStart..<lineEnd], as: UTF8.self)
            let range = KeptUTF8Range(start: start, end: start + utf8.distance(from: lineStart, to: lineEnd) + 1)
            start = range.end
            lineStarts[watched.entryId] = start
            lineStart = utf8.index(after: lineEnd)
            let lineTokens = tokenCounter.count(line + "\n")
            if watched.isReasoning {
                reasoningTokens[watched.entryId, default: 0] += lineTokens
            }
            if let finding = read(line: line, lineTokens: lineTokens, range: range, of: watched) {
                return finding
            }
        }
        lineStarts[watched.entryId] = start
        return nil
    }

    /// What one complete line is to the window.
    private enum LineKind {
        /// A long line whose shape the call did not write before. It empties
        /// the window.
        case new

        /// A counted line whose shape the call wrote before. Its tokens fill
        /// the window.
        case repeated

        /// A short line whose shape did not occur more than
        /// ``RepetitionDetection/shortLineRepeatThreshold`` times. It is
        /// neither new nor repeated.
        case uncounted
    }

    /// Reads one complete line.
    ///
    /// A long line of a `.response` entry also goes into the cycle of the
    /// entry (``cycleLines(afterResponseLine:of:)``). A line that closes a
    /// cycle repeats the line one block before it, so it is always a repeat.
    ///
    /// - Parameters:
    ///   - line: The line, without its line feed.
    ///   - lineTokens: The tokens of the line, with its line feed.
    ///   - range: The UTF-8 range of the line, with its line feed, in the
    ///     text of its entry.
    ///   - watched: The entry of the line.
    /// - Returns: The finding when this line filled the window or closed a
    ///   cycle, else `nil`.
    private mutating func read(
        line: String, lineTokens: Int, range: KeptUTF8Range, of watched: WatchedText
    ) -> RepetitionFinding? {
        generatedTokens += lineTokens
        let shape = detection.shape(of: line)
        let cycle = watched.isResponse && isLong(shape) ? cycleLines(afterResponseLine: line, of: watched.entryId) : nil
        switch kind(ofShape: shape) {
        case .uncounted:
            keep(range, of: watched.entryId)
            return nil
        case .new:
            countedLines += 1
            newLines += 1
            tokensWithoutNewLine = 0
            lineStartsAtNewLine = lineStarts
            keep(range, of: watched.entryId)
            return nil
        case .repeated:
            countedLines += 1
            tokensWithoutNewLine += lineTokens
            guard tokensWithoutNewLine < detection.windowTokens else { return finding(repeatedCycleLines: nil) }
            return cycle.map { finding(repeatedCycleLines: $0) }
        }
    }

    /// Whether a line with `shape` is long: it always counts.
    ///
    /// - Parameter shape: The shape of the line.
    /// - Returns: `true` when the shape is at least
    ///   ``RepetitionDetection/minimumLineLength`` long.
    private func isLong(_ shape: String) -> Bool {
        shape.count >= detection.minimumLineLength
    }

    /// Adds the long `line` of the `.response` entry `entryId` to the last
    /// long lines of the entry, and gives the cycle that it closes (task
    /// ^bsz6wn6).
    ///
    /// - Parameters:
    ///   - line: A long line of the response entry, without its line feed.
    ///   - entryId: The id of the response entry.
    /// - Returns: The number of lines of the block that the last long lines
    ///   of the entry hold ``RepetitionDetection/responseCycleRepeatLimit``
    ///   times in a row, or `nil` when they hold no such cycle or no limit
    ///   is in force.
    private mutating func cycleLines(afterResponseLine line: String, of entryId: String) -> Int? {
        guard let repeats = detection.responseCycleRepeatLimitInForce else { return nil }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let longestCycle = RepetitionDetection.responseCycleMaximumLines * repeats
        let lines = Array((responseLongLines[entryId, default: []] + [text]).suffix(longestCycle))
        responseLongLines[entryId] = lines
        return Self.blockLines(endingCycleOf: lines, repeats: repeats)
    }

    /// The number of lines of the shortest block that ends `lines` and
    /// occurs `repeats` times in a row there, with the same text each time.
    ///
    /// - Parameters:
    ///   - lines: The last long lines of one response entry, in order.
    ///   - repeats: How many times in a row the block must occur.
    /// - Returns: The number of lines of the block, from 1 to
    ///   ``RepetitionDetection/responseCycleMaximumLines``, or `nil` when no
    ///   block ends `lines` that often.
    private static func blockLines(endingCycleOf lines: [String], repeats: Int) -> Int? {
        (1...RepetitionDetection.responseCycleMaximumLines).first { blockSize in
            let cycle = lines.suffix(blockSize * repeats)
            return cycle.count == blockSize * repeats && zip(cycle, cycle.dropFirst(blockSize)).allSatisfy(==)
        }
    }

    /// The kind of a line with `shape`, and the count of the shape.
    ///
    /// A long shape is new the first time the call writes it. A short shape
    /// counts as a repeat only after it occurred
    /// ``RepetitionDetection/shortLineRepeatThreshold`` times in the call.
    ///
    /// - Parameter shape: The shape of the line.
    /// - Returns: The kind of the line.
    private mutating func kind(ofShape shape: String) -> LineKind {
        guard isLong(shape) else {
            let occurrences = shortShapeOccurrences[shape, default: 0] + 1
            shortShapeOccurrences[shape] = occurrences
            return occurrences > detection.shortLineRepeatThreshold ? .repeated : .uncounted
        }
        return seenShapes.insert(shape).inserted ? .new : .repeated
    }

    /// Adds `range` to the kept ranges of the entry `entryId`, merged with
    /// the last range when the two touch.
    ///
    /// - Parameters:
    ///   - range: The UTF-8 range of a line that is not a repeat.
    ///   - entryId: The id of the entry of the line.
    private mutating func keep(_ range: KeptUTF8Range, of entryId: String) {
        var ranges = keptRanges[entryId] ?? []
        if let last = ranges.last, last.end == range.start {
            ranges[ranges.index(before: ranges.endIndex)] = KeptUTF8Range(start: last.start, end: range.end)
        } else {
            ranges.append(range)
        }
        keptRanges[entryId] = ranges
    }

    /// The finding of the moment the window filled or a response cycle
    /// closed.
    ///
    /// The kept ranges of each entry end at the end of its last new line:
    /// the lines after it are the repeated part.
    ///
    /// - Parameter repeatedCycleLines: The number of lines of the block whose
    ///   cycle closed, or `nil` when the window filled.
    /// - Returns: The finding.
    private func finding(repeatedCycleLines: Int?) -> RepetitionFinding {
        let kept = Dictionary(
            uniqueKeysWithValues: watchedEntryIds.map { ($0, lineStartsAtNewLine[$0] ?? 0) })
        let keptRangesUpToNewLine = Dictionary(
            uniqueKeysWithValues: kept.map { entryId, bound in
                (entryId, Self.ranges(keptRanges[entryId] ?? [], endingBy: bound))
            })
        return RepetitionFinding(
            generatedTokens: generatedTokens, countedLines: countedLines, newLines: newLines,
            tokensWithoutNewLine: tokensWithoutNewLine, keptUTF8Lengths: kept, keptUTF8Ranges: keptRangesUpToNewLine,
            repeatedCycleLines: repeatedCycleLines)
    }

    /// The parts of `ranges` before `bound`.
    ///
    /// - Parameters:
    ///   - ranges: Ranges of one entry, in order.
    ///   - bound: A UTF-8 offset at the end of a line.
    /// - Returns: The ranges cut at `bound`.
    private static func ranges(_ ranges: [KeptUTF8Range], endingBy bound: Int) -> [KeptUTF8Range] {
        ranges.compactMap { range in
            range.start < bound ? KeptUTF8Range(start: range.start, end: min(range.end, bound)) : nil
        }
    }
}
