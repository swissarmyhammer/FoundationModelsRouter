import Foundation
import FoundationModels
import os

/// The logger a session reports a stalled generation to.
private let generationStallLogger = makeModuleLogger(category: "Generation")

/// What a session could observe about a generation's progress.
public enum GenerationProgressVisibility: Sendable, Equatable {
    /// The turn streams. `observed` is how many text fragments of the whole
    /// model call arrived before the stall. ``GenerationStall/timeWithoutProgress``
    /// is measured from the last append of any ``GenerationProgressKind``, or
    /// from the moment the current pass took its queue place when that is
    /// later.
    case fragments(observed: Int)

    /// The turn returns one whole `String`, so there is no text fragment to
    /// count. ``GenerationStall/timeWithoutProgress`` is measured from the last
    /// tool call or tool result, or from the start of the call before the
    /// first, or from the moment the current pass took its queue place when
    /// that is later.
    case wholeAnswer
}

/// The kind of the last append a model call made. Each append restarts the
/// interval a ``GenerationStall`` is measured over, and the report names the
/// kind of the last one.
public enum GenerationProgressKind: Sendable, Equatable {
    /// No append yet. The report is measured from the start of the call.
    case callStart

    /// A text fragment of the response.
    case fragment

    /// A reasoning entry in the transcript.
    case reasoning

    /// A tool call: a tool-calls entry in the transcript, or an open tool
    /// invocation.
    case toolCall

    /// A tool result: a tool-output entry in the transcript, or a closed tool
    /// invocation.
    case toolResult

    /// A transcript entry of a different kind: instructions, a prompt, or a
    /// response.
    case transcriptEntry

    /// The kind of append that `entry` is, when a snapshot adds it to the
    /// transcript.
    ///
    /// - Parameter entry: The transcript entry a snapshot added.
    init(appending entry: FoundationModels.Transcript.Entry) {
        switch entry {
        case .toolCalls:
            self = .toolCall
        case .toolOutput:
            self = .toolResult
        case .reasoning:
            self = .reasoning
        case .instructions, .prompt, .response:
            self = .transcriptEntry
        @unknown default:
            self = .transcriptEntry
        }
    }

    /// The words a report writes after "since" for this kind.
    var reportPhrase: String {
        switch self {
        case .callStart:
            "the start of the call"
        case .fragment:
            "the last fragment"
        case .reasoning:
            "the last reasoning entry"
        case .toolCall:
            "the last tool call"
        case .toolResult:
            "the last tool result"
        case .transcriptEntry:
            "the last transcript entry"
        }
    }
}

/// A report that a generation in flight has produced nothing the session can
/// observe for an interval. The report bounds nothing. A stalled generation
/// reports again on each further interval without progress.
///
/// The report measures generation, and not a wait (task ^ake8sax). When the
/// backend of the session runs over the per-session queued wrapper of the
/// live container, each pass of the model call reports when it holds its
/// place in the ``GenerationQueue`` of its model. The session then counts
/// only the time a pass holds its place: a wait for a queue place and a tool
/// body between two passes give no report. A backend with no executor seam
/// reports no pass, and the whole call counts.
public struct GenerationStall: Sendable, Equatable, CustomStringConvertible {
    /// How long the generation has gone with no observable progress.
    ///
    /// For a backend that reports its passes, this is measured only over the
    /// time a pass holds its queue place: from the later of the last progress
    /// and the moment the current pass took its place. For a backend with no
    /// executor seam, it is measured from the last progress.
    public let timeWithoutProgress: Duration

    /// How long this model call has been in flight: the whole call, with each
    /// wait for a queue place and each tool body in it.
    public let timeInFlight: Duration

    /// What the session could observe about this generation's progress. A
    /// ``GenerationProgressVisibility/fragments(observed:)`` count covers the
    /// whole model call.
    public let visibility: GenerationProgressVisibility

    /// The kind of the last append. A pass that takes its queue place is not
    /// progress, so the kind does not change when a pass starts.
    /// ``timeWithoutProgress`` is measured from this append, or from the
    /// moment the current pass took its place when that is later.
    public let lastProgress: GenerationProgressKind

