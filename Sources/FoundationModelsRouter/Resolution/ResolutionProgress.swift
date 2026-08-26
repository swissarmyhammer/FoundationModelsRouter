import Foundation
import Observation

/// One slot's live progress through a resolution: its state, the candidate
/// that won it, and its download progress.
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

    /// The share of a slot's work that downloading accounts for.
    private static let downloadShare = 0.5

    /// This slot's contribution to the overall fraction, in `0...1`.
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

/// The UI-bindable progress of a single ``Router/resolve(profile:reporting:)``
/// call. The router mutates it on the main actor as resolution advances.
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
    /// One element of ``phases``: the phase entered and the ``fraction`` at
    /// that moment.
    public typealias PhaseTransition = (phase: Phase, fraction: Double)

    /// The phase transitions of this resolution as an asynchronous sequence.
    /// It yields the current phase first, then each observed change of
    /// ``phase``, and finishes after ``Phase/ready`` or ``Phase/failed(_:)``.
    public var phases: AsyncStream<PhaseTransition> {
        AsyncStream { continuation in
            yieldPhaseTransitions(into: continuation, after: nil)
        }
    }

    /// Yields the current phase when it differs from `lastYielded`, finishes
    /// the stream at a terminal phase, or re-arms an observation of ``phase``.
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
