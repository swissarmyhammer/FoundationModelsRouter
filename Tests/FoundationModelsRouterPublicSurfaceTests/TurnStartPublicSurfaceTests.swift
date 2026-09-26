import Testing

import FoundationModelsRouter

/// Holds ``TurnStart`` to the access level a consumer outside this package
/// needs (task ^cbhpdjy): a consumer reads ``TurnStart/messageId`` to match a
/// turn to the message it sent, and calls
/// ``TurnStart/init(turnId:messageId:)`` to make the record again, for
/// example in a fake event stream of its own tests.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs. A consumer
/// cannot mint a ``TurnID``, so the test cannot build a record at run time:
/// the proof is that the calls below compile.
@Suite("TurnStart over a plain import")
struct TurnStartPublicSurfaceTests {
    /// The id of the sent message that `start` carries, as a consumer's queue
    /// view reads it to mark that message as running.
    ///
    /// - Parameter start: The record of the turn that began.
    /// - Returns: The id of the first sent message of the turn, or `nil`.
    static func runningMessage(of start: TurnStart) -> MessageID? {
        start.messageId
    }

    /// Makes `start` again with a different message id, as a consumer's
    /// fake event stream does.
    ///
    /// - Parameters:
    ///   - start: The record of the turn that began.
    ///   - message: The message id the new record carries.
    /// - Returns: A record of the same turn that carries `message`.
    static func restamped(_ start: TurnStart, with message: MessageID?) -> TurnStart {
        TurnStart(turnId: start.turnId, messageId: message)
    }

    @Test("a consumer reads messageId and calls init(turnId:messageId:) over a plain import")
    func aConsumerReadsTheMessageIdAndCallsTheInit() {
        // The read and the call type-check over the plain import.
        let read: (TurnStart) -> MessageID? = Self.runningMessage(of:)
        let make: (TurnID, MessageID?) -> TurnStart = TurnStart.init(turnId:messageId:)
        let restamp: (TurnStart, MessageID?) -> TurnStart = Self.restamped(_:with:)
        withExtendedLifetime((read, make, restamp)) {}

        // A consumer reads the id, but cannot write it.
        let messageIdPath: AnyKeyPath = \TurnStart.messageId
        #expect(messageIdPath is KeyPath<TurnStart, MessageID?>)
        #expect(!(messageIdPath is WritableKeyPath<TurnStart, MessageID?>))
    }
}
