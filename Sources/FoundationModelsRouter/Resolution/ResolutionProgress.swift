import Foundation
import Observation

/// One slot's live progress through a resolution: which state it is in, the
/// candidate that won it, and how much of its weights have downloaded.
///
/// `chosen` is set once joint fit picks the slot's model; `bytesDownloaded` and
/// `bytesTotal` track the weight download. The value is pure data so it binds
/// straight into a SwiftUI row.
public struct SlotProgress: Sendable, Equatable {
    /// Where a single slot is in the resolution pipeline.
    public enum State: Sendable, Equatable {
        /// Not yet started.
        case pending
        /// Being sized against the budget.
        case sizing
        /// Weights are downloading.
        case downloading
        /// Weights downloaded; the model is loading/warming.
        case loading
        /// Loaded and resident.
        case ready
        /// This slot failed; the associated value is the reason.
        case failed(String)
    }

    /// The slot's current state.
    public var state: State

    /// The candidate that won the slot in joint fit, or `nil` until chosen.
    public var chosen: ModelRef?

    /// Bytes of the chosen model's weights downloaded so far.
    public var bytesDownloaded: Int64

    /// Total bytes of the chosen model's weights, or `0` when not yet known.
    public var bytesTotal: Int64

    /// Creates a slot progress value.
    ///
    /// - Parameters:
    ///   - state: The slot's current state. Defaults to ``State/pending``.
    ///   - chosen: The winning candidate, or `nil`.
    ///   - bytesDownloaded: Bytes downloaded so far. Defaults to `0`.
    ///   - bytesTotal: Total bytes expected, or `0` when unknown. Defaults to `0`.
    public init(
        state: State = .pending,
        chosen: ModelRef? = nil,
        bytesDownloaded: Int64 = 0,
        bytesTotal: Int64 = 0
    ) {
        self.state = state
        self.chosen = chosen
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    /// The share of a slot's work that downloading accounts for, the rest
    /// being the load that follows it. Fully earned the moment the last byte
    /// lands, which is why a loading slot reads exactly this.
    private static let downloadShare = 0.5

    /// This slot's contribution to the overall fraction, in `0...1`.
    ///
    /// Downloading counts as the first ``downloadShare`` of a slot's work and
    /// loading as the rest, so a slot reads `0` until it downloads, climbs to
    /// ``downloadShare`` while bytes arrive, sits there once loading, and
    /// reads `1` when ready.
    var progressFraction: Double {
        switch state {
        case .pending, .sizing, .failed:
            return 0
        case .downloading:
            return bytesTotal > 0
                ? Self.downloadShare * Double(bytesDownloaded) / Double(bytesTotal)
                : 0
        case .loading:
            return Self.downloadShare
        case .ready:
            return 1
        }
    }
}

/// The UI-bindable progress of a single ``Router/resolve(profile:reporting:)`` call.
///
/// It is `@MainActor @Observable` so it can be bound directly into SwiftUI and
/// drive a `ProgressView`; the router mutates it on the main actor as resolution
/// advances `sizing → downloading → loading → ready` (or `failed`). `fraction`
/// is the overall `0...1` bar, derived from the per-slot ``slots`` progress.
@MainActor
@Observable
public final class ResolutionProgress {
    /// The overall phase of a resolution.
    public enum Phase: Sendable, Equatable {
        /// Sizing candidates against the budget and running joint fit.
        case sizing
        /// Downloading the chosen models' weights.
        case downloading
        /// Loading/warming the downloaded models.
        case loading
        /// All three models are resident; resolution succeeded.
        case ready
        /// Resolution failed; the associated value is the diagnostic message.
        case failed(String)
    }

    /// The current overall phase.
    public var phase: Phase = .sizing

    /// The overall progress in `0...1`, driving a `ProgressView`.
    public var fraction: Double = 0

    /// Per-slot progress, keyed by slot.
    public var slots: [ModelSlot: SlotProgress] = [:]

    /// Creates a fresh, empty progress in the ``Phase/sizing`` phase.
    public init() {}

    /// Recomputes ``fraction`` as the mean of the slots' ``SlotProgress/progressFraction``.
    ///
    /// With no slots the fraction is `0`. When every slot is ``SlotProgress/State/ready``
    /// the mean is exactly `1`.
    func refreshFraction() {
        guard !slots.isEmpty else {
            fraction = 0
            return
        }
        let total = slots.values.reduce(0.0) { $0 + $1.progressFraction }
        fraction = total / Double(slots.count)
    }
}

extension ResolutionProgress {
    /// One element of ``phases``: the phase the resolution entered, and the
    /// overall ``fraction`` at that moment.
    public typealias PhaseTransition = (phase: Phase, fraction: Double)

    /// The phase transitions of this resolution as an asynchronous sequence.
    ///
    /// The `@Observable` surface serves SwiftUI; this sequence serves a CLI
    /// or a test, replacing the polling task such a caller would otherwise
    /// write:
    ///
    /// ```swift
    /// for await transition in progress.phases {
    ///     print("phase=\(transition.phase) fraction=\(transition.fraction)")
    /// }
    /// ```
    ///
    /// The sequence yields the current phase first, then yields each observed
    /// change of ``phase`` exactly once, and finishes after it yields
    /// ``Phase/ready`` or ``Phase/failed(_:)``. It never polls: each element
    /// arrives from an observation of ``phase``, so an idle resolution costs
    /// nothing. A phase the resolution enters and leaves between two
    /// observations is skipped — the same visibility a polling loop had.
    public var phases: AsyncStream<PhaseTransition> {
        AsyncStream { continuation in
            yieldPhaseTransitions(into: continuation, after: nil)
        }
    }

    /// Yields the current phase into `continuation` when it differs from
    /// `lastYielded`, finishes the stream at a terminal phase, and otherwise
    /// re-arms an observation of ``phase`` to run again on its next change.
    ///
    /// - Parameters:
    ///   - continuation: The stream to yield transitions into.
    ///   - lastYielded: The phase this chain yielded last, or `nil` before
    ///     the first element.
    private func yieldPhaseTransitions(
        into continuation: AsyncStream<PhaseTransition>.Continuation,
        after lastYielded: Phase?
    ) {
        var latestYielded = lastYielded
        if phase != latestYielded {
            continuation.yield((phase: phase, fraction: fraction))
            latestYielded = phase
        }
        switch phase {
        case .ready, .failed:
            continuation.finish()
        case .sizing, .downloading, .loading:
            let observed = latestYielded
            withObservationTracking {
                _ = phase
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else {
                        continuation.finish()
                        return
                    }
                    self.yieldPhaseTransitions(into: continuation, after: observed)
                }
            }
        }
    }
}
