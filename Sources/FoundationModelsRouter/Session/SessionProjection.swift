import Foundation
import FoundationModels
import Observation

/// One tool invocation's lifecycle, correlated by ``id`` across its
/// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` and
/// ``SessionEvent/toolStatus(id:status:summary:output:)`` events — load-bearing
/// for distinguishing two concurrent same-name tool calls, exactly like
/// the events it is built from.
///
/// Shared by the two event-fold consumers: a ``SessionProjection`` transcript
/// row carries one (``SessionProjection/TranscriptEntry/Kind/toolCall(_:)``),
/// and ``TurnOutcome/toolCalls`` lists a turn's own. Top-level rather than
/// nested in ``SessionProjection`` so it carries no `@MainActor` isolation;
/// ``SessionProjection/ToolCallEntry`` remains as a typealias for source
/// compatibility.
public struct ToolCallEntry: Sendable, Equatable, Identifiable {
    /// The invocation's own id — Apple's `Transcript.ToolCall.id`.
    public let id: String
    /// The tool's name.
    public let name: String
    /// The call's arguments, as `GeneratedContent.jsonString`.
    public let argumentsJSON: String
    /// The invocation's current status.
    public var status: ToolCallStatus
    /// The tool's flattened output text once ``ToolCallStatus/completed``,
    /// or `nil` for ``ToolCallStatus/running``/``ToolCallStatus/failed``.
    public var summary: String?
    /// The tool's full output segments once ``ToolCallStatus/completed`` —
    /// every ``SegmentPayload`` the answering `.toolOutput` entry carries, in
    /// entry order, so a `.structure`, `.attachment`, or `.custom` result
    /// survives where ``summary`` flattens it to text — or `nil` for
    /// ``ToolCallStatus/running``/``ToolCallStatus/failed`` and for an entry
    /// that carries no segments.
    public var output: [SegmentPayload]? = nil
}

/// The `@MainActor`/`@Observable` mirror of one ``RoutedSession``'s live
/// state — SwiftUI's binding surface for a session (absorbs the
/// FoundationModelsAgents plan §10 observable-state ask, the "observable
/// transcript").
///
/// ``RoutedSession``/``RoutedSessionActor`` is an actor and so cannot itself
/// be `@Observable` (see ``ResolutionProgress`` for the same pattern applied
/// to resolution). This type is the plain, `@MainActor`-isolated projection a
/// host app pairs with a session instead. It never derives state on its
/// own — a driver feeds it the session's own ``SessionEvent`` vocabulary, one
/// event at a time via ``apply(_:)`` or a whole
/// ``RoutedSession/streamEvents(to:maxTokens:)`` call at a time via
/// ``apply(eventsFrom:)`` — so the actor stays the single source of truth for
/// what actually happened and this projection is always a faithful mirror of
/// it, mutated only by its own `@MainActor`-isolated methods:
///
/// ```swift
/// let projection = SessionProjection()
/// try await projection.apply(eventsFrom: session.streamEvents(to: prompt))
/// // `projection.phase`, `.transcript`, `.tokensIn`/`.tokensOut`, and
/// // `.contextFill` are all live for a SwiftUI view to bind to, updated as
/// // each event arrived.
/// ```
///
/// One projection can observe a session across many turns — ``tokensIn``/
/// ``tokensOut`` accumulate across every ``apply(_:)`` call for the
/// projection's whole lifetime, not just the most recent turn.
@MainActor
@Observable
public final class SessionProjection {
    /// Where a session is in one observed turn, coarse-grained for a status
    /// indicator or spinner.
    ///
    /// Derived from whichever ``SessionEvent`` most recently arrived and
    /// actually updated something — an untracked
    /// ``SessionEvent/toolStatus(id:status:summary:output:)`` (no prior matching
    /// ``SessionEvent/toolCall(id:name:argumentsJSON:)``) leaves it
    /// unchanged rather than reporting ``Phase/runningTool`` for nothing (see
    /// ``updateToolCallRow(id:status:summary:output:in:)``), and
    /// ``SessionEvent/entryRecorded(id:kind:)`` is identity bookkeeping that
    /// never touches it.
    ///
    /// ``Phase/runningTool`` is a *live* signal: a
    /// ``SessionEvent/toolInvocation(_:)`` open record arrives while the
    /// tool's own work still runs and sets it, and the matching close record
    /// returns it to ``Phase/generating`` once the last open invocation
    /// closed (see ``applyToolInvocation(_:)``). The diff-time
    /// ``SessionEvent/toolCall(id:name:argumentsJSON:)``/
    /// ``SessionEvent/toolStatus(id:status:summary:output:)``/
    /// ``SessionEvent/reasoningDelta(_:)`` events — synthesized only once
    /// generation finishes and the turn's own diff runs — still set it too,
    /// as they always did.
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
    /// carries — the top-level ``FoundationModelsRouter/ToolCallEntry``, kept
    /// reachable under this name for source compatibility with code written
    /// while the type was nested here.
    public typealias ToolCallEntry = FoundationModelsRouter.ToolCallEntry

