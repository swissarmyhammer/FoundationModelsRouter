import FoundationModelsExtras

@testable import FoundationModelsRouter

/// Canned agent plans (`PlanSnapshot`) and the `.progress` events that carry
/// them (task ^mq1js23). A plan goes to the host, and the model must never get
/// it. Thus each plan entry has a text that no `detail` of these fixtures
/// holds: a test finds a leak of the plan when that text is in model input.
enum PlanFixtures {
    /// The tool name of each event. Code mode posts the events of its nested
    /// `tools.*` calls under this name.
    static let tool = "runCode"

    /// The op of each event.
    static let op = "run code"

    /// The correlation id of each event: the completion token of one run.
    static let correlationID = "01AN4Z07BY79KA1307SR9X4MV3"

    /// The id of the plan of each fixture.
    static let planID = "plan-1"

    /// The text of the first plan entry. No `detail` holds it.
    static let firstEntryText = "read the plan entry that only the host sees"

    /// The text of the second plan entry. No `detail` holds it.
    static let secondEntryText = "write the second plan entry that only the host sees"

    /// The short text line for the model that each plan event carries.
    static let planDetail = "1 of 2 tasks done"

    /// A plan with two entries. The first entry has `status`.
    ///
    /// - Parameters:
    ///   - id: The id of the plan.
    ///   - status: The status of the first entry.
    /// - Returns: The plan.
    static func plan(id: String = planID, firstStatus status: PlanSnapshot.Status = .inProgress) -> PlanSnapshot {
        PlanSnapshot(
            id: id,
            entries: [
                PlanSnapshot.Entry(content: firstEntryText, priority: .high, status: status),
                PlanSnapshot.Entry(content: secondEntryText, priority: .medium, status: .pending),
            ])
    }

    /// A `.progress` event of the fixture run that carries `plan`.
    ///
    /// - Parameters:
    ///   - plan: The plan of the event.
    ///   - detail: The text line for the model.
    /// - Returns: The event.
    static func planProgress(_ plan: PlanSnapshot = plan(), detail: String = planDetail) -> OperationEvent {
        OperationEvent(
            tool: tool, op: op, correlationID: correlationID, kind: .progress, detail: detail, plan: plan)
    }

    /// A `.progress` event of the fixture run that carries text and no plan.
    ///
    /// - Parameter detail: The text line for the model.
    /// - Returns: The event.
    static func textProgress(_ detail: String) -> OperationEvent {
        OperationEvent(tool: tool, op: op, correlationID: correlationID, kind: .progress, detail: detail)
    }

    /// Whether `text` holds the text of a plan entry of these fixtures.
    ///
    /// - Parameter text: The text to examine, for example model input.
    /// - Returns: `true` when `text` holds a plan entry text.
    static func holdsPlanText(_ text: String) -> Bool {
        text.contains(firstEntryText) || text.contains(secondEntryText)
    }
}
