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
/// answers. ``tokensIn`` and ``tokensOut`` accumulate for its whole lifetime.
@MainActor
@Observable
public final class SessionProjection {
    /// Where a session is in one observed answer, derived from the most recent
    /// ``SessionEvent`` that updated something.
    public enum Phase: Sendable, Equatable {
        /// No answer is currently being observed.
        case idle
        /// The model is producing, or has just produced, response/reasoning text.
        case generating
        /// A tool call this answer requested is in flight, or its result just landed.
        case runningTool
        /// An auto-compaction inside an answer is running.
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
            /// The result of an auto-compaction inside an answer.
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

    /// The running submission: set by ``SessionEvent/submissionStarted(_:)``,
    /// cleared by the ``SessionEvent/submissionEnded(_:)`` with the same id.
    /// `nil` between submissions.
    public private(set) var currentSubmission: SubmissionStart?

    /// The caller messages that a started submission delivered and that no
    /// ``SessionEvent/answered(_:)`` or ``SessionEvent/answerFailed(_:)``
    /// named yet, in delivery order. A view shows them as the messages in
    /// flight.
    public private(set) var messagesAwaitingAnswer: [MessageID] = []

    /// The running transcript observed so far, oldest first.
    public private(set) var transcript: [TranscriptEntry] = []

    /// Cumulative input tokens across every observed
    /// ``SessionEvent/submissionEnded(_:)`` that carried usage.
    public private(set) var tokensIn: Int = 0

    /// Cumulative output tokens across every observed
    /// ``SessionEvent/submissionEnded(_:)`` that carried usage.
    public private(set) var tokensOut: Int = 0

    /// The session's most recently measured ``RoutedSession/contextFill``,
    /// updated by every ``SessionEvent/submissionEnded(_:)`` that carried
    /// usage.
    public private(set) var contextFill: Double = 0

    /// Creates an empty projection in ``Phase/idle``.
    public init() {}

    /// Applies one ``SessionEvent`` to this projection's state.
    ///
    /// - Parameter event: The event to apply.
    public func apply(_ event: SessionEvent) {
        switch event {
        case .submissionStarted(let start):
            applySubmissionStarted(start)
        case .submissionEnded(let end):
            applySubmissionEnded(end)
        case .answered(let answer):
            removeAwaitingAnswer(answer.messageIds)
        case .answerFailed(let failure):
            removeAwaitingAnswer(failure.messageIds)
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
            // The rule itself lives in the shared ``ResponseTextReducer``.
            responseTextReducer.reset()
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
        case .discoveryPrimingFailed, .generationStalled, .submissionQueued, .repetitionStopped,
            .runSettled, .toolCallReport, .elicitationRequested, .generationCall:
            // Handled explicitly, and deliberately changes nothing. A settled
            // run's terminal reaches this mirror as the recorded tool output
            // of the submission that next carries it. A submission whose
            // discovery priming could not seed generates as an unprimed
            // submission does (see ``SessionEvent/discoveryPrimingFailed(_:)``).
            // A stall report bounds nothing: the submission still runs and
            // still gives its output (see ``SessionEvent/generationStalled(_:)``).
            // A wait of a submission for the worker of its model changes no
            // entry and no counter: the submission gives the same output after
            // the wait. A repetition stop report comes with the recorded
            // entries of the stopped attempt, and its
            // ``SessionEvent/submissionEnded(_:)`` names the stop. A tool call
            // report carries records for a host to decode, and the phase of
            // the call is already mirrored from its
            // ``SessionEvent/toolInvocation(_:)`` records. An elicitation
            // request names a question that only a host can answer, and the
            // call that asks still runs. The usage of one generation call is
            // a part of the usage of the submission, and
            // ``SessionEvent/submissionEnded(_:)`` carries the sum. So the
            // phase, the transcript and the counters of this projection
            // already mirror what occurred. These events are for a driver
            // that watches the event stream, not session state.
            break
        }
    }

    /// Applies one ``SessionEvent/submissionStarted(_:)``: the submission
    /// becomes ``currentSubmission``, and each caller message it delivers
    /// joins ``messagesAwaitingAnswer`` one time.
    ///
    /// - Parameter start: The start record of the submission.
    private func applySubmissionStarted(_ start: SubmissionStart) {
        currentSubmission = start
        for messageId in start.messageIds where !messagesAwaitingAnswer.contains(messageId) {
            messagesAwaitingAnswer.append(messageId)
        }
    }

