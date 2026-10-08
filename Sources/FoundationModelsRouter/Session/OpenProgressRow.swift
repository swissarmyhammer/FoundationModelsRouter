import FoundationModelsExtras

/// The consecutive progress events of one run that the run journal writes as
/// one merged transcript row (task ^zze1067).
///
/// A tool that streams its output posts one progress event for each chunk. A
/// row for each event makes the transcript grow with the count of events. So
/// the journal writes the first progress event of a run as its own start row,
/// and then collects the next consecutive progress events of the same run
/// here. The row closes only when a different event comes: an event of a
/// different run, an event of a different kind, a progress event that has a
/// plan, the end of the run, or a different transcript entry. No time window
/// and no size limit close it.
///
/// The row keeps each event whole. The `detail` of an event is a payload that
/// the tool owns, so the row does not join the payloads. It writes one
/// ``OperationEventSegment`` for each event, and no output text is lost.
struct OpenProgressRow: Sendable {
    /// The `correlationID` of the run whose progress this row collects.
    let correlationID: String

    /// The name of the tool that posts the events of the run.
    let toolName: String

    /// The collected progress events, in post order. Empty until the second
    /// progress event of the run comes, because the first one is the start
    /// row.
    private(set) var events: [OperationEvent] = []

    /// Opens an empty row for the run that `start` belongs to.
    ///
    /// - Parameter start: The progress event the journal wrote as the start
    ///   row of the run.
    init(after start: OperationEvent) {
        correlationID = start.correlationID
        toolName = start.tool
    }

    /// Whether `event` continues this row: a progress event of the same run
    /// that has no plan.
    ///
    /// A progress event that has a plan (`OperationEvent.plan`) never goes
    /// into the row. The row is only in memory, and a restore must find the
    /// last plan on disk (task ^mq1js23). So the journal writes a plan event
    /// at once, as its own row.
    ///
    /// - Parameter event: The event the journal records next.
    /// - Returns: `true` when `event` goes into this row.
    func accepts(_ event: OperationEvent) -> Bool {
        event.kind == .progress && event.correlationID == correlationID && event.plan == nil
    }

    /// Adds `event` to the end of this row.
    ///
    /// - Parameter event: A progress event that ``accepts(_:)`` admits.
    mutating func append(_ event: OperationEvent) {
        events.append(event)
    }
}
