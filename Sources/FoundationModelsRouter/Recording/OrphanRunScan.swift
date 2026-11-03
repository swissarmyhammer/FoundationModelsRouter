import Foundation
import FoundationModelsExtras

/// The identity of one journaled operation run: the tool's name plus its
/// tool-assigned `correlationID`. A correlation id is unique only within one
/// tool.
///
/// For a background run, the `correlationID` is the completion token of the
/// run. A host that spawns a sub-agent from a run records that token as the
/// ``SessionRecord/AgentSpawn/parentToolCallId`` of the child.
public struct RunKey: Hashable, Sendable {
    /// The name of the tool, as the journal records it.
    public let tool: String

    /// The `correlationID` that the tool gave to the run.
    public let correlationID: String

    /// Makes a run key.
    ///
    /// - Parameters:
    ///   - tool: The name of the tool.
    ///   - correlationID: The `correlationID` of the run.
    public init(tool: String, correlationID: String) {
        self.tool = tool
        self.correlationID = correlationID
    }
}

/// The status of one journaled run of a recorded session, as
/// ``RouterSessionDirectory/runStatuses(of:)`` reads it.
public enum RunStatus: Sendable, Equatable {
    /// The journal holds a non-terminal event of the run (`.progress`,
    /// `.elicitation` or `.message`) and no `.completed`. The process died
    /// while the run worked. A restore of the session posts a `.lost`
    /// terminal for this run.
    case orphaned

    /// The journal holds a `.completed` event of the run, with this outcome.
    case completed(OperationOutcome)
}

/// Orphan-detection state over a recorded stream: which runs completed,
/// each run's newest non-terminal event, and the order of first
/// non-terminal appearance.
///
/// One scan serves the restore (``lostTerminalEvents()``) and the read-only
/// status of the runs (``statuses``), so the orphan set of a read is the lost
/// set of a restore by construction.
struct OrphanRunScan {
    /// The wire value of the outcome that a `.completed` event with no
    /// outcome gets. The journal writes an outcome for each `.completed`
    /// event, so this value only marks a damaged record.
    static let missingOutcomeValue = "missing"

    /// The outcome of the first `.completed` event of each completed run.
    private var completedOutcomes: [RunKey: OperationOutcome] = [:]

    /// The newest kept non-terminal event of each run.
    private var newestNonTerminalByRun: [RunKey: OperationEvent] = [:]

    /// The runs with a non-terminal event, in order of first appearance.
    private var orphanCandidateOrder: [RunKey] = []

    /// Scans a recorded stream.
    ///
    /// The journaled events are read through
    /// ``TranscriptEvent/operationEvents``, which passes over a stripped or
    /// undecodable segment.
    ///
    /// - Parameter events: A session's effective recorded events, in order.
    init(scanning events: [TranscriptEvent]) {
        for event in events {
            for operationEvent in event.operationEvents {
                observe(operationEvent)
            }
        }
    }

    /// The runs with a non-terminal event and no `.completed` event, in order
    /// of first appearance.
    var orphanedRuns: [RunKey] {
        orphanCandidateOrder.filter { completedOutcomes[$0] == nil }
    }

    /// The status of each run that has a journaled event.
    var statuses: [RunKey: RunStatus] {
        var statuses = completedOutcomes.mapValues(RunStatus.completed)
        for run in orphanedRuns {
            statuses[run] = .orphaned
        }
        return statuses
    }

    /// Applies one journaled event to the scan.
    ///
    /// A question that a relay sent up from a child
    /// (``ElicitationRequest/isRelayed``) is not model input (rule R5), so it
    /// does not take the place of an older event of its run: the detail of a
    /// lost terminal comes from the own events of the run. When a relayed
    /// question is the first event of its run, it makes the run a candidate,
    /// and a later event of the run takes its place.
    ///
    /// - Parameter event: The journaled event.
    private mutating func observe(_ event: OperationEvent) {
        let run = RunKey(tool: event.tool, correlationID: event.correlationID)
        switch event.kind {
        case .completed:
            if completedOutcomes[run] == nil {
                completedOutcomes[run] = event.outcome ?? .other(Self.missingOutcomeValue)
            }
        case .progress, .elicitation, .message:
            if event.elicitation?.isRelayed == true, newestNonTerminalByRun[run] != nil {
                return
            }
            if newestNonTerminalByRun.updateValue(event, forKey: run) == nil {
                orphanCandidateOrder.append(run)
            }
        }
    }

    /// The terminal `.completed` events with outcome ``OperationOutcome/lost``
    /// that a restore manufactures: one for each orphaned run, in order of
    /// first appearance. The `detail` of each is the message of a question
    /// that the run asked itself, or the newest event's `detail`, as the
    /// journal holds it. A relayed question gives no detail (rule R5).
    ///
    /// - Returns: The manufactured terminal events, or empty.
    func lostTerminalEvents() -> [OperationEvent] {
        orphanedRuns.compactMap { run in
            guard let newest = newestNonTerminalByRun[run] else { return nil }
            return OperationEvent(
                tool: run.tool,
                op: newest.op,
                correlationID: run.correlationID,
                kind: .completed,
                detail: Self.lostDetail(of: newest),
                outcome: .lost
            )
        }
    }

    /// The `detail` of the lost terminal of a run whose newest kept event
    /// is `newest`: the message of its question, or its own `detail`.
    ///
    /// The lost terminal goes to the model as run mail. A question that a
    /// relay sent up from a child (``ElicitationRequest/isRelayed``) is not
    /// model input (rule R5), so its message is never the detail. The scan
    /// keeps a relayed question as the newest event only when the run has no
    /// other event, and then the detail is the `detail` of that event.
    ///
    /// - Parameter newest: The newest kept non-terminal event of the run.
    /// - Returns: The detail.
    private static func lostDetail(of newest: OperationEvent) -> String {
        guard let question = newest.elicitation, !question.isRelayed else { return newest.detail }
        return question.message
    }
}
