import Foundation
import FoundationModels
import Observation

/// One tool invocation's lifecycle, correlated by ``id`` across its
/// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` and
/// ``SessionEvent/toolStatus(id:status:summary:output:)`` events.
public struct ToolCallEntry: Sendable, Equatable, Identifiable {
    /// The invocation's own id, Apple's `Transcript.ToolCall.id`.
    public let id: String
    /// The tool's name.
    public let name: String
    /// The call's arguments, as `GeneratedContent.jsonString`.
    public let argumentsJSON: String
    /// The invocation's current status.
    public var status: ToolCallStatus
    /// The tool's flattened output text once ``ToolCallStatus/completed``,
    /// or `nil` otherwise.
    public var summary: String?
    /// The tool's full output segments once ``ToolCallStatus/completed``, in
    /// entry order, or `nil` otherwise.
    public var output: [SegmentPayload]? = nil
}

/// The `@MainActor`/`@Observable` mirror of one ``RoutedSession``'s live
/// state, for SwiftUI binding.
///
/// A driver feeds it ``SessionEvent``s through ``apply(_:)`` or
/// ``apply(eventsFrom:)``. One projection can observe a session across many
/// turns. ``tokensIn`` and ``tokensOut`` accumulate for its whole lifetime.
@MainActor
@Observable
public final class SessionProjection {
    /// Where a session is in one observed turn, derived from the most recent
    /// ``SessionEvent`` that updated something.
    public enum Phase: Sendable, Equatable {
        /// No turn is currently being observed.
        case idle
        /// The model is producing, or has just produced, response/reasoning text.
        case generating
        /// A tool call this turn requested is in flight, or its result just landed.
        case runningTool
        /// A mid-turn auto-compaction fold is running.
        case compacting
    }

    /// The tool-call payload a ``TranscriptEntry/Kind/toolCall(_:)`` row
    /// carries. Kept for source compatibility.
    public typealias ToolCallEntry = FoundationModelsRouter.ToolCallEntry

    /// One entry in ``transcript``, identifiable for direct SwiftUI `ForEach` use.
    public struct TranscriptEntry: Sendable, Equatable, Identifiable {
        /// What kind of content one transcript entry carries.
        public enum Kind: Sendable, Equatable {
            /// Accumulated response text from consecutive
            /// ``SessionEvent/textDelta(_:)`` fragments.
            case text(String)
            /// Accumulated reasoning text from consecutive
            /// ``SessionEvent/reasoningDelta(_:)`` fragments.
            case reasoning(String)
            /// A tool invocation and its live lifecycle.
            case toolCall(ToolCallEntry)
            /// A mid-turn auto-compaction fold's result.
            case compaction(CompactionResult)
        }

        /// This row's identity: the SDK `Transcript.ToolCall.id` for a call
        /// row, ``CompactionResult/id`` for a compaction row, and for a text or
        /// reasoning row a provisional id (`"provisional-<n>"`) until
        /// ``SessionEvent/entryRecorded(id:kind:)`` gives it the SDK entry id.
        public let id: String

        /// This entry's current content.
        public var kind: Kind

        /// The SDK `Transcript.Entry.id` this row joins back to, or `nil`
        /// while the row is still open. For a ``Kind/toolCall(_:)`` row it
        /// names the `.toolCalls` entry.
        public let sourceEntryId: String?

        /// Creates a transcript entry.
        ///
        /// - Parameters:
        ///   - id: This row's identity.
        ///   - kind: This entry's content.
        ///   - sourceEntryId: The SDK entry id this row joins back to, or `nil`.
        public init(id: String, kind: Kind, sourceEntryId: String? = nil) {
            self.id = id
            self.kind = kind
            self.sourceEntryId = sourceEntryId
        }
    }

    /// The current phase.
    public private(set) var phase: Phase = .idle

    /// The most recent ``SessionEvent/turnStarted(_:)``, or `nil` before the
    /// first one. Not cleared by ``SessionEvent/turnEnded(_:)``.
    public private(set) var currentTurn: TurnStart?

    /// The running transcript observed so far, oldest first.
    public private(set) var transcript: [TranscriptEntry] = []

    /// Cumulative input tokens across every observed ``SessionEvent/turnEnded(_:)``.
    public private(set) var tokensIn: Int = 0

