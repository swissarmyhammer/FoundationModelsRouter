import Foundation
import FoundationModels

/// The protocol that marks a `Tool` as a background tool.
/// A conforming tool that returns a background ``mount`` always answers
/// at once with a completion-token handle; the work goes on behind it.
/// A plain `Tool` — one that does not conform — runs to completion in band.
/// Each declaration has a default, so a tool states only the part it needs.
///
/// **The return value of a background call is a short report, never the
/// output.** The output of a background run (a shell command, a build, a test
/// run) stays in the tool. The tool returns a report: what ran, how it ended,
/// and how to get the output. The run plane carries that report as it is. It
/// is the terminal event's `detail` in the mailbox, in
/// ``ToolContext/wait(completionToken:seconds:)``, in the
/// ``PendingRunEnvelope`` (pending, or settled inside ``inlineSettleGrace``),
/// and in the journal. Nothing on the run plane cuts it. The model asks the
/// tool for the output when it wants it.
public protocol BackgroundTool {
    /// The mount this tool needs, or `nil` to take the composition site's own.
    /// A declaration wins over the site, timeout included.
    var mount: ToolMount? { get }

    /// Returns the per-call `timeout` encoded in `arguments`, or `nil` to take the mount's own.
    func timeout(from arguments: GeneratedContent) -> TimeInterval?

    /// Returns the `next` sentence of the pending envelope a background call hands the model.
    /// It must name `completionToken`.
    /// - Returns: The `next` text as plain prose; the envelope escapes it.
    func collectInstruction(forCompletionToken completionToken: String) -> String

    /// How long a background call waits for its own run before it answers, or
    /// `nil` to answer at once.
    ///
    /// A short run that settles inside this time answers with the same
    /// ``PendingRunEnvelope``, but with `pending` false and the result in it.
    /// The model then reads the result in the tool output it already has, and
    /// makes no `wait` call at all. A run still going when the time elapses
    /// answers with the pending envelope, exactly as a tool that declares
    /// nothing here does.
    ///
    /// Keep the value small. It is an in-band wait inside the submission of
    /// the turn, so it holds the model for every session on it for its whole
    /// time (task ^1psqdm9), and a run on the same model can never settle
    /// inside it. It buys a short run one round trip and costs a long run
    /// that same small delay.
    var inlineSettleGrace: TimeInterval? { get }

    /// Returns the `next` sentence of the envelope a background call hands the
    /// model when the run settled inside ``inlineSettleGrace``.
    ///
    /// It must tell the model to answer from the `detail` beside it, and that
    /// there is nothing left to collect.
    ///
    /// - Returns: The `next` text as plain prose; the envelope escapes it.
    func resultInstruction(forCompletionToken completionToken: String) -> String

    /// What kind of work a background call of this tool is.
    /// A ``RunKind/process`` tool must supply ``canceler(forCompletionToken:)``.
    var runKind: RunKind { get }

    /// Returns the canceler for the run backgrounded under `completionToken`,
    /// or `nil` to take the cooperative one, which reports ``OperationOutcome/cancelled``.
    func canceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)?
}

extension BackgroundTool {
    /// Blanket default: ``PendingRunEnvelope/defaultCollectInstruction(forCompletionToken:)``.
    public func collectInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
    }

    /// Blanket default: ``PendingRunEnvelope/defaultResultInstruction(forCompletionToken:)``.
    public func resultInstruction(forCompletionToken completionToken: String) -> String {
        PendingRunEnvelope.defaultResultInstruction(forCompletionToken: completionToken)
    }

    /// Blanket default: no declared mount.
    public var mount: ToolMount? { nil }

    /// Blanket default: no wait, so a background call answers at once.
    public var inlineSettleGrace: TimeInterval? { nil }

    /// Blanket default: no per-call timeout.
    public func timeout(from arguments: GeneratedContent) -> TimeInterval? {
        nil
    }

    /// Blanket default: ``RunKind/swiftTask``.
    public var runKind: RunKind { .swiftTask }

    /// Blanket default: `nil`, so the cooperative canceler is used.
    public func canceler(
        forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)? {
        nil
    }
}
