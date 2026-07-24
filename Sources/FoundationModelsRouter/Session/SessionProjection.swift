import Foundation
import Observation

/// The `@MainActor`/`@Observable` mirror of one ``RoutedSession``'s live
/// state — SwiftUI's binding surface for a session (harness-collapse item:
/// absorbs the harness's `HarnessState`, harness plan §10 item 2c
/// "observable transcript").
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
    /// ``SessionEvent/toolStatus(id:status:summary:)`` (no prior matching
    /// ``SessionEvent/toolCall(id:name:argumentsJSON:)``) leaves it
    /// unchanged rather than reporting ``Phase/runningTool`` for nothing (see
    /// ``updateToolCall(id:status:summary:)``). Also not a perfectly
    /// real-time signal — ``RoutedSession/streamEvents(to:maxTokens:)``
    /// only synthesizes ``SessionEvent/toolCall(id:name:argumentsJSON:)``/
    /// ``SessionEvent/toolStatus(id:status:summary:)``/``SessionEvent/reasoningDelta(_:)``
    /// once generation finishes and the turn's own diff runs (see that
    /// method's doc comment on emission order) — but accurate enough to drive
    /// a UI label.
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

    /// One tool invocation's live lifecycle, correlated by ``id`` across its
    /// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` and
    /// ``SessionEvent/toolStatus(id:status:summary:)`` events — load-bearing
    /// for distinguishing two concurrent same-name tool calls, exactly like
    /// the events it is built from.
    public struct ToolCallEntry: Sendable, Equatable, Identifiable {
        /// The invocation's own id.
        public let id: String
        /// The tool's name.
        public let name: String
        /// The call's arguments, as `GeneratedContent.jsonString`.
        public let argumentsJSON: String
        /// The invocation's current status.
        public var status: ToolCallStatus
        /// The tool's output text once ``ToolCallStatus/completed``, or `nil`
        /// for ``ToolCallStatus/running``/``ToolCallStatus/failed``.
        public var summary: String?
    }

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

        /// A stable identity for this entry, independent of its (possibly
        /// still-growing) content — usable directly as a SwiftUI `ForEach` id.
        public let id: ULID

        /// This entry's current content.
        public var kind: Kind

        /// Creates a transcript entry.
        ///
        /// - Parameters:
        ///   - id: A stable identity for this entry. Defaults to a freshly
        ///     generated ``ULID``.
        ///   - kind: This entry's content.
        public init(id: ULID = .generate(), kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// The current phase. See this property's own type, ``Phase``, for when
    /// ``apply(_:)`` does and does not refresh it.
    public private(set) var phase: Phase = .idle

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
    /// including a retried attempt's own (harness plan §5.1), not only once
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
        case .textDelta(let fragment):
            phase = .generating
            appendTextFragment(fragment)
        case .reasoningDelta(let fragment):
            phase = .generating
            appendReasoningFragment(fragment)
        case .toolCall(let id, let name, let argumentsJSON):
            phase = .runningTool
            transcript.append(
                TranscriptEntry(
                    kind: .toolCall(ToolCallEntry(id: id, name: name, argumentsJSON: argumentsJSON, status: .running, summary: nil))))
        case .toolStatus(let id, let status, let summary):
            if updateToolCall(id: id, status: status, summary: summary) {
                phase = .runningTool
            }
        case .compaction(let result):
            phase = .compacting
            transcript.append(TranscriptEntry(kind: .compaction(result)))
        case .turnEnded(let usage):
            tokensIn += usage.tokensIn
            tokensOut += usage.tokensOut
            contextFill = usage.contextFill
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

    /// Appends `fragment` to the last entry if it is already a growing entry
    /// of the same kind, or starts a new one — the shared coalescing logic
    /// behind ``appendTextFragment(_:)`` and ``appendReasoningFragment(_:)``,
    /// which differ only in which ``TranscriptEntry/Kind`` case they read and
    /// construct.
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
        if let last = transcript.last, let existing = matching(last.kind) {
            transcript[transcript.count - 1].kind = makeKind(existing + fragment)
        } else {
            transcript.append(TranscriptEntry(kind: makeKind(fragment)))
        }
    }

    /// Appends `fragment` to the last entry if it is already a growing
    /// ``TranscriptEntry/Kind/text(_:)`` entry, or starts a new one.
    private func appendTextFragment(_ fragment: String) {
        appendFragment(
            fragment,
            matching: { if case .text(let existing) = $0 { return existing } else { return nil } },
            makeKind: TranscriptEntry.Kind.text)
    }

    /// Appends `fragment` to the last entry if it is already a growing
    /// ``TranscriptEntry/Kind/reasoning(_:)`` entry, or starts a new one.
    private func appendReasoningFragment(_ fragment: String) {
        appendFragment(
            fragment,
            matching: { if case .reasoning(let existing) = $0 { return existing } else { return nil } },
            makeKind: TranscriptEntry.Kind.reasoning)
    }

    /// Finds the ``TranscriptEntry/Kind/toolCall(_:)`` entry whose
    /// ``ToolCallEntry/id`` matches `id` (searching from the end, since a
    /// call's own entry is unique per id) and updates its status/summary in
    /// place.
    ///
    /// A true no-op when no matching entry exists — defensive against a
    /// status event with no preceding call, never a crash — which is why this
    /// reports whether it found a match: ``apply(_:)`` only flips ``phase``
    /// to ``Phase/runningTool`` on a genuine update, so an untracked status
    /// event never surfaces as a phase change with nothing to show for it.
    ///
    /// - Returns: Whether a matching entry was found and updated.
    @discardableResult
    private func updateToolCall(id: String, status: ToolCallStatus, summary: String?) -> Bool {
        guard
            let index = transcript.lastIndex(where: {
                if case .toolCall(let call) = $0.kind { return call.id == id }
                return false
            })
        else { return false }
        guard case .toolCall(var call) = transcript[index].kind else { return false }
        call.status = status
        call.summary = summary
        transcript[index].kind = .toolCall(call)
        return true
    }
}
