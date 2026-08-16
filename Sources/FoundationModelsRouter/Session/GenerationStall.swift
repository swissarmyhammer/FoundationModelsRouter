import Foundation
import os

/// The logger a session reports a stalled generation to.
///
/// Its own category rather than ``sessionRecordingLogger``'s, for the same
/// reason ``sessionCompactionLogger`` has one: what it reports is a
/// generation's liveness, not a recording outcome. Every report is logged
/// *and* surfaced as ``SessionEvent/generationStalled(_:)`` — the log is for
/// an operator reading a process's console who instrumented nothing of their
/// own, the event for a host watching the session live (see
/// ``RoutedSession/streamSessionEvents()``, the route that carries it on every
/// turn including the ones that hand their caller a response rather than a
/// stream).
private let generationStallLogger = makeModuleLogger(category: "Generation")

/// What a session could observe about a generation's progress — the honest
/// half of a ``GenerationStall``.
///
/// A stall report is only as strong as what the session can see, and the two
/// generation paths differ. Naming the difference here keeps a consumer from
/// reading a `respond` turn's report as a statement about tokens, which it can
/// never be.
public enum GenerationProgressVisibility: Sendable, Equatable {
    /// The turn streams, so every ``ResponseFragment`` the backend produced is
    /// a real increment the session counted — the surfaces
    /// ``RoutedSession/streamResponse(to:maxTokens:)`` and
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` drive.
    ///
    /// ``GenerationStall/timeWithoutProgress`` is then measured from the last
    /// fragment that arrived, so the report really does say "this generation
    /// has produced no fragment in N seconds". Before the first fragment there
    /// is nothing to measure from, and the report falls back to the start of
    /// the model call — `observed` is `0` whenever it did.
    ///
    /// - Parameter observed: How many fragments arrived before the stall.
    case fragments(observed: Int)

    /// The turn does not stream: the backend hands back one whole `String`, so
    /// no increment exists anywhere for the session to time — the surfaces
    /// ``RoutedSession/respond(to:maxTokens:)`` and
    /// ``RoutedSession/dispatchNextPrompt()`` drive, and the summarizer call a
    /// compaction fold makes.
    ///
    /// ``GenerationStall/timeWithoutProgress`` is then measured from the start
    /// of the model call, and it says exactly one thing: the call has run that
    /// long. It never says a token did, or did not, move. A caller that needs
    /// the stronger statement runs the turn through a streaming surface.
    case wholeAnswer
}

/// A report that a generation in flight has produced nothing the session can
/// observe for a while (task ^z6xcmnh).
///
/// **This bounds nothing.** The session does not cancel the turn, does not
/// fail it, and does not change the answer it eventually returns — see
/// ``RoutedSession/respond(to:maxTokens:)`` for the whole recorded decision.
/// The report exists because, from outside, a stuck decode and a slow one look
/// identical, and that is what makes one expensive to find.
///
/// A stalled generation reports again on each further interval it goes without
/// progress, so the report is a heartbeat rather than a single edge: a caller
/// watching one sees ``timeWithoutProgress`` grow, which is the fact that
/// separates a stuck decode from a slow one.
public struct GenerationStall: Sendable, Equatable, CustomStringConvertible {
    /// How long the generation has gone with no observable progress.
    ///
    /// Measured from the last fragment the session counted, or from the start
    /// of the model call when it has counted none — see ``visibility``, which
    /// says which of the two this is.
    public let timeWithoutProgress: Duration

    /// How long this model call has been in flight, whether or not it made
    /// progress along the way.
    ///
    /// Never less than ``timeWithoutProgress``, and greater whenever the
    /// session counted a fragment after the call began.
    public let timeInFlight: Duration

    /// What the session could observe about this generation's progress, and so
    /// how much ``timeWithoutProgress`` is entitled to claim.
    public let visibility: GenerationProgressVisibility

    /// Creates a stall report.
    ///
    /// - Parameters:
    ///   - timeWithoutProgress: How long the generation has gone with no
    ///     observable progress.
    ///   - timeInFlight: How long this model call has been in flight.
    ///   - visibility: What the session could observe about this generation's
    ///     progress.
    public init(
        timeWithoutProgress: Duration,
        timeInFlight: Duration,
        visibility: GenerationProgressVisibility
    ) {
        self.timeWithoutProgress = timeWithoutProgress
        self.timeInFlight = timeInFlight
        self.visibility = visibility
    }

    /// A one-line rendering of this report — the text the session's own log
    /// line carries, so an operator reading the console and a host reading the
    /// event see the same words.
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

    /// How many decimal places ``secondsText(_:)`` renders — tenths, which is
    /// as precise as a liveness report needs to be.
    private static let secondsFormat = "%.1f"

    /// Renders `duration` as a plain seconds figure for ``description``.
    ///
    /// - Parameter duration: The duration to render.
    /// - Returns: The duration in seconds, to one decimal place.
    private static func secondsText(_ duration: Duration) -> String {
        String(format: secondsFormat, duration.seconds)
    }
}

extension Duration {
    /// Attoseconds in one second — the unit `Duration.components` reports its
    /// fractional part in.
    private static let attosecondsPerSecond: Double = 1e18

    /// This duration in whole and fractional seconds.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / Self.attosecondsPerSecond
    }
}

/// The stall watch over the one model call a session has in flight.
///
/// A value rather than a reference type: it lives in
/// ``RoutedSessionActor/generationStallWatch`` under that actor's isolation,
/// and the watchdog task addresses it by ``id`` instead of holding it, so no
/// watch can outlive the call it belongs to or be mistaken for a later one.
struct GenerationStallWatch: Sendable {
    /// This watch's identity, monotonic per session, so a watchdog left over
    /// from an earlier model call can never report against a later one.
    let id: UInt64

    /// When the model call began.
    let startedAt: ContinuousClock.Instant

    /// When this call last made progress the session could observe — the start
    /// of the call until a fragment arrives.
    var lastProgressAt: ContinuousClock.Instant

    /// How many fragments the session has counted for this call.
    var fragmentsObserved: Int = 0

    /// Whether this call produces fragments the session counts at all.
    ///
    /// Declared by ``RoutedSessionActor/observeGenerationFragments()`` when the
    /// streaming body starts, rather than inferred from the first fragment: a
    /// streaming turn that has produced nothing yet is still a streaming turn,
    /// and reporting it as ``GenerationProgressVisibility/wholeAnswer`` would
    /// claim the session cannot see fragments when it can.
    var producesFragments: Bool = false

    /// What the session can observe about this call, as a report says it.
    var visibility: GenerationProgressVisibility {
        producesFragments ? .fragments(observed: fragmentsObserved) : .wholeAnswer
    }
}

extension RoutedSessionActor {
    /// The seconds ``defaultGenerationStallReportInterval`` is built from.
    ///
    /// Named apart from the interval because a `Duration` is built by a call,
    /// and a number written inside a call names nothing. The reason for the
    /// value is on the interval itself.
    private static let defaultGenerationStallReportIntervalSeconds = 30

    /// How long a model call runs with no observable progress before a session
    /// reports a ``GenerationStall``, unless the session is told otherwise.
    ///
    /// Thirty seconds, because the report is a diagnostic and not a limit: it
    /// has to be long enough that an ordinary slow decode on a loaded machine
    /// never fills a console with reports, and short enough that a caller who
    /// suspects a hang learns within one attention span rather than after a
    /// coffee break. Nothing is decided by this number — a report at the wrong
    /// moment costs a log line, never a result.
    static let defaultGenerationStallReportInterval: Duration =
        .seconds(defaultGenerationStallReportIntervalSeconds)

    /// Installs how long a model call on this session may run with no
    /// observable progress before it reports a ``GenerationStall``.
    ///
    /// Takes effect on the next model call; a call already in flight keeps the
    /// interval its watchdog started with.
    ///
    /// - Parameter interval: The interval to install. A non-positive interval
    ///   turns reporting off for later calls.
    func setGenerationStallReportInterval(_ interval: Duration) {
        generationStallReportInterval = interval
    }

    /// Opens a stall watch over the model call about to start.
    ///
    /// - Returns: The new watch's id, which every later call about this model
    ///   call names.
    func beginGenerationStallWatch() -> UInt64 {
        lastGenerationStallWatchId += 1
        let now = ContinuousClock.now
        generationStallWatch = GenerationStallWatch(
            id: lastGenerationStallWatchId, startedAt: now, lastProgressAt: now)
        return lastGenerationStallWatchId
    }

    /// Closes the stall watch named by `id`, if it is still the one installed.
    ///
    /// Identity-matched for the same reason ``inFlightModelCall`` is: a later
    /// call's own watch is never closed by an earlier one's unwind.
    ///
    /// - Parameter id: The watch to close.
    func endGenerationStallWatch(id: UInt64) {
        guard generationStallWatch?.id == id else { return }
        generationStallWatch = nil
    }

    /// Declares that the model call in flight produces fragments this session
    /// counts, so its reports speak of fragments rather than of call duration.
    ///
    /// Called by the streaming body before it consumes its first fragment. A
    /// call that never calls this reports
    /// ``GenerationProgressVisibility/wholeAnswer``, which is exactly right for
    /// a backend that hands back one whole string.
    func observeGenerationFragments() {
        generationStallWatch?.producesFragments = true
    }

    /// Notes that the model call in flight just produced one fragment, which
    /// restarts the interval a report is measured over.
    func noteGenerationFragment() {
        guard var watch = generationStallWatch else { return }
        watch.fragmentsObserved += 1
        watch.lastProgressAt = ContinuousClock.now
        generationStallWatch = watch
    }

    /// Reports one interval's worth of stall for the watch named by `id`, when
    /// that watch is still installed and has gone the whole interval without
    /// progress.
    ///
    /// Reports to two places at once: this module's log, which needs no
    /// subscription of any kind, and the turn's composed event sink, which
    /// reaches the turn's own stream and every session-scoped subscription
    /// (see ``RoutedSessionActor/currentTurnEventSink``). A model call running
    /// outside a turn frame — the summarizer call of an explicit
    /// ``compact(prompt:budget:)``, which opens no frame — has no sink, so it
    /// reports to the log alone.
    ///
    /// - Parameter id: The watch to report against.
    /// - Returns: Whether that watch is still installed, so its watchdog knows
    ///   whether there is anything left to watch.
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
    /// on each interval it goes without observable progress.
    ///
    /// Runs alongside the model call and ends with it: the call's own `defer`
    /// cancels this, and a watch that is gone ends it too. It reads the
    /// session's interval once, at the start, so a call's cadence cannot
    /// change underneath its own watchdog.
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