    /// Applies one ``SessionEvent/submissionEnded(_:)``: it adds the usage of
    /// the submission when the submission carries usage, and it clears
    /// ``currentSubmission`` when that submission ended.
    ///
    /// A run that went to the background never closes inside its own
    /// submission, so its open invocation is cleared here, also when the
    /// submission carries no usage. A stale open must never pin the phase of
    /// a later submission to ``Phase/runningTool``. Its late close then finds
    /// nothing tracked and changes nothing (see ``applyToolInvocation(_:)``).
    ///
    /// - Parameter end: The end record of the submission.
    private func applySubmissionEnded(_ end: SubmissionEnd) {
        if let usage = end.usage {
            tokensIn += usage.tokensIn
            tokensOut += usage.tokensOut
            contextFill = usage.contextFill
        }
        if currentSubmission?.submissionId == end.submissionId {
            currentSubmission = nil
        }
        openInvocationCorrelationIDs.removeAll()
        phase = .idle
    }

    /// Removes each of `messageIds` from ``messagesAwaitingAnswer``: an
    /// answer or a failure named them.
    ///
    /// - Parameter messageIds: The caller messages that the answer or the
    ///   failure names.
    private func removeAwaitingAnswer(_ messageIds: [MessageID]) {
        messagesAwaitingAnswer.removeAll { messageIds.contains($0) }
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
        let startsNewEntry = responseTextReducer.append(fragment)
        appendFragment(
            fragment,
            matching: { kind in
                guard !startsNewEntry, case .text(let existing) = kind else { return nil }
                return existing
            },
            makeKind: TranscriptEntry.Kind.text)
    }

    /// The ``ResponseTextReducer`` that applies the ``SessionEvent/textReset`` rule.
    private var responseTextReducer = ResponseTextReducer()

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
    /// record of the running submission. Cleared at each
    /// ``SessionEvent/submissionEnded(_:)``.
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
        responseTextReducer = ResponseTextReducer()
        openInvocationCorrelationIDs.removeAll()
        provisionalEntryCount = 0
        currentSubmission = nil
        messagesAwaitingAnswer = []
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
        entries.reduce(into: ColdTranscriptScan()) { scan, entry in scan.read(entry: entry) }.finishedRows
    }

    /// The state that ``transcriptRows(from:)`` threads through the entries
    /// of a cold transcript: the rows so far, and the tool calls of the
    /// submission that the scan is in.
    private struct ColdTranscriptScan {
        /// The rows so far, in transcript order.
        private var rows: [TranscriptEntry] = []

        /// The call ids that the current submission dispatched, in order.
        private var dispatchedToolCallIds: [String] = []

        /// The call ids of the current submission that an output answered.
        private var completedToolCallIds: Set<String> = []

        /// The rows, with each call row that is still
        /// ``ToolCallStatus/running`` marked ``ToolCallStatus/failed``: no
        /// output answered that call.
        var finishedRows: [TranscriptEntry] {
            rows.map { row in
                guard case .toolCall(var call) = row.kind, call.status == .running else { return row }
                call.status = .failed
                var failed = row
                failed.kind = .toolCall(call)
                return failed
            }
        }

        /// Reads the next entry of the cold transcript into the rows.
        ///
        /// - Parameter entry: The next entry, in transcript order.
        mutating func read(entry: Transcript.Entry) {
            let (kind, payload, text) = TranscriptEntryMapper.event(from: entry)
            switch kind {
            case .prompt:
                // A compaction boundary is a row, not the start of a submission.
                if let boundary = SessionProjection.compactionRow(from: entry, entryId: payload.entryId) {
                    rows.append(boundary)
                } else {
                    dispatchedToolCallIds.removeAll()
                    completedToolCallIds.removeAll()
                }
            case .toolCalls:
                read(toolCalls: payload.toolCalls ?? [], entryId: payload.entryId)
            case .toolOutput:
                let callId = ToolCallOutputPairing.completedToolCallId(
                    forOutputEntryId: payload.entryId,
                    dispatched: dispatchedToolCallIds,
                    completed: completedToolCallIds)
                completedToolCallIds.insert(callId)
                SessionProjection.updateToolCallRow(
                    id: callId, status: .completed, summary: text, output: payload.segments, in: &rows)
            case .response:
                rows.append(
                    SessionProjection.compactionRow(from: entry, entryId: payload.entryId)
                        ?? TranscriptEntry(id: payload.entryId, kind: .text(text ?? ""), sourceEntryId: payload.entryId))
            case .reasoning:
                rows.append(
                    TranscriptEntry(
                        id: payload.entryId, kind: .reasoning(text ?? ""), sourceEntryId: payload.entryId))
            case .session, .instructions, .embedding, .divergence, .generationCall, .repeatedPartRemoval, .toolCall,
                .unknown:
                break
            }
        }

