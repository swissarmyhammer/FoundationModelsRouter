import Foundation
import FoundationModels

/// One entry of a call in flight that the repetition detector reads: its id
/// and its text so far.
struct WatchedText: Sendable, Equatable {
    /// The `Transcript.Entry.id` of the entry.
    let entryId: String

    /// The joined text segments of the entry, as ``text(of:)`` joins them.
    let text: String

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

    /// The `.reasoning` and `.response` entries of `entries` that are not in
    /// `entryIdsBeforeAttempt`, in transcript order: the text of the attempt
    /// in flight.
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
                return WatchedText(entryId: entry.id, text: text(of: reasoning.segments))
            case .response(let response):
                return WatchedText(entryId: entry.id, text: text(of: response.segments))
            case .instructions, .prompt, .toolCalls, .toolOutput:
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
}

/// Reads the text of one call in flight line by line, and finds the moment
/// when one window of generated tokens holds no new line (task ^1hcwaqy).
///
/// A line is the text up to a line feed. A line counts when its length,
/// without the white space at its two ends, is at least
/// ``RepetitionDetection/minimumLineLength``. A counted line is new when the
/// call did not write the same line before, in any watched entry. The tokens
/// of each counted line that repeats fill the window, and a new line empties
/// it. A short line is neither new nor repeated, so it does not fill the
/// window.
///
/// The detector reads each entry from where it stopped the last time, so a
/// text that grows costs only its new part.
struct RepetitionDetector {
    /// The settings in force.
    private let detection: RepetitionDetection

    /// The counter of the session, for the tokens of each line.
    private let tokenCounter: any TokenCounter

    /// The counted lines the call wrote, without white space at the ends.
    private var seenLines: Set<String> = []

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

    /// The byte that ends a line.
    private static let lineFeed = UInt8(ascii: "\n")

    /// Creates a detector for one call.
    ///
    /// - Parameters:
    ///   - detection: The settings in force.
    ///   - tokenCounter: The counter of the session.
    init(detection: RepetitionDetection, tokenCounter: any TokenCounter) {
        self.detection = detection
        self.tokenCounter = tokenCounter
    }

    /// Reads the complete lines that `texts` added since the last call.
    ///
    /// - Parameter texts: The watched entries of the call, in transcript order.
    /// - Returns: The finding when one window of repeated lines filled, else `nil`.
    mutating func observe(_ texts: [WatchedText]) -> RepetitionFinding? {
        for watched in texts {
            if let finding = readCompleteLines(of: watched) {
                return finding
            }
        }
        return nil
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
        }
        var lineStart = utf8.index(utf8.startIndex, offsetBy: start)
        while let lineEnd = utf8[lineStart...].firstIndex(of: Self.lineFeed) {
            let line = String(decoding: utf8[lineStart..<lineEnd], as: UTF8.self)
            start += utf8.distance(from: lineStart, to: lineEnd) + 1
            lineStarts[watched.entryId] = start
            lineStart = utf8.index(after: lineEnd)
            if let finding = read(line: line) {
                return finding
            }
        }
        lineStarts[watched.entryId] = start
        return nil
    }

    /// Reads one complete line.
    ///
    /// - Parameter line: The line, without its line feed.
    /// - Returns: The finding when this line filled the window, else `nil`.
    private mutating func read(line: String) -> RepetitionFinding? {
        let lineTokens = tokenCounter.count(line + "\n")
        generatedTokens += lineTokens
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= detection.minimumLineLength else { return nil }
        countedLines += 1
        guard !seenLines.insert(trimmed).inserted else {
            newLines += 1
            tokensWithoutNewLine = 0
            lineStartsAtNewLine = lineStarts
            return nil
        }
        tokensWithoutNewLine += lineTokens
        guard tokensWithoutNewLine >= detection.windowTokens else { return nil }
        return finding()
    }

    /// The finding of the moment the window filled.
    private func finding() -> RepetitionFinding {
        let kept = Dictionary(
            uniqueKeysWithValues: watchedEntryIds.map { ($0, lineStartsAtNewLine[$0] ?? 0) })
        return RepetitionFinding(
            generatedTokens: generatedTokens, countedLines: countedLines, newLines: newLines,
            tokensWithoutNewLine: tokensWithoutNewLine, keptUTF8Lengths: kept)
    }
}
