import Foundation
import FoundationModels

/// The mode and timeout a tool is mounted under. Every progress event resets ``timeout``.
public struct ToolMount: Sendable, Equatable {
    /// Whether a call returns a background handle at once or runs to completion.
    public enum Mode: Sendable, Equatable {
        /// Every call returns the pending envelope at once; the work goes on behind it.
        case background

        /// Each call runs to completion, bounded by ``ToolMount/timeout``.
        case runToCompletion
    }

    /// The stock per-call timeout, in seconds.
    public static let defaultTimeoutSeconds: TimeInterval = 120

    /// The synchronous mount: run to completion under ``defaultTimeoutSeconds``.
    public static let synchronous = ToolMount(
        mode: .runToCompletion, timeout: defaultTimeoutSeconds
    )

    /// The mount that runs to completion with no timeout.
    public static let synchronousUnbounded = ToolMount(
        mode: .runToCompletion, timeout: nil
    )

    /// Whether a call returns a background handle at once or runs to completion.
    public var mode: Mode

    /// How long the work may run with no progress, in seconds, or `nil` for no timeout.
    /// A pending elicitation suspends it. Expiry settles the run as ``OperationOutcome/timedOut``.
    public var timeout: TimeInterval?

    /// Creates a mount.
    public init(mode: Mode, timeout: TimeInterval? = Self.defaultTimeoutSeconds) {
        self.mode = mode
        self.timeout = timeout
    }
}

/// The one failure the tool mounts themselves produce. The model reads it in place of the tool's output.
public enum ToolMountError: Error, Equatable, CustomStringConvertible {
    /// The per-call `timeout` elapsed with no progress and no pending elicitation.
    case timedOut(tool: String, timeoutSeconds: TimeInterval)

    /// What the failure says to whoever reads it.
    public var description: String {
        switch self {
        case .timedOut(let tool, let timeoutSeconds):
            "\(tool) timed out after \(timeoutSeconds) seconds with no progress"
        }
    }
}