    /// One entry in ``transcript``, identifiable for direct SwiftUI `ForEach` use.
    public struct TranscriptEntry: Sendable, Equatable, Identifiable {
        /// What kind of content one transcript entry carries.
        public enum Kind: Sendable, Equatable {
            /// Accumulated response text, coalesced across consecutive
            /// ``SessionEvent/textDelta(_:)`` fragments into one growing entry.
            case text(String)
            /// Accumulated reasoning text, coalesced across consecutive
            /// ``SessionEvent/reasoningDelta(_:)`` fragments into one growing entry.
            case reasoning(String)
            /// A tool invocation and its live lifecycle.
            case toolCall(ToolCallEntry)
            /// A mid-turn auto-compaction fold's result.
            case compaction(CompactionResult)
        }

        /// This row's identity, derived from the source data — usable
        /// directly as a SwiftUI `ForEach` id, and equal across any two
        /// projections built from the same event sequence.
        ///
        /// Which source datum it is depends on the row's kind:
        ///
        /// - A ``Kind/toolCall(_:)`` row carries the SDK
        ///   `Transcript.ToolCall.id` its
        ///   ``SessionEvent/toolCall(id:name:argumentsJSON:)`` announced.
        /// - A ``Kind/compaction(_:)`` row carries ``CompactionResult/id``.
        /// - A ``Kind/text(_:)``/``Kind/reasoning(_:)`` row starts with a
        ///   deterministic provisional id (`"provisional-<n>"`, a
        ///   per-projection counter) while its deltas stream, then adopts the
        ///   SDK `Transcript.Entry.id` when the turn's
        ///   ``SessionEvent/entryRecorded(id:kind:)`` closes the entry.
        ///
        /// **The one adopt-id transition.** A text or reasoning row
        /// re-identifies exactly once, at the end of its turn, when the SDK
        /// id becomes known. SwiftUI treats that as removing the provisional
        /// row and inserting the adopted one — a single-row transition
        /// confined to the turn boundary, after which the id never changes
        /// again. A row that never receives its close (a turn that failed
        /// before the SDK recorded the entry) keeps its provisional id, which
        /// is still deterministic across projections of the same events.
        public let id: String

        /// This entry's current content.
        public var kind: Kind

        /// The SDK `Transcript.Entry.id` this row joins back to in the raw
        /// transcript and the recording (``TranscriptEntryPayload/entryId``),
        /// or `nil` while none is known.
        ///
        /// For a ``Kind/text(_:)``/``Kind/reasoning(_:)`` row this equals
        /// ``id`` once the row adopted its entry's id — `nil` means the row
        /// is still open (its deltas may still be coalescing). For a
        /// ``Kind/toolCall(_:)`` row it names the `.toolCalls` entry the call
        /// belongs to, distinct from the row's own call ``id``. For a
        /// ``Kind/compaction(_:)`` row it is
        /// ``CompactionResult/summaryEntryId``.
        public let sourceEntryId: String?

        /// Creates a transcript entry.
        ///
        /// - Parameters:
        ///   - id: This row's identity — see ``id`` for the forms it takes.
        ///   - kind: This entry's content.
        ///   - sourceEntryId: The SDK entry id this row joins back to, or
        ///     `nil` while none is known. Defaults to `nil`.
        public init(id: String, kind: Kind, sourceEntryId: String? = nil) {
            self.id = id
            self.kind = kind
            self.sourceEntryId = sourceEntryId
        }
    }

    /// The current phase. See this property's own type, ``Phase``, for when
    /// ``apply(_:)`` does and does not refresh it.
    public private(set) var phase: Phase = .idle

