import FoundationModels
import FoundationModelsExtras

/// The context projection of a session (`mailbox.md`, section 5, problems
/// 10 and 11, and section 7): it selects and renders the recorded
/// transcript into the context that the model reads.
///
/// The context is a render of the transcript, in transcript order:
///
/// - The render starts at the last compacted value (the newest
///   ``CompactionSegment`` checkpoint) and keeps each entry after it.
/// - Mail enters the context where the pump delivered it: the `.prompt`
///   entry of a submission holds one ``MailRecord/mailDelivered(_:)`` record
///   for each mail that the submission delivered, in take order, and the
///   text of that entry is ``promptText(delivering:followedBy:)`` of that
///   mail. A mail that a failed submission put back in the queue gets a
///   record only in the `.prompt` entry of the submission that delivered it
///   at last, so the context holds it one time. When a failed attempt runs
///   again (a rejected tool call or a context overflow), only the `.prompt`
///   entry of the retry records the mail of that attempt.
/// - The other mail records (``TranscriptEvent/Kind/mail`` events) are not
///   rendered.
/// - Model output, tool calls and tool results come after the `.prompt`
///   entry of their submission.
/// - A question that a relay sent up from a child (rule R5) is not
///   rendered. The journal keeps it as a `.toolOutput` entry, and each other
///   run event of that journal is rendered.
///
/// Both functions are pure: the same input gives the same output. The
/// transcript is append-only, so between two submissions the context grows
/// only at its end. The one exception is a compaction, which starts the
/// context again at its compacted value.
enum ContextRenderer {
    /// The text between two blocks of the prompt of one submission: between
    /// two user-type mails, between a user-type mail and the lines of run
    /// mail, and before the text of the session that follows the mail.
    static let blockSeparator = "\n\n"

    /// The text between two lines of run mail in one block.
    static let runLineSeparator = "\n"

    /// The text of the `.prompt` entry of one submission: the render of
    /// `mail` in take order, then `text`.
    ///
    /// Each user-type mail is one block (``Mail/promptText``). Each run of
    /// consecutive run mail is one block, with one line for each event
    /// (``OperationEventSegment/renderedLine(for:)``). `text` is one more
    /// block at the end: the text that the session itself adds, for example
    /// the prompt of a continuation, or the prompt of a submission that only
    /// run mail starts.
    ///
    /// - Parameters:
    ///   - mail: The mail that the submission delivers, in take order.
    ///   - text: The text of the session after the mail, or `nil`.
    /// - Returns: The text of the prompt.
    static func promptText(delivering mail: [Mail], followedBy text: String?) -> String {
        var blocks: [String] = []
        var runLines: [String] = []
        for item in mail {
            guard let userText = item.promptText else {
                runLines += item.runEvent.map { [OperationEventSegment.renderedLine(for: $0)] } ?? []
                continue
            }
            blocks += lineBlock(runLines)
            runLines = []
            blocks.append(userText)
        }
        blocks += lineBlock(runLines)
        blocks += text.map { [$0] } ?? []
        return blocks.joined(separator: blockSeparator)
    }

    /// The block of `lines`, or no block when `lines` is empty.
    ///
    /// - Parameter lines: The lines of consecutive run mail.
    /// - Returns: One block, or none.
    private static func lineBlock(_ lines: [String]) -> [String] {
        lines.isEmpty ? [] : [lines.joined(separator: runLineSeparator)]
    }

    /// The context of one session: the transcript that a backend gets, as
    /// the render of `events`.
    ///
    /// The render starts at the newest compaction checkpoint
    /// (``TranscriptReconstructionView/restore``), rebuilds each entry event
    /// in `seq` order, and applies each cut that a
    /// ``TranscriptEvent/Kind/repeatedPartRemoval`` event records. In each
    /// rebuilt entry it removes the plan of each operation event
    /// (``OperationEventSegment/removingPlans(from:)``) and the mail records
    /// of a `.prompt` entry (``MailRecordSegment/removingRecords(from:)``):
    /// the text of that entry is already the render of its mail, so the
    /// model reads each mail one time, as the live session gave it.
    ///
    /// Last, it removes each question that a relay sent up from a child
    /// (``OperationEventSegment/removingRelayedQuestions(from:)``), rule R5:
    /// a relayed question is not model input. The journal keeps the
    /// question, and each other run event stays in the context. A restore
    /// and a fork both seed from this render, so neither gives the question
    /// to the model.
    ///
    /// - Parameter events: The effective events of the session, in `seq`
    ///   order, with the ``TranscriptEvent/Kind/repeatedPartRemoval`` events.
    ///   Each other router-only event is passed over.
    /// - Returns: The context.
    /// - Throws: ``TranscriptReconstructionError`` for an event that does not
    ///   rebuild.
    static func context(of events: [TranscriptEvent]) throws -> Transcript {
        let entries = try TranscriptTree.entries(
            of: TranscriptTree.reconstructableEvents(events.filter(\.kind.isEntryKind), view: .restore))
        let render = RepeatedPartRemoval.render(of: entries, applying: try TranscriptTree.renderCut(in: events))
        let rendered = render.map { MailRecordSegment.removingRecords(from: OperationEventSegment.removingPlans(from: $0)) }
        return Transcript(entries: OperationEventSegment.removingRelayedQuestions(from: rendered))
    }
}