    /// Cumulative output tokens across every observed ``SessionEvent/turnEnded(_:)``.
    public private(set) var tokensOut: Int = 0

    /// The session's most recently measured ``RoutedSession/contextFill``,
    /// updated by every ``SessionEvent/turnEnded(_:)``.
    public private(set) var contextFill: Double = 0

    /// Creates an empty projection in ``Phase/idle``.
    public init() {}

    /// Applies one ``SessionEvent`` to this projection's state.
    ///
    /// - Parameter event: The event to apply.
    public func apply(_ event: SessionEvent) {
        switch event {
        case .turnStarted(let start):
            currentTurn = start
        case .textDelta(let fragment):
            phase = .generating
            appendTextFragment(fragment)
        case .textReset:
            // The model abandoned the response it was writing and began
            // another (see ``SessionEvent/textReset``). The superseded text
            // really was produced and really is recorded as its own
            // `.response` transcript entry, so a faithful mirror keeps it and
            // closes it: the next fragment opens a new entry beside it rather
            // than growing the old one into a sentence the model never wrote.
            // The rule itself lives in the shared ``ResponseTextFold``.
            responseTextFold.reset()
            markOpenTextRowSuperseded()
        case .reasoningDelta(let fragment):
            phase = .generating
            appendReasoningFragment(fragment)
        case .toolCall(let id, let name, let argumentsJSON):
            phase = .runningTool
            transcript.append(
                TranscriptEntry(
                    id: id,
                    kind: .toolCall(ToolCallEntry(id: id, name: name, argumentsJSON: argumentsJSON, status: .running, summary: nil))))
        case .toolStatus(let id, let status, let summary, let output):
            if Self.updateToolCallRow(id: id, status: status, summary: summary, output: output, in: &transcript) {
                phase = .runningTool
            }
        case .toolInvocation(let record):
            applyToolInvocation(record)
        case .entryRecorded(let id, let kind):
            // Bookkeeping only, deliberately no phase change: the close
            // arrives at diff time, alongside events that already set the
            // phase they report, and closing an entry is not itself a phase.
            recordEntryOrdinal(id)
            adoptRecordedEntry(id: id, kind: kind)
        case .compaction(let result):
            phase = .compacting
            transcript.append(
                TranscriptEntry(id: result.id, kind: .compaction(result), sourceEntryId: result.summaryEntryId))
        case .discoveryPrimingFailed, .generationStalled, .runSettled:
            // Handled explicitly, and deliberately changes nothing. A settled
            // run's terminal reaches this mirror as the recorded tool output
            // of the turn that next carries it. A turn whose
            // discovery priming could not seed generates exactly as an unprimed
            // turn does (see ``SessionEvent/discoveryPrimingFailed(_:)``), and a
            // stall report bounds nothing at all — the turn is still running and
            // will still produce whatever it was going to produce (see
            // ``SessionEvent/generationStalled(_:)``). So this projection's
            // phase, transcript, and counters are already the faithful mirror of
            // what happened. Both are diagnostics for a driver watching the
            // event stream, not session state.
            break
        case .turnEnded(let usage):
            tokensIn += usage.tokensIn
            tokensOut += usage.tokensOut
            contextFill = usage.contextFill
            // A run that went to the background never closes inside its own turn, so its
            // open invocation is cleared here — a stale open must never pin a
            // later turn's phase to ``Phase/runningTool``. Its late close
            // then finds nothing tracked and changes nothing (see
            // ``applyToolInvocation(_:)``).
            openInvocationCorrelationIDs.removeAll()
            phase = .idle
        }
    }

    /// Drains `stream` and applies every event as it arrives.
    ///
    /// Resets to ``Phase/idle`` when the stream finishes or throws.
    ///
    /// - Parameter stream: The event stream to drain.
    /// - Throws: Whatever `stream` throws, after applying every event first.
    public func apply(eventsFrom stream: AsyncThrowingStream<SessionEvent, Error>) async throws {
        defer { phase = .idle }
        for try await event in stream {
            apply(event)
        }
    }

