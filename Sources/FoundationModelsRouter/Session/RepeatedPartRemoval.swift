import Foundation
import FoundationModels

/// The response that closes the reasoning that a stop cut off, in the render
/// that the model receives next (task ^0dcsd3t).
///
/// A stopped pass ends inside its reasoning: no response text follows the
/// thought. The next pass would continue that thought. So the render puts a
/// short response after the last entry of the stopped pass, before the
/// prompt of the recovery. The record holds no such entry; the
/// ``RepeatedPartRemovalSegment`` of the stop records the closure, and a
/// restore puts the same response at the same place.
struct ReasoningClosure: Codable, Equatable, Sendable {
    /// The id of the render entry that the closing response follows: the
    /// last entry of the stopped pass.
    let afterEntryId: String

    /// The id of the closing response entry.
    let responseEntryId: String

    /// The text of the closing response.
    let text: String

    /// The closure that `render` needs: when its last pass wrote only
    /// reasoning (``ReasoningOnlyOutput/trailingReasoningText(of:)``), a
    /// response with `text` after its last entry.
    ///
    /// - Parameters:
    ///   - render: The render after the stop, with the repeated part removed.
    ///   - text: The text of the closing response.
    /// - Returns: The closure, or `nil` when the last pass acted.
    static func needed(in render: [Transcript.Entry], text: String) -> ReasoningClosure? {
        guard let last = render.last, ReasoningOnlyOutput.trailingReasoningText(of: render) != nil else {
            return nil
        }
        return ReasoningClosure(afterEntryId: last.id, responseEntryId: UUID().uuidString, text: text)
    }

    /// The closing response entry. Its one text segment has the id of the
    /// entry, so the live render and a restored render hold the same entry.
    var response: Transcript.Entry {
        .response(
            Transcript.Response(
                id: responseEntryId, assetIDs: [],
                segments: [.text(Transcript.TextSegment(id: responseEntryId, content: text))]))
    }

    /// `entries` with the response of each closure of `closures` after the
    /// entry it follows. A closure whose entry `entries` does not hold adds
    /// nothing.
    ///
    /// - Parameters:
    ///   - entries: The render entries.
    ///   - closures: The closures to apply.
    /// - Returns: The closed render entries.
    static func closing(_ entries: [Transcript.Entry], with closures: [ReasoningClosure]) -> [Transcript.Entry] {
        guard !closures.isEmpty else { return entries }
        let closureByEntry = Dictionary(closures.map { ($0.afterEntryId, $0) }) { _, newer in newer }
        return entries.flatMap { entry -> [Transcript.Entry] in
            guard let closure = closureByEntry[entry.id] else { return [entry] }
            return [entry, closure.response]
        }
    }
}

/// The changes of the render that the stops of a session made, merged in
/// record order: the cut of each watched entry, and each reasoning closure
/// (tasks ^gg49g5e and ^0dcsd3t).
struct RenderCut: Equatable, Sendable {
    /// For each cut entry id, the UTF-8 length that the render keeps at most.
    var keptUTF8Lengths: [String: Int] = [:]

    /// For each cut entry id whose cut names its ranges, the ranges that the
    /// render keeps.
    var keptUTF8Ranges: [String: [KeptUTF8Range]] = [:]

    /// The reasoning closures, in record order.
    var reasoningClosures: [ReasoningClosure] = []

    /// Adds the change of one stop. A later cut of one entry id replaces an
    /// earlier one.
    ///
    /// - Parameter content: The change of one stop.
    mutating func add(_ content: RepeatedPartRemovalSegment.Content) {
        for entryId in content.keptUTF8Lengths.keys {
            keptUTF8Lengths[entryId] = content.keptUTF8Lengths[entryId]
            keptUTF8Ranges[entryId] = content.keptUTF8Ranges?[entryId]
        }
        if let closure = content.reasoningClosure {
            reasoningClosures.append(closure)
        }
    }

    /// The ranges that the render keeps of the entry `entryId`, or `nil`
    /// when the render keeps the entry whole.
    ///
    /// - Parameter entryId: A transcript entry id.
    /// - Returns: The kept ranges, or `nil`.
    func keptRanges(of entryId: String) -> [KeptUTF8Range]? {
        guard let length = keptUTF8Lengths[entryId] else { return nil }
        return keptUTF8Ranges[entryId] ?? [KeptUTF8Range(start: 0, end: length)]
    }
}

