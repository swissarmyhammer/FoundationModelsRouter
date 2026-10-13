import Testing

@testable import FoundationModelsRouter

/// The terminal events of a list of session events, by mail id and by signal
/// id (`mailbox.md`, section 5, problem 5).
///
/// A terminal event ends the mail it names, and no other event of that mail
/// comes after it: ``SessionEvent/answered(_:)`` and
/// ``SessionEvent/answerFailed(_:)`` end each id of their `mailIds`, and
/// ``SessionEvent/cancelled(_:)`` and ``SessionEvent/lost(_:)`` end their one
/// id. Each mail must get exactly one terminal event.
///
/// A signal also ends with exactly one terminal event:
/// ``SessionEvent/signalDone(_:)``, and for a compaction
/// ``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``
/// whose id is the signal id.
///
/// A test gives the ledger the events of a session and the ids of the mail
/// or the signals it sent, and the ledger records an issue for each id that
/// has no terminal event or more than one.
struct TerminalEventLedger {
    /// The ids that each terminal event ends, one array for each terminal
    /// event, in event order. An id can be in more than one array: that is
    /// the fault the ledger finds.
    let endedMailIds: [[MailID]]

    /// The signal id that each terminal event of a signal ends, in its string
    /// form, one element for each terminal event, in event order. The id of a
    /// compaction event is a string, so the ledger keeps the string form of
    /// each signal id. An id can be in the list more than one time: that is
    /// the fault the ledger finds.
    let endedSignalIds: [String]

    /// Makes the ledger of `events`.
    ///
    /// - Parameter events: The events of a session, in order.
    init(events: [SessionEvent]) {
        endedMailIds = events.compactMap(Self.mailIdsEnded(by:))
        endedSignalIds = events.compactMap(Self.signalIdEnded(by:))
    }

    /// Makes the ledger of the events of `outputs`. The origins do not
    /// change the ledger.
    ///
    /// - Parameter outputs: The output of a session, in order.
    init(outputs: [SessionOutput]) {
        self.init(events: outputs.map(\.event))
    }

    /// The ids that `event` ends, or `nil` when `event` is no terminal event
    /// of mail.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: The ids that the event ends, or `nil`.
    static func mailIdsEnded(by event: SessionEvent) -> [MailID]? {
        switch event {
        case .answered(let answer):
            answer.mailIds
        case .answerFailed(let failure):
            failure.mailIds
        case .cancelled(let mailID), .lost(let mailID):
            [mailID]
        default:
            nil
        }
    }

    /// The signal id that `event` ends, in its string form, or `nil` when
    /// `event` is no terminal event of a signal.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: The string form of the signal id, or `nil`.
    static func signalIdEnded(by event: SessionEvent) -> String? {
        switch event {
        case .signalDone(let signalID):
            signalID.description
        case .compaction(let result):
            result.id
        case .compactionFailed(let failure):
            failure.id
        default:
            nil
        }
    }

    /// How many terminal events end the mail `mailID`.
    ///
    /// - Parameter mailID: The id of one mail.
    /// - Returns: The count of the terminal events that name it.
    func terminalCount(of mailID: MailID) -> Int {
        endedMailIds.filter { $0.contains(mailID) }.count
    }

    /// How many terminal events end the signal `signalID`.
    ///
    /// - Parameter signalID: The id of one signal.
    /// - Returns: The count of the terminal events that name it.
    func terminalCount(of signalID: SignalID) -> Int {
        endedSignalIds.filter { $0 == signalID.description }.count
    }

    /// Records an issue for each id of `mailIds` that has no terminal event,
    /// or more than one.
    ///
    /// - Parameters:
    ///   - mailIds: The ids of the mail that the test sent.
    ///   - sourceLocation: The place of the call, for the issue.
    func expectExactlyOneTerminal(
        for mailIds: some Sequence<MailID>, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for mailID in mailIds {
            let count = terminalCount(of: mailID)
            guard count != 1 else { continue }
            Issue.record(
                """
                mail \(mailID) has \(count) terminal events, and it must have exactly one \
                (answered, answerFailed, cancelled or lost). Terminal events by id: \(endedMailIds)
                """,
                sourceLocation: sourceLocation)
        }
    }

    /// Records an issue for each id of `signalIds` that has no terminal
    /// event, or more than one.
    ///
    /// - Parameters:
    ///   - signalIds: The ids of the signals that the test sent.
    ///   - sourceLocation: The place of the call, for the issue.
    func expectExactlyOneTerminal(
        forSignals signalIds: some Sequence<SignalID>, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for signalID in signalIds {
            let count = terminalCount(of: signalID)
            guard count != 1 else { continue }
            Issue.record(
                """
                signal \(signalID) has \(count) terminal events, and it must have exactly one \
                (signalDone, compaction or compactionFailed). Terminal events of signals: \(endedSignalIds)
                """,
                sourceLocation: sourceLocation)
        }
    }
}