    /// Appends `fragment` to the last open entry that `matching` accepts, or
    /// starts a new entry with `makeKind` under a fresh provisional id.
    private func appendFragment(
        _ fragment: String,
        matching: (TranscriptEntry.Kind) -> String?,
        makeKind: (String) -> TranscriptEntry.Kind
    ) {
        if let last = transcript.last, last.sourceEntryId == nil, let existing = matching(last.kind) {
            transcript[transcript.count - 1].kind = makeKind(existing + fragment)
        } else {
            transcript.append(TranscriptEntry(id: makeProvisionalId(), kind: makeKind(fragment)))
        }
    }

    /// Appends `fragment` to the last open ``TranscriptEntry/Kind/text(_:)``
    /// entry, or starts a new one after a ``SessionEvent/textReset``.
    private func appendTextFragment(_ fragment: String) {
        let startsNewEntry = responseTextFold.append(fragment)
        appendFragment(
            fragment,
            matching: { kind in
                guard !startsNewEntry, case .text(let existing) = kind else { return nil }
                return existing
            },
            makeKind: TranscriptEntry.Kind.text)
    }

    /// The ``ResponseTextFold`` that applies the ``SessionEvent/textReset`` rule.
    private var responseTextFold = ResponseTextFold()

    /// Appends `fragment` to the last open ``TranscriptEntry/Kind/reasoning(_:)``
    /// entry, or starts a new one.
    private func appendReasoningFragment(_ fragment: String) {
        appendFragment(
            fragment,
            matching: { if case .reasoning(let existing) = $0 { return existing } else { return nil } },
            makeKind: TranscriptEntry.Kind.reasoning)
    }

    /// Updates the ``TranscriptEntry/Kind/toolCall(_:)`` row in `rows` whose
    /// call id matches `id` with `status`, `summary`, and `output`, in place.
    ///
    /// - Returns: Whether a matching row was found and updated.
    @discardableResult
    private nonisolated static func updateToolCallRow(
        id: String, status: ToolCallStatus, summary: String?, output: [SegmentPayload]?,
        in rows: inout [TranscriptEntry]
    ) -> Bool {
        guard
            let index = rows.lastIndex(where: {
                if case .toolCall(let call) = $0.kind { return call.id == id }
                return false
            })
        else { return false }
        guard case .toolCall(var call) = rows[index].kind else { return false }
        call.status = status
        call.summary = summary
        call.output = output
        rows[index].kind = .toolCall(call)
        return true
    }

    /// The `correlationID` of every open ``SessionEvent/toolInvocation(_:)``
    /// record this turn. Cleared at ``SessionEvent/turnEnded(_:)``.
    private var openInvocationCorrelationIDs: Set<String> = []

    /// Applies one ``SessionEvent/toolInvocation(_:)`` to ``phase``. An open
    /// record sets ``Phase/runningTool``. The last tracked close returns the
    /// phase to ``Phase/generating``. An untracked close changes nothing.
    ///
    /// - Parameter record: The record to apply.
    private func applyToolInvocation(_ record: ToolInvocationRecord) {
        guard record.closedAt != nil else {
            openInvocationCorrelationIDs.insert(record.correlationID)
            phase = .runningTool
            return
        }
        guard openInvocationCorrelationIDs.remove(record.correlationID) != nil else { return }
        phase = openInvocationCorrelationIDs.isEmpty ? .generating : .runningTool
    }

    /// The prefix every provisional row id carries.
    private static let provisionalIdPrefix = "provisional-"

    /// How many provisional ids this projection has handed out.
    private var provisionalEntryCount = 0

    /// Returns the next provisional row id, deterministic per event sequence.
    private func makeProvisionalId() -> String {
        provisionalEntryCount += 1
        return "\(Self.provisionalIdPrefix)\(provisionalEntryCount)"
    }

    /// Applies one ``SessionEvent/entryRecorded(id:kind:)``: the oldest open
    /// row of `kind` adopts `id`, or the unstamped call rows get `id` as their
    /// ``TranscriptEntry/sourceEntryId``. A no-op when no row is open.
    ///
    /// - Parameters:
    ///   - id: The recorded entry's SDK `Transcript.Entry.id`.
    ///   - kind: Which entry kind was recorded.
    private func adoptRecordedEntry(id: String, kind: RecordedEntryKind) {
        switch kind {
        case .response:
            adopt(entryId: id, ontoOldestOpenRowWhere: { if case .text = $0 { return true } else { return false } })
        case .reasoning:
            adopt(
                entryId: id, ontoOldestOpenRowWhere: { if case .reasoning = $0 { return true } else { return false } })
        case .toolCalls:
            stampToolCallRows(sourceEntryId: id)
        }
    }

