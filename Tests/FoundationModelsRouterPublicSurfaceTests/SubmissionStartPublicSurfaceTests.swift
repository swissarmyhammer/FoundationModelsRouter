import Testing

import FoundationModelsRouter

/// Holds ``SubmissionStart`` and ``SubmissionEnd`` to the access level a
/// consumer outside this package needs (task ^x7cxsg3; the same need that
/// task ^cbhpdjy found for the record these two replace). A consumer reads
/// ``SubmissionStart/messageIds`` to mark the messages a submission delivers
/// as running, reads ``SubmissionEnd/usage`` to show the cost of the
/// submission, and calls each init to make a record again, for example in a
/// fake event stream of its own tests.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs. A consumer
/// cannot mint a ``SubmissionID``, so the test cannot build a record at run
/// time: the proof is that the calls below compile.
@Suite("SubmissionStart and SubmissionEnd over a plain import")
struct SubmissionStartPublicSurfaceTests {
    /// The ids of the messages that `start` delivers, as a consumer's queue
    /// view reads them to mark those messages as running.
    ///
    /// - Parameter start: The record of the submission that started.
    /// - Returns: The ids of the messages the submission delivers.
    private static func runningMessages(of start: SubmissionStart) -> [MessageID] {
        start.messageIds
    }

    /// Makes `start` again with a different cause, as a consumer's fake event
    /// stream does.
    ///
    /// - Parameters:
    ///   - start: The record of the submission that started.
    ///   - cause: The cause the new record carries.
    /// - Returns: A record of the same submission that carries `cause`.
    private static func restamped(_ start: SubmissionStart, with cause: SubmissionStart.Cause) -> SubmissionStart {
        SubmissionStart(submissionId: start.submissionId, messageIds: start.messageIds, cause: cause)
    }

    /// Makes `end` again with no usage, as a consumer's fake event stream
    /// does for a backend that reports none.
    ///
    /// - Parameter end: The record of the submission that ended.
    /// - Returns: A record of the same submission with no usage.
    private static func withoutUsage(_ end: SubmissionEnd) -> SubmissionEnd {
        SubmissionEnd(submissionId: end.submissionId, usage: nil, finishReason: end.finishReason)
    }

    @Test("a consumer reads a submission start and calls its init over a plain import")
    func aConsumerReadsASubmissionStartAndCallsItsInit() {
        // The reads and the calls type-check over the plain import.
        let read: (SubmissionStart) -> [MessageID] = Self.runningMessages(of:)
        let make: (SubmissionID, [MessageID], SubmissionStart.Cause) -> SubmissionStart =
            SubmissionStart.init(submissionId:messageIds:cause:)
        let restamp: (SubmissionStart, SubmissionStart.Cause) -> SubmissionStart = Self.restamped(_:with:)
        withExtendedLifetime((read, make, restamp)) {}

        // A consumer reads each field, but cannot write it.
        let messageIdsPath: AnyKeyPath = \SubmissionStart.messageIds
        #expect(messageIdsPath is KeyPath<SubmissionStart, [MessageID]>)
        #expect(!(messageIdsPath is WritableKeyPath<SubmissionStart, [MessageID]>))
        let causePath: AnyKeyPath = \SubmissionStart.cause
        #expect(!(causePath is WritableKeyPath<SubmissionStart, SubmissionStart.Cause>))
    }

    @Test("a consumer names each cause of a submission by its stable raw value")
    func aConsumerNamesEachCause() {
        #expect(SubmissionStart.Cause.message.rawValue == "message")
        #expect(SubmissionStart.Cause.mail.rawValue == "mail")
        #expect(SubmissionStart.Cause.continuation.rawValue == "continuation")
    }

    @Test("a consumer reads a submission end and calls its init over a plain import")
    func aConsumerReadsASubmissionEndAndCallsItsInit() {
        let make: (SubmissionID, TokenUsage?, FinishReason) -> SubmissionEnd =
            SubmissionEnd.init(submissionId:usage:finishReason:)
        let strip: (SubmissionEnd) -> SubmissionEnd = Self.withoutUsage(_:)
        withExtendedLifetime((make, strip)) {}

        let usagePath: AnyKeyPath = \SubmissionEnd.usage
        #expect(usagePath is KeyPath<SubmissionEnd, TokenUsage?>)
        #expect(!(usagePath is WritableKeyPath<SubmissionEnd, TokenUsage?>))
        let finishReasonPath: AnyKeyPath = \SubmissionEnd.finishReason
        #expect(!(finishReasonPath is WritableKeyPath<SubmissionEnd, FinishReason>))
    }
}
