import Foundation
import os

/// The logger a session reports a stalled generation to.
private let generationStallLogger = makeModuleLogger(category: "Generation")

/// What a session could observe about a generation's progress.
public enum GenerationProgressVisibility: Sendable, Equatable {
    /// The turn streams. `observed` is how many fragments arrived before the
    /// stall. ``GenerationStall/timeWithoutProgress`` is measured from the last
    /// fragment, or from the start of the call before the first.
    case fragments(observed: Int)

    /// The turn returns one whole `String`, so
    /// ``GenerationStall/timeWithoutProgress`` is measured from the call start.
    case wholeAnswer
}

/// A report that a generation in flight has produced nothing the session can
/// observe for an interval. The report bounds nothing. A stalled generation
/// reports again on each further interval without progress.
public struct GenerationStall: Sendable, Equatable, CustomStringConvertible {
    /// How long the generation has gone with no observable progress.
    public let timeWithoutProgress: Duration

    /// How long this model call has been in flight.
    public let timeInFlight: Duration

    /// What the session could observe about this generation's progress.
    public let visibility: GenerationProgressVisibility

    /// Creates a stall report.
    public init(
        timeWithoutProgress: Duration,
        timeInFlight: Duration,
        visibility: GenerationProgressVisibility
    ) {
        self.timeWithoutProgress = timeWithoutProgress
        self.timeInFlight = timeInFlight
        self.visibility = visibility
    }

    /// A one-line rendering of this report, also used as the session's log line.
    public var description: String {
        let without = Self.secondsText(timeWithoutProgress)
        let inFlight = Self.secondsText(timeInFlight)
        switch visibility {
        case .fragments(let observed):
            return """
                generation has produced no fragment in \(without)s \
                (\(observed) so far, \(inFlight)s in flight)
                """
        case .wholeAnswer:
            return """
                generation has produced nothing observable in \(without)s \
                (this turn returns one whole answer, so there is no fragment to time; \
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
    /// until a fragment arrives.
    var lastProgressAt: ContinuousClock.Instant

    /// How many fragments the session has counted for this call.
    var fragmentsObserved: Int = 0

    /// Whether this call produces fragments the session counts. Declared by
    /// ``RoutedSessionActor/observeGenerationFragments()`` when the streaming
    /// body starts, not inferred from the first fragment.
    var producesFragments: Bool = false

    /// What the session can observe about this call, as a report says it.
    var visibility: GenerationProgressVisibility {
        producesFragments ? .fragments(observed: fragmentsObserved) : .wholeAnswer
    }
}

extension RoutedSessionActor {
    /// The seconds ``defaultGenerationStallReportInterval`` is built from.
    private static let defaultGenerationStallReportIntervalSeconds = 30

    /// How long a model call runs with no observable progress before a session
    /// reports a ``GenerationStall``, unless the session is told otherwise.
    static let defaultGenerationStallReportInterval: Duration =
        .seconds(defaultGenerationStallReportIntervalSeconds)

    /// Installs how long a model call on this session may run with no
    /// observable progress before it reports a ``GenerationStall``.
    /// Takes effect on the next model call.
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

    /// Notes that the model call in flight produced one fragment, which
    /// restarts the interval a report is measured over.
    func noteGenerationFragment() {
        guard var watch = generationStallWatch else { return }
        watch.fragmentsObserved += 1
        watch.lastProgressAt = ContinuousClock.now
        generationStallWatch = watch
    }

    /// Reports one interval of stall for the watch named by `id`, when that
    /// watch is still installed and has gone the whole interval without
    /// progress. Reports to the module log and to ``currentTurnEventSink``.
    ///
    /// - Parameter id: The watch to report against.
    /// - Returns: Whether that watch is still installed.
    func reportGenerationStall(id: UInt64) -> Bool {
        guard let watch = generationStallWatch, watch.id == id else { return false }
        let now = ContinuousClock.now
        let withoutProgress = watch.lastProgressAt.duration(to: now)
        guard withoutProgress >= generationStallReportInterval else { return true }
        let stall = GenerationStall(
            timeWithoutProgress: withoutProgress,
            timeInFlight: watch.startedAt.duration(to: now),
            visibility: watch.visibility
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