    /// Creates a stall report.
    public init(
        timeWithoutProgress: Duration,
        timeInFlight: Duration,
        visibility: GenerationProgressVisibility,
        lastProgress: GenerationProgressKind
    ) {
        self.timeWithoutProgress = timeWithoutProgress
        self.timeInFlight = timeInFlight
        self.visibility = visibility
        self.lastProgress = lastProgress
    }

    /// A one-line rendering of this report, also used as the session's log line.
    public var description: String {
        let without = Self.secondsText(timeWithoutProgress)
        let inFlight = Self.secondsText(timeInFlight)
        let stalled = "generation has made no progress for \(without)s since \(lastProgress.reportPhrase)"
        switch visibility {
        case .fragments(let observed):
            return "\(stalled) (\(observed) fragments so far, \(inFlight)s in flight)"
        case .wholeAnswer:
            return """
                \(stalled) (this turn returns one whole answer, so there is no fragment to count; \
                \(inFlight)s in flight)
                """
        }
    }

    /// The format ``secondsText(_:)`` renders with: tenths of a second.
    private static let secondsFormat = "%.1f"

    /// Renders `duration` in seconds, to one decimal place, for ``description``.
    private static func secondsText(_ duration: Duration) -> String {
        String(format: secondsFormat, duration.seconds)
    }
}

extension Duration {
    /// Attoseconds in one second, the unit of `Duration.components.attoseconds`.
    private static let attosecondsPerSecond: Double = 1e18

    /// This duration in whole and fractional seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / Self.attosecondsPerSecond
    }
}

/// The stall watch over the one model call a session has in flight.
/// The watchdog task addresses it by ``id``, so a watch cannot be mistaken
/// for a later one.
struct GenerationStallWatch: Sendable {
    /// This watch's identity, monotonic per session.
    let id: UInt64

    /// When the model call began.
    let startedAt: ContinuousClock.Instant

    /// When this call last made observable progress. The start of the call
    /// until the first append.
    var lastProgressAt: ContinuousClock.Instant

    /// The kind of the last append, or ``GenerationProgressKind/callStart``
    /// before the first.
    var lastProgressKind: GenerationProgressKind = .callStart

    /// How many text fragments the session has counted for this call.
    var fragmentsObserved: Int = 0

    /// Whether this call produces fragments the session counts. Declared by
    /// ``RoutedSessionActor/observeGenerationFragments()`` when the streaming
    /// body starts, not inferred from the first fragment.
    var producesFragments: Bool = false

    /// Whether the backend of this call reports its passes. Set by the first
    /// ``GenerationPassPhase`` of the call. Until then the watch measures the
    /// whole call, as it does for a backend with no executor seam.
    var reportsPasses = false

    /// When the pass of this call that holds its queue place took the place,
    /// or `nil` while no pass of this call holds a place.
    var passHeldSince: ContinuousClock.Instant?

    /// What the session can observe about this call, as a report says it.
    var visibility: GenerationProgressVisibility {
        producesFragments ? .fragments(observed: fragmentsObserved) : .wholeAnswer
    }

    /// The instant that the time without progress is measured from now, or
    /// `nil` when no time counts now.
    ///
    /// For a call whose backend reports its passes, only the time a pass
    /// holds its queue place counts: the later of the last progress and the
    /// moment the current pass took its place. A wait for a queue place and
    /// a tool body between two passes count nothing. For any other call, the
    /// time counts from the last progress.
    var measuredFrom: ContinuousClock.Instant? {
        guard reportsPasses else { return lastProgressAt }
        guard let passHeldSince else { return nil }
        return max(lastProgressAt, passHeldSince)
    }

    /// Applies one reported phase of a pass of this call. Taking a queue
    /// place is not progress, so ``lastProgressAt`` does not change.
    ///
    /// - Parameter phase: The phase the pass reported.
    mutating func apply(_ phase: GenerationPassPhase) {
        reportsPasses = true
        switch phase {
        case .started(let instant, _):
            passHeldSince = instant
        case .queued, .ended:
            passHeldSince = nil
        }
    }
}

