import Foundation
import FoundationModels

/// The hook a wrapped tool states its own mount parameters through.
///
/// Each declaration has a default, so a tool states only the part it needs.
/// A tool that does not conform runs under the configuration its
/// composition site passes, with the default collect sentence, as a
/// ``RunKind/swiftTask`` run under the cooperative canceler.
public protocol DetachmentParameterProviding {
    /// The mount this tool needs whatever mount its composition site
    /// applies, or `nil` to take that site's own. A tool known ahead of
    /// time to run long declares `DetachConfiguration(mode: .background,
    /// timeout: nil)` here. A declaration wins over the site, timeout and all.
    var detachmentMount: DetachConfiguration? { get }

    /// Returns the per-call `timeout` encoded in `arguments`, or `nil` when
    /// the call does not supply one.
    ///
    /// - Parameter arguments: The call's arguments as opaque `GeneratedContent`.
    /// - Returns: The per-call `timeout`, or `nil` to take the mount's own.
    func detachmentTimeout(from arguments: GeneratedContent) -> TimeInterval?

    /// Returns the `next` sentence of the pending envelope a background call
    /// of this tool hands the model: the collect step the tool's own host
    /// offers. It must name `completionToken`, lead to a step that returns the
    /// result in band, and keep the whole envelope under
    /// ``ToolContext/terminalDetailTailLimit``.
    ///
    /// - Parameter completionToken: The background run's completion token.
    /// - Returns: The `next` text as plain prose; the envelope escapes it.
    func detachmentCollectInstruction(forCompletionToken completionToken: String) -> String

    /// What kind of work a background call of this tool is. A capability that
    /// spawns an OS process group declares ``RunKind/process`` and then owes
    /// a canceler of its own through ``detachmentCanceler(forCompletionToken:)``.
    var detachmentRunKind: RunKind { get }

    /// Returns the canceler for the run backgrounded under `completionToken`,
    /// or `nil` to take the cooperative one, which requests the run's task
    /// stop and reports ``OperationOutcome/cancelled``. The run plane reports
    /// what the canceler reports, never a guess.
    ///
    /// - Parameter completionToken: The background run's completion token.
    /// - Returns: The canceler for that run, or `nil`.
    func detachmentCanceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)?
}

extension DetachmentParameterProviding {
    /// Blanket default: ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``.
    ///
    /// - Parameter completionToken: The background run's completion token.
    /// - Returns: The default collect sentence for `completionToken`.
    public func detachmentCollectInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// Blanket default: no declared mount.
    public var detachmentMount: DetachConfiguration? { nil }

    /// Blanket default: no per-call timeout.
    ///
    /// - Parameter arguments: The call's arguments, which this default does not read.
    /// - Returns: `nil`.
    public func detachmentTimeout(from arguments: GeneratedContent) -> TimeInterval? {
        nil
    }

    /// Blanket default: ``RunKind/swiftTask``.
    public var detachmentRunKind: RunKind { .swiftTask }

    /// Blanket default: `nil`, so the cooperative canceler is used.
    ///
    /// - Parameter completionToken: The background run's completion token,
    ///   which this default does not read.
    /// - Returns: `nil`.
    public func detachmentCanceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)? {
        nil
    }
}

/// The mode and timeout a tool is mounted under. ``mode`` selects
/// ``BackgroundTool`` or ``RunToCompletionTool``; ``timeout`` bounds the
/// work, and every progress event resets it.
public struct DetachConfiguration: Sendable, Equatable {
    /// Whether a call returns a background handle at once or runs to completion.
    public enum Mode: Sendable, Equatable {
        /// Every call is tracked in the session's ``SessionMailbox`` at once
        /// and returns the pending envelope; the work goes on behind it.
        /// The mode a shell tool or an agent tool declares for itself.
        case background

        /// Each call runs to completion — the default for every tool.
        /// ``DetachConfiguration/timeout`` still bounds the work unless it
        /// is `nil`.
        case runToCompletion
    }

    /// The stock per-call timeout. A tool that hangs past it with no
    /// progress is reported as ``DetachingToolError/timedOut(tool:timeoutSeconds:)``.
    public static let defaultTimeoutSeconds: TimeInterval = 120

    /// The native-session mount: run to completion under ``defaultTimeoutSeconds``.
    /// The one configuration every session tool-composition site applies.
    public static let nativeSessionMount = DetachConfiguration(
        mode: .runToCompletion, timeout: defaultTimeoutSeconds
    )

    /// The mount for a tool whose result the model cannot proceed without:
    /// a call blocks until the tool finishes, under no clock at all, so only
    /// a real failure of the tool reaches the model. A tool asks for it
    /// through ``DetachmentParameterProviding/detachmentMount``.
    public static let runToCompletionMount = DetachConfiguration(
        mode: .runToCompletion, timeout: nil
    )

    /// Whether a call returns a background handle at once or runs to completion.
    public var mode: Mode

    /// How long the work may run with no progress, in seconds, or `nil` for
    /// no timeout at all. A pending elicitation suspends it. Expiry cancels
    /// the work and settles the run as ``OperationOutcome/timedOut``.
    public var timeout: TimeInterval?

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - mode: Whether a call returns a background handle at once or runs to completion.
    ///   - timeout: How long the work may run with no progress, or `nil` for
    ///     no timeout. Defaults to ``defaultTimeoutSeconds``.
    public init(mode: Mode, timeout: TimeInterval? = Self.defaultTimeoutSeconds) {
        self.mode = mode
        self.timeout = timeout
    }
}

/// The one failure the tool mounts themselves produce. It renders as a
/// sentence, because the model reads it in place of the tool's output.
public enum DetachingToolError: Error, Equatable, CustomStringConvertible {
    /// The per-call `timeout` elapsed with no progress and no pending
    /// elicitation; the work was cancelled and the run settled as
    /// ``OperationOutcome/timedOut``.
    case timedOut(tool: String, timeoutSeconds: TimeInterval)

    /// What the failure says to whoever reads it.
    public var description: String {
        switch self {
        case .timedOut(let tool, let timeoutSeconds):
            "\(tool) timed out after \(timeoutSeconds) seconds with no progress"
        }
    }
}
