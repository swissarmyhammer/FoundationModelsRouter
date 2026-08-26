import Foundation
import FoundationModels

/// The hook a wrapped tool states its own mount parameters through.
/// Each declaration has a default, so a tool states only the part it needs.
public protocol DetachmentParameterProviding {
    /// The mount this tool needs, or `nil` to take the composition site's own.
    /// A declaration wins over the site, timeout included.
    var detachmentMount: DetachConfiguration? { get }

    /// Returns the per-call `timeout` encoded in `arguments`, or `nil` to take the mount's own.
    func detachmentTimeout(from arguments: GeneratedContent) -> TimeInterval?

    /// Returns the `next` sentence of the pending envelope a background call hands the model.
    /// It must name `completionToken` and keep the envelope under ``ToolContext/terminalDetailTailLimit``.
    /// - Returns: The `next` text as plain prose; the envelope escapes it.
    func detachmentCollectInstruction(forCompletionToken completionToken: String) -> String

    /// What kind of work a background call of this tool is.
    /// A ``RunKind/process`` tool must supply ``detachmentCanceler(forCompletionToken:)``.
    var detachmentRunKind: RunKind { get }

    /// Returns the canceler for the run backgrounded under `completionToken`,
    /// or `nil` to take the cooperative one, which reports ``OperationOutcome/cancelled``.
    func detachmentCanceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)?
}

extension DetachmentParameterProviding {
    /// Blanket default: ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``.
    public func detachmentCollectInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// Blanket default: no declared mount.
    public var detachmentMount: DetachConfiguration? { nil }

    /// Blanket default: no per-call timeout.
    public func detachmentTimeout(from arguments: GeneratedContent) -> TimeInterval? {
        nil
    }

    /// Blanket default: ``RunKind/swiftTask``.
    public var detachmentRunKind: RunKind { .swiftTask }

    /// Blanket default: `nil`, so the cooperative canceler is used.
    public func detachmentCanceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)? {
        nil
    }
}

/// The mode and timeout a tool is mounted under. Every progress event resets ``timeout``.
public struct DetachConfiguration: Sendable, Equatable {
    /// Whether a call returns a background handle at once or runs to completion.
    public enum Mode: Sendable, Equatable {
        /// Every call returns the pending envelope at once; the work goes on behind it.
        case background

        /// Each call runs to completion, bounded by ``DetachConfiguration/timeout``.
        case runToCompletion
    }

    /// The stock per-call timeout, in seconds.
    public static let defaultTimeoutSeconds: TimeInterval = 120

    /// The native-session mount: run to completion under ``defaultTimeoutSeconds``.
    public static let nativeSessionMount = DetachConfiguration(
        mode: .runToCompletion, timeout: defaultTimeoutSeconds
    )

    /// The mount that runs to completion with no timeout.
    public static let runToCompletionMount = DetachConfiguration(
        mode: .runToCompletion, timeout: nil
    )

    /// Whether a call returns a background handle at once or runs to completion.
    public var mode: Mode

    /// How long the work may run with no progress, in seconds, or `nil` for no timeout.
    /// A pending elicitation suspends it. Expiry settles the run as ``OperationOutcome/timedOut``.
    public var timeout: TimeInterval?

    /// Creates a configuration.
    public init(mode: Mode, timeout: TimeInterval? = Self.defaultTimeoutSeconds) {
        self.mode = mode
        self.timeout = timeout
    }
}

/// The one failure the tool mounts themselves produce. The model reads it in place of the tool's output.
public enum DetachingToolError: Error, Equatable, CustomStringConvertible {
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