        /// Adds one ``ToolCallStatus/running`` call row for each call of a
        /// `.toolCalls` entry, and records each call as dispatched.
        ///
        /// - Parameters:
        ///   - toolCalls: The calls of the entry, in order.
        ///   - entryId: The id of the `.toolCalls` entry.
        private mutating func read(toolCalls: [ToolCallPayload], entryId: String) {
            dispatchedToolCallIds.append(contentsOf: toolCalls.map(\.id))
            rows.append(
                contentsOf: toolCalls.map { call in
                    TranscriptEntry(
                        id: call.id,
                        kind: .toolCall(
                            ToolCallEntry(
                                id: call.id, name: call.toolName, argumentsJSON: call.argumentsJSON,
                                status: .running, summary: nil)),
                        sourceEntryId: entryId)
                })
        }
    }

    /// The ``TranscriptEntry/Kind/compaction(_:)`` row for a compaction
    /// boundary entry, keyed on the persisted ``CompactionSegment/id``, or
    /// `nil` for an ordinary `.prompt` or `.response`.
    ///
    /// The boundary entry is a `.prompt`. A checkpoint recorded before task
    /// ^5t72pdx holds it as a `.response`, and this reads both. The summary
    /// is the text segment with the id
    /// ``CompactionSegment/summaryTextSegmentId(of:)``, so the model-visible
    /// ``CompactionSegment/summaryHeader`` is not part of it.
    ///
    /// - Parameters:
    ///   - entry: The `.prompt` or `.response` entry to inspect.
    ///   - entryId: That entry's own id.
    /// - Returns: The compaction row, or `nil` for an ordinary entry.
    private nonisolated static func compactionRow(
        from entry: Transcript.Entry, entryId: String
    ) -> TranscriptEntry? {
        let segments: [Transcript.Segment]
        switch entry {
        case .prompt(let prompt):
            segments = prompt.segments
        case .response(let response):
            segments = response.segments
        default:
            return nil
        }
        let segment = segments.lazy.compactMap { candidate -> CompactionSegment? in
            guard case .structure(let structured) = candidate else { return nil }
            return (try? CompactionSegment(structuredSegment: structured)) ?? nil
        }.first
        guard let segment else { return nil }
        let summaryTextId = CompactionSegment.summaryTextSegmentId(of: entryId)
        let summaryText = segments.lazy.compactMap { candidate -> String? in
            guard case .text(let textSegment) = candidate, textSegment.id == summaryTextId else { return nil }
            return textSegment.content
        }.first
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
    /// `.response` entry in the same submission superseded.
    ///
    /// - Parameter entries: The cold transcript's entries, oldest first.
    /// - Returns: The superseded text rows' entry ids.
    private nonisolated static func supersededTextEntryIds(in entries: [Transcript.Entry]) -> Set<String> {
        let submissions = entries.compactMap(submissionMark(of:)).split(separator: .submissionStart)
        // In each submission, every text entry but the last is superseded.
        return Set(submissions.flatMap { submission in submission.dropLast().compactMap(\.textEntryId) })
    }

    /// What one entry of a cold transcript means to the submissions that
    /// ``supersededTextEntryIds(in:)`` groups.
    private enum SubmissionMark: Equatable {
        /// A plain `.prompt`: the start of a submission.
        case submissionStart

        /// A plain `.response`: one text row of the current submission.
        case text(entryId: String)

        /// The entry id of a ``text(entryId:)`` mark, or `nil` for a
        /// ``submissionStart``.
        var textEntryId: String? {
            guard case .text(let entryId) = self else { return nil }
            return entryId
        }
    }

    /// The mark that `entry` puts on the submissions of a cold transcript,
    /// or `nil` for an entry that puts none. A compaction boundary is not
    /// the start of a submission, and it is not a text row.
    ///
    /// - Parameter entry: An entry of the cold transcript.
    /// - Returns: The mark of `entry`, or `nil`.
    private nonisolated static func submissionMark(of entry: Transcript.Entry) -> SubmissionMark? {
        let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
        switch kind {
        case .prompt:
            return compactionRow(from: entry, entryId: payload.entryId) == nil ? .submissionStart : nil
        case .response:
            return compactionRow(from: entry, entryId: payload.entryId) == nil ? .text(entryId: payload.entryId) : nil
        case .toolCalls, .toolOutput, .reasoning, .session, .instructions, .embedding, .divergence,
            .generationCall, .repeatedPartRemoval, .toolCall, .unknown:
            return nil
        }
    }

    /// The ordinal of a row before any recorded entry, so that it sorts
    /// ahead of every recorded one.
    private static let ordinalBeforeEveryRecordedEntry = -1

    /// ``transcript`` sorted by each row's recorded ordinal. A row with no
    /// ordinal inherits the nearest preceding row's ordinal.
    ///
    /// - Returns: The rows in canonical order.
    private func canonicallyOrderedTranscript() -> [TranscriptEntry] {
        let ordinals = carriedOrdinals()
        return transcript.indices
            .sorted { (ordinals[$0], $0) < (ordinals[$1], $1) }
            .map { transcript[$0] }
    }

    /// The ordinal of each row of ``transcript``, in transcript order: the
    /// row's recorded ordinal, or else the ordinal of the nearest preceding
    /// row.
    ///
    /// - Returns: One ordinal for each row of ``transcript``.
    private func carriedOrdinals() -> [Int] {
        transcript.reduce(into: []) { ordinals, row in
            let recorded = row.sourceEntryId.flatMap { recordedEntryOrdinals[$0] }
            ordinals.append(recorded ?? ordinals.last ?? Self.ordinalBeforeEveryRecordedEntry)
        }
    }

    /// Applies the grouping rule to rows already in canonical order.
    ///
    /// Each row that is not context is an anchor. The context rows between
    /// one anchor and the next attach to the next anchor. Context rows after
    /// the last anchor stay top-level.
    ///
    /// - Parameters:
    ///   - rows: The rows to group, in canonical order.
    ///   - supersededTextRowIds: The ids of the superseded text rows.
    /// - Returns: The grouped items, in canonical order.
    private nonisolated static func groupedRows(
        from rows: [TranscriptEntry], supersededTextRowIds: Set<String>
    ) -> [GroupedRow] {
        let anchorIndices = rows.indices.filter { index in
            !isContext(row: rows[index], supersededTextRowIds: supersededTextRowIds)
        }
        let contextStarts = [rows.startIndex] + anchorIndices.map { rows.index(after: $0) }
        let anchored = zip(contextStarts, anchorIndices).flatMap { contextStart, anchor in
            groupedItems(anchor: rows[anchor], context: Array(rows[contextStart..<anchor]))
        }
        let trailingContext = rows[(contextStarts.last ?? rows.startIndex)...].map(GroupedRow.row)
        return anchored + trailingContext
    }

    /// Whether `row` is context: a reasoning row or a superseded text row.
    ///
    /// - Parameters:
    ///   - row: The row to classify.
    ///   - supersededTextRowIds: The ids of the superseded text rows.
    /// - Returns: `true` for a context row, `false` for an anchor row.
    private nonisolated static func isContext(row: TranscriptEntry, supersededTextRowIds: Set<String>) -> Bool {
        switch row.kind {
        case .reasoning:
            return true
        case .text:
            return supersededTextRowIds.contains(row.id)
        case .toolCall, .compaction:
            return false
        }
    }

    /// The grouped items of one anchor row and the context rows before it.
    /// A tool-call anchor gets one ``ToolCallGroup`` that holds the context.
    /// Any other anchor stays top-level, after its context rows.
    ///
    /// - Parameters:
    ///   - anchor: The row that is not context.
    ///   - context: The context rows immediately before `anchor`, in order.
    /// - Returns: The grouped items, in canonical order.
    private nonisolated static func groupedItems(anchor: TranscriptEntry, context: [TranscriptEntry]) -> [GroupedRow] {
        guard case .toolCall = anchor.kind else { return context.map(GroupedRow.row) + [.row(anchor)] }
        return [.toolCallGroup(ToolCallGroup(call: anchor, context: context))]
    }
}