/// Removes the repeated part of a stopped attempt from the render that the
/// model receives next (task ^1hcwaqy), and closes the reasoning that the
/// stop cut off (task ^0dcsd3t).
///
/// The recorded transcript keeps each entry whole. Only the render changes:
/// each watched entry keeps its lines that are not repeats, up to the end of
/// its last new line; an entry with no text left leaves the render; and a
/// stopped pass that wrote only reasoning gets a closing response
/// (``ReasoningClosure``).
enum RepeatedPartRemoval {
    /// `entries` with the changes of `cut`.
    ///
    /// - Parameters:
    ///   - entries: The transcript, whole.
    ///   - cut: The changes of the render.
    /// - Returns: The render entries.
    static func render(of entries: [Transcript.Entry], applying cut: RenderCut) -> [Transcript.Entry] {
        let trimmedEntries = entries.compactMap { entry in
            guard let ranges = cut.keptRanges(of: entry.id) else { return entry }
            return trimmed(entry, keeping: ranges)
        }
        return ReasoningClosure.closing(trimmedEntries, with: cut.reasoningClosures)
    }

    /// The render of a stopped attempt, and the change that the session
    /// records for it.
    ///
    /// - Parameters:
    ///   - entries: The rebuilt transcript of the stopped attempt, whole.
    ///   - keptUTF8Lengths: For each watched entry id, the UTF-8 length that
    ///     the render keeps at most.
    ///   - keptUTF8Ranges: For each watched entry id, the ranges that the
    ///     render keeps.
    ///   - closureText: The text of the response that closes a stopped
    ///     reasoning.
    /// - Returns: The render entries, and the change of the render.
    static func renderAfterStop(
        of entries: [Transcript.Entry], keptUTF8Lengths: [String: Int], keptUTF8Ranges: [String: [KeptUTF8Range]],
        closureText: String
    ) -> (entries: [Transcript.Entry], change: RepeatedPartRemovalSegment.Content) {
        let removal = RepeatedPartRemovalSegment.Content(
            keptUTF8Lengths: keptUTF8Lengths, keptUTF8Ranges: keptUTF8Ranges)
        var cut = RenderCut()
        cut.add(removal)
        let trimmedEntries = render(of: entries, applying: cut)
        let closure = ReasoningClosure.needed(in: trimmedEntries, text: closureText)
        let change = RepeatedPartRemovalSegment.Content(
            keptUTF8Lengths: keptUTF8Lengths, keptUTF8Ranges: keptUTF8Ranges, reasoningClosure: closure)
        return (ReasoningClosure.closing(trimmedEntries, with: closure.map { [$0] } ?? []), change)
    }

    /// `entry` with its text cut to the bytes of `ranges`, or `nil` when no
    /// text is left.
    ///
    /// A watched `.toolCalls` entry stays whole (task ^dzw15st). The rebuild
    /// of a stopped attempt already removed a call that got no output
    /// (``InFlightTranscript/removingUnansweredCalls(from:entryIdsBeforeAttempt:)``),
    /// and a call that got an output keeps its arguments, so the output keeps
    /// its call.
    ///
    /// - Parameters:
    ///   - entry: A watched `.reasoning`, `.response` or `.toolCalls` entry.
    ///   - ranges: The UTF-8 ranges of the text to keep.
    /// - Returns: The cut entry, the same entry when nothing is cut, or `nil`.
    private static func trimmed(_ entry: Transcript.Entry, keeping ranges: [KeptUTF8Range]) -> Transcript.Entry? {
        switch entry {
        case .reasoning(var reasoning):
            guard let segments = cut(reasoning.segments, keeping: ranges) else { return entry }
            guard !segments.isEmpty else { return nil }
            reasoning.segments = segments
            return .reasoning(reasoning)
        case .response(var response):
            guard let segments = cut(response.segments, keeping: ranges) else { return entry }
            guard !segments.isEmpty else { return nil }
            response.segments = segments
            return .response(response)
        case .instructions, .prompt, .toolCalls, .toolOutput:
            return entry
        @unknown default:
            return entry
        }
    }

    /// One text segment that holds the bytes of `ranges` of the text of
    /// `segments`, in order; no segment when no byte is kept, an entry with
    /// no text included; or `nil` when the ranges keep the whole text.
    ///
    /// Each range starts and ends at the end of a line, so the cut never
    /// splits a character. The new segment keeps the id of the first text
    /// segment of the entry, so the live render and a restored render hold
    /// the same segment.
    ///
    /// - Parameters:
    ///   - segments: The segments of the entry.
    ///   - ranges: The UTF-8 ranges of the text to keep, in order.
    /// - Returns: The new segments, or `nil` when nothing is cut.
    private static func cut(_ segments: [Transcript.Segment], keeping ranges: [KeptUTF8Range]) -> [Transcript.Segment]? {
        let utf8 = Array(WatchedText.text(of: segments).utf8)
        let kept = ranges.flatMap { range -> ArraySlice<UInt8> in
            let start = min(range.start, utf8.count)
            return utf8[start..<max(start, min(range.end, utf8.count))]
        }
        guard !kept.isEmpty else { return [] }
        guard kept.count < utf8.count else { return nil }
        let segmentId = segments.lazy.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.id
        }.first ?? UUID().uuidString
        return [.text(Transcript.TextSegment(id: segmentId, content: String(decoding: kept, as: UTF8.self)))]
    }
}