    /// Gives the oldest open row that satisfies `isKind` the id `entryId` as
    /// both its identity and its ``TranscriptEntry/sourceEntryId``. A no-op
    /// when no such row exists.
    ///
    /// - Parameters:
    ///   - entryId: The SDK entry id to adopt.
    ///   - isKind: Whether a row's kind is the one this close names.
    private func adopt(entryId: String, ontoOldestOpenRowWhere isKind: (TranscriptEntry.Kind) -> Bool) {
        guard let index = transcript.firstIndex(where: { $0.sourceEntryId == nil && isKind($0.kind) }) else {
            return
        }
        // The row's identity changes, so its membership in the superseded
        // set follows it — a superseded text row stays superseded under its
        // adopted id (see ``supersededTextRowIds``).
        if supersededTextRowIds.remove(transcript[index].id) != nil {
            supersededTextRowIds.insert(entryId)
        }
        transcript[index] = TranscriptEntry(id: entryId, kind: transcript[index].kind, sourceEntryId: entryId)
    }

    /// Stamps `sourceEntryId` onto every ``TranscriptEntry/Kind/toolCall(_:)``
    /// row not yet joined to its `.toolCalls` entry.
    ///
    /// - Parameter sourceEntryId: The recorded `.toolCalls` entry's SDK id.
    private func stampToolCallRows(sourceEntryId: String) {
        for index in transcript.indices {
            guard transcript[index].sourceEntryId == nil, case .toolCall = transcript[index].kind else { continue }
            transcript[index] = TranscriptEntry(
                id: transcript[index].id, kind: transcript[index].kind, sourceEntryId: sourceEntryId)
        }
    }

    // MARK: - Seeding from a cold Transcript

    /// Resets this projection to mirror a cold `transcript`. Installs the
    /// rows from ``transcriptRows(from:)`` and resets every other value to
    /// its initial state.
    ///
    /// - Parameter transcript: The cold transcript to mirror.
    public func seed(from transcript: Transcript) {
        let entries = Array(transcript)
        self.transcript = Self.transcriptRows(from: entries)
        supersededTextRowIds = Self.supersededTextEntryIds(in: entries)
        recordedEntryOrdinals = [:]
        for row in self.transcript {
            guard let sourceEntryId = row.sourceEntryId else { continue }
            recordEntryOrdinal(sourceEntryId)
        }
        responseTextFold = ResponseTextFold()
        openInvocationCorrelationIDs.removeAll()
        provisionalEntryCount = 0
        currentTurn = nil
        tokensIn = 0
        tokensOut = 0
        contextFill = 0
        phase = .idle
    }

    /// Groups a cold transcript's entries into the rows a live projection
    /// holds for the same history. A `.toolOutput` entry pairs to its call
    /// through ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``.
    /// A call row still ``ToolCallStatus/running`` at the end is marked
    /// ``ToolCallStatus/failed``.
    ///
    /// - Parameter entries: The cold transcript's entries, oldest first.
    /// - Returns: The rows, in transcript order.
    nonisolated static func transcriptRows(from entries: [Transcript.Entry]) -> [TranscriptEntry] {
        var rows: [TranscriptEntry] = []
        var dispatchedToolCallIds: [String] = []
        var completedToolCallIds: Set<String> = []
        for entry in entries {
            let (kind, payload, text) = TranscriptEntryMapper.event(from: entry)
            switch kind {
            case .prompt:
                dispatchedToolCallIds.removeAll()
                completedToolCallIds.removeAll()
            case .toolCalls:
                for call in payload.toolCalls ?? [] {
                    dispatchedToolCallIds.append(call.id)
                    rows.append(
                        TranscriptEntry(
                            id: call.id,
                            kind: .toolCall(
                                ToolCallEntry(
                                    id: call.id, name: call.toolName, argumentsJSON: call.argumentsJSON,
                                    status: .running, summary: nil)),
                            sourceEntryId: payload.entryId))
                }
            case .toolOutput:
                let callId = ToolCallOutputPairing.completedToolCallId(
                    forOutputEntryId: payload.entryId,
                    dispatched: dispatchedToolCallIds,
                    completed: completedToolCallIds)
                completedToolCallIds.insert(callId)
                updateToolCallRow(id: callId, status: .completed, summary: text, output: payload.segments, in: &rows)
            case .response:
                rows.append(
                    compactionRow(from: entry, entryId: payload.entryId)
                        ?? TranscriptEntry(id: payload.entryId, kind: .text(text ?? ""), sourceEntryId: payload.entryId))
            case .reasoning:
                rows.append(
                    TranscriptEntry(
                        id: payload.entryId, kind: .reasoning(text ?? ""), sourceEntryId: payload.entryId))
            case .session, .instructions, .embedding, .divergence, .toolCall, .unknown:
                break
            }
        }
        failUnansweredToolCallRows(in: &rows)
        return rows
    }