extension RoutedSessionActor {
    /// See ``RoutedSession/setGenerationStallReportInterval(_:)``.
    ///
    /// - Parameter interval: The interval to install. A non-positive interval
    ///   turns reporting off for later calls.
    func setGenerationStallReportInterval(_ interval: Duration) {
        generationStallReportInterval = interval
    }

    /// Opens a stall watch over the model call about to start.
    ///
    /// - Returns: The new watch's id.
    func beginGenerationStallWatch() -> UInt64 {
        lastGenerationStallWatchId += 1
        let now = ContinuousClock.now
        generationStallWatch = GenerationStallWatch(
            id: lastGenerationStallWatchId, startedAt: now, lastProgressAt: now)
        return lastGenerationStallWatchId
    }

    /// Closes the stall watch named by `id`, if it is still the one installed.
    ///
    /// - Parameter id: The watch to close.
    func endGenerationStallWatch(id: UInt64) {
        guard generationStallWatch?.id == id else { return }
        generationStallWatch = nil
    }

    /// Declares that the model call in flight produces fragments this session
    /// counts. The streaming body calls this before its first fragment.
    func observeGenerationFragments() {
        generationStallWatch?.producesFragments = true
    }

    /// Notes that the model call in flight made one append, which restarts the
    /// interval a report is measured over. A text fragment also adds one to
    /// the fragment count.
    ///
    /// - Parameter kind: The kind of the append.
    func noteGenerationProgress(_ kind: GenerationProgressKind) {
        guard var watch = generationStallWatch else { return }
        if kind == .fragment {
            watch.fragmentsObserved += 1
        }
        watch.lastProgressAt = ContinuousClock.now
        watch.lastProgressKind = kind
        generationStallWatch = watch
    }

    /// Reports one interval of stall for the watch named by `id`, when that
    /// watch is still installed and has gone the whole interval without
    /// progress. Reports to the module log and to ``currentTurnEventSink``.
    ///
    /// It first takes the pass phases not yet applied
    /// (``drainGenerationPassPhases()``), so the report reads whether a pass
    /// holds its queue place now, and not a moment ago. See
    /// ``GenerationStallWatch/measuredFrom`` for the time that counts.
    ///
    /// - Parameter id: The watch to report against.
    /// - Returns: Whether that watch is still installed.
    func reportGenerationStall(id: UInt64) -> Bool {
        drainGenerationPassPhases()
        guard let watch = generationStallWatch, watch.id == id else { return false }
        guard let measuredFrom = watch.measuredFrom else { return true }
        let now = ContinuousClock.now
        let withoutProgress = measuredFrom.duration(to: now)
        guard withoutProgress >= generationStallReportInterval else { return true }
        let stall = GenerationStall(
            timeWithoutProgress: withoutProgress,
            timeInFlight: watch.startedAt.duration(to: now),
            visibility: watch.visibility,
            lastProgress: watch.lastProgressKind
        )
        generationStallLogger.warning(
            "session \(self.id.description, privacy: .public): \(stall.description, privacy: .public)"
        )
        currentTurnEventSink?(.generationStalled(stall))
        return true
    }

    /// Watches the model call named by `id`, reporting a ``GenerationStall``
    /// on each interval it goes without observable progress. Ends when the
    /// task is cancelled or the watch is gone. Reads the interval once.
    ///
    /// The watch runs over the whole model call, but for a backend that
    /// reports its passes it counts only the time a pass holds its queue
    /// place (``GenerationStallWatch/measuredFrom``). A wait for a queue place
    /// and a tool body between two passes make no report (task ^ake8sax).
    ///
    /// - Parameter id: The watch to report against.
    func watchGenerationForStalls(id: UInt64) async {
        let interval = generationStallReportInterval
        guard interval > .zero else { return }
        while true {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard reportGenerationStall(id: id) else { return }
        }
    }
}