    /// The turn whose events this projection is currently mirroring, and the
    /// queued prompt that caused it where there was one — the most recent
    /// ``SessionEvent/turnStarted(_:)``, or `nil` before the first one arrives.
    ///
    /// This is what attributes everything below to a turn, and through
    /// ``TurnStart/promptId`` to the prompt a client submitted: a session runs
    /// one turn at a time, so every event applied after a frame belongs to that
    /// frame's turn. Deliberately *not* cleared by
    /// ``SessionEvent/turnEnded(_:)``: a turn that retries after a recovered
    /// context overflow closes two of those inside one frame, so clearing on the
    /// first would drop the identity of events still to come.
    public private(set) var currentTurn: TurnStart?

    /// The running transcript observed so far, oldest first.
    public private(set) var transcript: [TranscriptEntry] = []

    /// Cumulative input (prompt) tokens across every ``SessionEvent/turnEnded(_:)``
    /// this projection has observed, across every turn.
    public private(set) var tokensIn: Int = 0

    /// Cumulative output (completion) tokens across every
    /// ``SessionEvent/turnEnded(_:)`` this projection has observed, across
    /// every turn.
    public private(set) var tokensOut: Int = 0

    /// The session's most recently measured ``RoutedSession/contextFill``,
    /// live mid-turn — updated by every ``SessionEvent/turnEnded(_:)``,
    /// including a retried attempt's own (compaction_plan.md §1.7), not only once
    /// per logical turn.
    public private(set) var contextFill: Double = 0

    /// Creates an empty projection in ``Phase/idle``.
    public init() {}