    /// Marks every call row still ``ToolCallStatus/running`` as
    /// ``ToolCallStatus/failed``.
    ///
    /// - Parameter rows: The rows grouped from the whole transcript.
    private nonisolated static func failUnansweredToolCallRows(in rows: inout [TranscriptEntry]) {
        for index in rows.indices {
            guard case .toolCall(var call) = rows[index].kind, call.status == .running else { continue }
            call.status = .failed
            rows[index].kind = .toolCall(call)
        }
    }

    /// The ``TranscriptEntry/Kind/compaction(_:)`` row for a compaction
    /// boundary entry, keyed on the persisted ``CompactionSegment/id``, or
    /// `nil` for an ordinary `.response`.
    ///
    /// - Parameters:
    ///   - entry: The `.response` entry to inspect.
    ///   - entryId: That entry's own id.
    /// - Returns: The compaction row, or `nil` for an ordinary response.
    private nonisolated static func compactionRow(
        from entry: Transcript.Entry, entryId: String
    ) -> TranscriptEntry? {
        guard case .response(let response) = entry else { return nil }
        var segment: CompactionSegment?
        var summaryText: String?
        for candidate in response.segments {
            if segment == nil, case .structure(let structured) = candidate,
                let compaction = try? CompactionSegment(structuredSegment: structured)
            {
                segment = compaction
            }
            if summaryText == nil, case .text(let textSegment) = candidate {
                summaryText = textSegment.content
            }
        }
        guard let segment else { return nil }
        let summary = summaryText.flatMap { $0.isEmpty ? nil : $0 }
        let result = CompactionResult(
            id: segment.id,
            summary: summary,
            summaryEntryId: summary == nil ? nil : entryId,
            tokensBefore: segment.content.tokensBefore,
            tokensAfter: segment.content.tokensAfter,
            stagesApplied: segment.content.stagesApplied)
        return TranscriptEntry(id: result.id, kind: .compaction(result), sourceEntryId: result.summaryEntryId)
    }

    // MARK: - The grouped view (task ^8dc98vs)

    /// One tool call's group in ``groupedRows``: the call row plus the
    /// adjacent context rows that led to it.
    public struct ToolCallGroup: Sendable, Equatable, Identifiable {
        /// The ``TranscriptEntry/Kind/toolCall(_:)`` row this group holds.
        public let call: TranscriptEntry

        /// The reasoning rows and superseded text rows that come immediately
        /// before the call, in transcript order.
        public let context: [TranscriptEntry]

        /// This group's stable identity, the call's own row id.
        public var id: String { call.id }

        /// Creates a call group.
        ///
        /// - Parameters:
        ///   - call: The tool-call row the group holds.
        ///   - context: The context rows attached to the call.
        public init(call: TranscriptEntry, context: [TranscriptEntry]) {
            self.call = call
            self.context = context
        }
    }

    /// One item in ``groupedRows``: a top-level row, or one call's group.
    public enum GroupedRow: Sendable, Equatable, Identifiable {
        /// A row that attaches to no call group and stays top-level.
        case row(TranscriptEntry)

        /// A tool call plus the adjacent context rows that led to it.
        case toolCallGroup(ToolCallGroup)

        /// This item's stable identity: the row's id for ``row(_:)``, the
        /// call's id for ``toolCallGroup(_:)``.
        public var id: String {
            switch self {
            case .row(let row):
                return row.id
            case .toolCallGroup(let group):
                return group.id
            }
        }
    }