    /// Applies one ``SessionEvent``, updating ``phase`` and whichever of
    /// ``transcript``/``tokensIn``/``tokensOut``/``contextFill`` it carries.
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
            adoptRecordedEntry(id: id, kind: kind)
        case .compaction(let result):
            phase = .compacting
            transcript.append(
                TranscriptEntry(id: result.id, kind: .compaction(result), sourceEntryId: result.summaryEntryId))
        case .discoveryPrimingFailed:
            // Handled explicitly, and deliberately changes nothing: a turn whose
            // discovery priming could not seed generates exactly as an unprimed
            // turn does (see ``SessionEvent/discoveryPrimingFailed(_:)``), so
            // this projection's phase, transcript, and counters are already the
            // faithful mirror of what happened. The failure is a diagnostic for
            // a driver watching the event stream, not session state.
            break
        case .turnEnded(let usage):
            tokensIn += usage.tokensIn
            tokensOut += usage.tokensOut
            contextFill = usage.contextFill
            // A run that detached never closes inside its own turn, so its
            // open invocation is cleared here — a stale open must never pin a
            // later turn's phase to ``Phase/runningTool``. Its late close
            // then finds nothing tracked and changes nothing (see
            // ``applyToolInvocation(_:)``).
            openInvocationCorrelationIDs.removeAll()
            phase = .idle
        }
    }

    /// Drains `stream`, ``apply(_:)``-ing every event as it arrives — the
    /// convenience for feeding a whole ``RoutedSession/streamEvents(to:maxTokens:)``
    /// call straight into this projection.
    ///
    /// Resets to ``Phase/idle`` once the stream finishes, whether it completes
    /// normally or throws, so a turn that fails partway never leaves the
    /// projection stuck reporting a stale non-idle phase.
    ///
    /// - Parameter stream: The event stream to drain.
    /// - Throws: Whatever `stream` throws, after applying every event it
    ///   yielded first.
    public func apply(eventsFrom stream: AsyncThrowingStream<SessionEvent, Error>) async throws {
        defer { phase = .idle }
        for try await event in stream {
            apply(event)
        }
    }

    /// Appends `fragment` to the last entry if it is still a growing, open
    /// entry of the same kind, or starts a new one under a fresh provisional
    /// id — the shared coalescing logic behind ``appendTextFragment(_:)`` and
    /// ``appendReasoningFragment(_:)``, which differ only in which
    /// ``TranscriptEntry/Kind`` case they read and construct.
    ///
    /// An entry stops coalescing the moment it adopts its SDK id
    /// (``TranscriptEntry/sourceEntryId`` becomes non-`nil`): the SDK closed
    /// that entry, so a later fragment belongs to a new one — which is also
    /// what keeps one projection row per SDK entry across turns.
    ///
    /// - Parameters:
    ///   - fragment: The new text to append.
    ///   - matching: Extracts the last entry's accumulated text if it is
    ///     already the coalescing case, or `nil` otherwise.
    ///   - makeKind: Constructs the case to store, given the (possibly
    ///     freshly-coalesced) accumulated text.
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

    /// Appends `fragment` to the last entry if it is already a growing
    /// ``TranscriptEntry/Kind/text(_:)`` entry, or starts a new one — a
    /// fragment that begins a new response (a ``SessionEvent/textReset``
    /// preceded it, as ``responseTextFold`` reports) always starts a new
    /// entry, leaving the superseded text its own row.
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

    /// The shared ``ResponseTextFold`` this projection folds response text
    /// through — the one home of the ``SessionEvent/textReset`` rule, shared
    /// with ``TurnOutcomeFold`` so the rule cannot drift between the two
    /// consumers.
    ///
    /// Not a projected value a driver reads — the bookkeeping that keeps a
    /// superseded response and the response that replaced it two entries, the
    /// way the SDK's own transcript keeps them two `.response` entries.
    private var responseTextFold = ResponseTextFold()

    /// Appends `fragment` to the last entry if it is already a growing
    /// ``TranscriptEntry/Kind/reasoning(_:)`` entry, or starts a new one.
    private func appendReasoningFragment(_ fragment: String) {
        appendFragment(
            fragment,
            matching: { if case .reasoning(let existing) = $0 { return existing } else { return nil } },
            makeKind: TranscriptEntry.Kind.reasoning)
    }

    /// Finds the ``TranscriptEntry/Kind/toolCall(_:)`` row in `rows` whose
    /// ``ToolCallEntry/id`` matches `id` (searching from the end, since a
    /// call's own row is unique per id) and updates its status, summary, and
    /// output in place — the one body behind both the live
    /// ``SessionEvent/toolStatus(id:status:summary:output:)`` update and the cold
    /// seed's `.toolOutput` pairing (see ``transcriptRows(from:)``), so the
    /// two paths cannot drift.
    ///
    /// A true no-op when no matching row exists — defensive against a
    /// status event (or a cold output) with no preceding call, never a
    /// crash — which is why this reports whether it found a match:
    /// ``apply(_:)`` only flips ``phase`` to ``Phase/runningTool`` on a
    /// genuine update, so an untracked status event never surfaces as a
    /// phase change with nothing to show for it.
    ///
    /// - Parameters:
    ///   - id: The call id the update names.
    ///   - status: The call's new status.
    ///   - summary: The tool's flattened output text, or `nil` when it
    ///     carries none.
    ///   - output: The tool's full output segments, or `nil` when it carries
    ///     none — see ``ToolCallEntry/output``.
    ///   - rows: The rows to update — the live ``transcript``, or the cold
    ///     grouping's rows-so-far.
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

    /// The `correlationID` of every ``SessionEvent/toolInvocation(_:)`` open
    /// record whose close has not yet arrived this turn — the live set behind
    /// ``Phase/runningTool``, cleared at ``SessionEvent/turnEnded(_:)`` so a
    /// detached run's never-closing open cannot pin a later turn.
    ///
    /// Not a projected value a driver reads: transcript rows stay diff-driven
    /// (``SessionEvent/toolCall(id:name:argumentsJSON:)`` opens them), and
    /// these ids live in the run's `completionToken` space, never in the SDK
    /// call-id space those rows carry.
    private var openInvocationCorrelationIDs: Set<String> = []

    /// Applies one ``SessionEvent/toolInvocation(_:)`` to ``phase``.
    ///
    /// An open record tracks its `correlationID` and reports
    /// ``Phase/runningTool``. A close record for a tracked open stops
    /// tracking it and, once no invocation remains open, returns the phase to
    /// ``Phase/generating`` — the tool finished but its turn is still
    /// producing. An untracked close — a detached run's late close after its
    /// turn ended, whose open ``SessionEvent/turnEnded(_:)`` already
    /// cleared — changes nothing, the same defensive posture
    /// ``updateToolCallRow(id:status:summary:output:in:)`` takes for an
    /// untracked status.
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

    /// The prefix every provisional row id carries, keeping the provisional
    /// space visibly distinct from every SDK id a row can adopt.
    private static let provisionalIdPrefix = "provisional-"

    /// How many provisional ids this projection has handed out — the counter
    /// behind ``makeProvisionalId()``.
    private var provisionalEntryCount = 0

    /// Returns the next provisional row id.
    ///
    /// Deterministic by construction: the id is this projection's running
    /// count of provisional rows, so two projections fed the same event
    /// sequence hand out identical provisional ids — the property that makes
    /// row identity reproducible even before adoption (see
    /// ``TranscriptEntry/id``).
    private func makeProvisionalId() -> String {
        provisionalEntryCount += 1
        return "\(Self.provisionalIdPrefix)\(provisionalEntryCount)"
    }

    /// Applies one ``SessionEvent/entryRecorded(id:kind:)`` to the transcript:
    /// a `.response`/`.reasoning` close makes the oldest still-open row of the
    /// matching kind adopt the SDK entry id, and a `.toolCalls` close stamps
    /// ``TranscriptEntry/sourceEntryId`` onto that entry's call rows.
    ///
    /// Oldest-first adoption is what pairs rows with entries correctly when a
    /// turn produced more than one of a kind: the diff closes entries in the
    /// order the SDK appended them, and this projection opened its rows in
    /// that same order (``SessionEvent/textReset`` split the superseded text
    /// into its own still-open row), so the first unadopted row is the first
    /// closed entry's.
    ///
    /// A close with no open row of its kind is a no-op — the normal case for
    /// a consumer of ``RoutedSession/streamSessionEvents()``, which never
    /// receives the ``SessionEvent/textDelta(_:)`` fragments that would have
    /// opened a text row.
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

    /// Re-identifies the oldest row that satisfies `isKind` and has not yet
    /// adopted an entry id, giving it `entryId` as both its row identity and
    /// its ``TranscriptEntry/sourceEntryId`` — the one adopt-id transition
    /// ``TranscriptEntry/id`` documents. A no-op when no such row exists.
    ///
    /// - Parameters:
    ///   - entryId: The SDK entry id to adopt.
    ///   - isKind: Whether a row's kind is the one this close names.
    private func adopt(entryId: String, ontoOldestOpenRowWhere isKind: (TranscriptEntry.Kind) -> Bool) {
        guard let index = transcript.firstIndex(where: { $0.sourceEntryId == nil && isKind($0.kind) }) else {
            return
        }
        transcript[index] = TranscriptEntry(id: entryId, kind: transcript[index].kind, sourceEntryId: entryId)
    }

    /// Stamps `sourceEntryId` onto every ``TranscriptEntry/Kind/toolCall(_:)``
    /// row not yet joined to its `.toolCalls` entry, keeping each row's own
    /// call id as its identity.
    ///
    /// Event order makes this correct without carrying per-call data on the
    /// close: a `.toolCalls` entry's ``SessionEvent/toolCall(id:name:argumentsJSON:)``
    /// events all precede its own close, and the previous entry's close
    /// already stamped *its* rows, so the unstamped call rows at this moment
    /// are exactly this entry's.
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

    /// Resets this projection to mirror `transcript` — the cold-start
    /// counterpart of ``apply(_:)``, for a session restored from its recording
    /// (``RoutedModel/restoreSessionTree(root:recordingRoot:registry:tools:)``)
    /// whose history predates every live event this projection could observe.
    ///
    /// Installs the rows ``transcriptRows(from:)`` groups from `transcript`'s
    /// entries and returns everything else to its fresh-projection value —
    /// ``phase`` to ``Phase/idle``, ``currentTurn`` to `nil`, ``tokensIn``/
    /// ``tokensOut``/``contextFill`` to zero (none of the seeded history's
    /// usage was observed by this projection; the session's own restored
    /// ``RoutedSession/contextFill`` is the durable value), and the streaming
    /// coalescing state cleared. Seeding is therefore equal to constructing a
    /// fresh projection and installing the rows, whatever this projection
    /// observed before.
    ///
    /// Live events applied after a seed append normally: every seeded text
    /// and reasoning row already carries its adopted SDK entry id, so a later
    /// turn's ``SessionEvent/textDelta(_:)`` opens a new row rather than
    /// growing a seeded one, and a later ``SessionEvent/entryRecorded(id:kind:)``
    /// adopts onto that new row alone.
    ///
    /// The transcript to seed from comes from ``RoutedSession/transcript`` —
    /// the chosen source, read off the live session — or from
    /// ``TranscriptTree/effectiveTranscript(forSession:registry:view:)`` when
    /// no live session exists; both produce the same entries for a restored
    /// session.
    ///
    /// - Parameter transcript: The cold transcript to mirror.
    public func seed(from transcript: Transcript) {
        self.transcript = Self.transcriptRows(from: Array(transcript))
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
    /// would hold for the same history — the pure function behind
    /// ``seed(from:)`` (task ^5aky6xr).
    ///
    /// Each entry maps through ``TranscriptEntryMapper/event(from:)``, the
    /// same mapping the live diff derives its ``SessionEvent``s from, so call
    /// ids, argument JSON, and text flattening cannot drift between the two
    /// paths. The grouping mirrors the live event fold row for row:
    ///
    /// - A `.response` entry becomes a ``TranscriptEntry/Kind/text(_:)`` row
    ///   that already adopted its entry id — unless it is a compaction
    ///   boundary (it carries a ``CompactionSegment``), which becomes a
    ///   ``TranscriptEntry/Kind/compaction(_:)`` row instead (see
    ///   ``compactionRow(from:entryId:)`` for the one id divergence).
    /// - A `.reasoning` entry becomes a ``TranscriptEntry/Kind/reasoning(_:)``
    ///   row that already adopted its entry id.
    /// - A `.toolCalls` entry becomes one ``TranscriptEntry/Kind/toolCall(_:)``
    ///   row per call, keyed on the call's own id and stamped with the entry
    ///   id as ``TranscriptEntry/sourceEntryId``.
    /// - A `.toolOutput` entry completes its call's row — paired through the
    ///   shared ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``,
    ///   by id equality first and first-occurrence ordinal order second, the
    ///   same rule the live diff applies — carrying the output's flattened
    ///   text as the row's summary and its full segments as the row's
    ///   ``ToolCallEntry/output``. An output that pairs to no row yields
    ///   nothing, exactly as the live projection drops an untracked status.
    /// - A `.prompt` entry yields no row and resets the pairing scope: the
    ///   live rule's scope is one turn's diff, and a turn's diff begins at
    ///   its own `.prompt`.
    /// - Every other kind (`.instructions`, and any future kind) yields no
    ///   row, matching the live event vocabulary.
    ///
    /// Once every entry is grouped, a call row still ``ToolCallStatus/running``
    /// is marked ``ToolCallStatus/failed`` — the cold mirror of the live
    /// diff's closing sweep for a call whose output never arrived.
    ///
    /// Rows come back in transcript order. A live projection's row order can
    /// differ for one row per turn — the answer's text row streams before the
    /// turn's diff appends the tool rows — but every row's content and id are
    /// equal between the two paths.
    ///
    /// - Parameter entries: The cold transcript's entries, oldest first.
    /// - Returns: The rows the entries group into, in transcript order.
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
    /// ``ToolCallStatus/failed`` — the cold mirror of the live diff's closing
    /// sweep, which fails every announced call whose output never arrived.
    ///
    /// - Parameter rows: The rows grouped from the whole transcript.
    private nonisolated static func failUnansweredToolCallRows(in rows: inout [TranscriptEntry]) {
        for index in rows.indices {
            guard case .toolCall(var call) = rows[index].kind, call.status == .running else { continue }
            call.status = .failed
            rows[index].kind = .toolCall(call)
        }
    }

    /// The ``TranscriptEntry/Kind/compaction(_:)`` row a compaction boundary
    /// entry implies, or `nil` when `entry` is an ordinary `.response`.
    ///
    /// A boundary is a `.response` entry carrying a `.custom`
    /// ``CompactionSegment`` (see
    /// ``CompactionSegment/boundaryEntry(id:summaryText:content:)``). The
    /// rebuilt ``CompactionResult`` mirrors the one the live fold emitted:
    /// the summary is the boundary's first text segment (empty text means a
    /// deterministic-only fold, whose live result carried no summary), the
    /// join key ``CompactionResult/summaryEntryId`` is the boundary entry's
    /// own id exactly when a summary exists, and the token counts and stages
    /// come from the persisted ``CompactionSegment/Content``.
    ///
    /// **The one id divergence from a live row.** A live fold's
    /// ``CompactionResult/id`` is generated when the fold runs and is never
    /// persisted, so no cold seed can read it back. The cold row keys on the
    /// persisted ``CompactionSegment/id`` instead — stable across every seed
    /// of the same recording, just not equal to the live run's generated id.
    /// Every other row kind seeds with the exact id its live counterpart
    /// adopted.
    ///
    /// - Parameters:
    ///   - entry: The `.response` entry to inspect.
    ///   - entryId: That entry's own id, already read off its payload.
    /// - Returns: The compaction row, or `nil` for an ordinary response.
    private nonisolated static func compactionRow(
        from entry: Transcript.Entry, entryId: String
    ) -> TranscriptEntry? {
        guard case .response(let response) = entry else { return nil }
        var segment: CompactionSegment?
        var summaryText: String?
        for candidate in response.segments {
            if segment == nil, case .custom(let custom) = candidate,
                let compaction = custom as? CompactionSegment
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
}