    /// The grouped view over ``transcript``, derived on read. The run of
    /// reasoning rows and superseded text rows immediately before a tool-call
    /// row attaches to that call's ``ToolCallGroup``.
    public var groupedRows: [GroupedRow] {
        Self.groupedRows(from: canonicallyOrderedTranscript(), supersededTextRowIds: supersededTextRowIds)
    }

    /// The row ids of every ``TranscriptEntry/Kind/text(_:)`` row a
    /// ``SessionEvent/textReset`` closed as superseded.
    private var supersededTextRowIds: Set<String> = []

    /// Each recorded entry id's arrival ordinal, which is its transcript order.
    private var recordedEntryOrdinals: [String: Int] = [:]

    /// Marks the open text row superseded. A no-op when the last row is not
    /// an open text row.
    private func markOpenTextRowSuperseded() {
        guard let last = transcript.last, last.sourceEntryId == nil, case .text = last.kind else { return }
        supersededTextRowIds.insert(last.id)
    }

    /// Records `id`'s arrival ordinal once. A second close keeps the first
    /// ordinal.
    ///
    /// - Parameter id: The recorded entry's SDK `Transcript.Entry.id`.
    private func recordEntryOrdinal(_ id: String) {
        guard recordedEntryOrdinals[id] == nil else { return }
        recordedEntryOrdinals[id] = recordedEntryOrdinals.count
    }

    /// The entry ids of every plain `.response` entry that a later plain
    /// `.response` entry in the same turn superseded.
    ///
    /// - Parameter entries: The cold transcript's entries, oldest first.
    /// - Returns: The superseded text rows' entry ids.
    private nonisolated static func supersededTextEntryIds(in entries: [Transcript.Entry]) -> Set<String> {
        var superseded: Set<String> = []
        var turnTextEntryIds: [String] = []
        for entry in entries {
            let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
            switch kind {
            case .prompt:
                turnTextEntryIds.removeAll()
            case .response:
                guard compactionRow(from: entry, entryId: payload.entryId) == nil else { break }
                superseded.formUnion(turnTextEntryIds)
                turnTextEntryIds.append(payload.entryId)
            case .toolCalls, .toolOutput, .reasoning, .session, .instructions, .embedding, .divergence,
                .toolCall, .unknown:
                break
            }
        }
        return superseded
    }

    /// ``transcript`` sorted by each row's recorded ordinal. A row with no
    /// ordinal inherits the nearest preceding row's ordinal.
    ///
    /// - Returns: The rows in canonical order.
    private func canonicallyOrderedTranscript() -> [TranscriptEntry] {
        var keyed: [(ordinal: Int, index: Int, row: TranscriptEntry)] = []
        keyed.reserveCapacity(transcript.count)
        // Rows before any recorded entry sort ahead of every recorded one.
        var carried = -1
        for (index, row) in transcript.enumerated() {
            if let sourceEntryId = row.sourceEntryId, let ordinal = recordedEntryOrdinals[sourceEntryId] {
                carried = ordinal
            }
            keyed.append((carried, index, row))
        }
        return keyed.sorted { ($0.ordinal, $0.index) < ($1.ordinal, $1.index) }.map(\.row)
    }

    /// Applies the grouping rule to rows already in canonical order.
    ///
    /// - Parameters:
    ///   - rows: The rows to group, in canonical order.
    ///   - supersededTextRowIds: The ids of the superseded text rows.
    /// - Returns: The grouped items, in canonical order.
    private nonisolated static func groupedRows(
        from rows: [TranscriptEntry], supersededTextRowIds: Set<String>
    ) -> [GroupedRow] {
        var grouped: [GroupedRow] = []
        var pendingContext: [TranscriptEntry] = []
        for row in rows {
            switch row.kind {
            case .reasoning:
                pendingContext.append(row)
            case .text where supersededTextRowIds.contains(row.id):
                pendingContext.append(row)
            case .toolCall:
                grouped.append(.toolCallGroup(ToolCallGroup(call: row, context: pendingContext)))
                pendingContext.removeAll()
            case .text, .compaction:
                grouped.append(contentsOf: pendingContext.map(GroupedRow.row))
                pendingContext.removeAll()
                grouped.append(.row(row))
            }
        }
        grouped.append(contentsOf: pendingContext.map(GroupedRow.row))
        return grouped
    }
}
