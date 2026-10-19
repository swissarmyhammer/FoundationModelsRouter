import FoundationModels
import FoundationModelsExtras

/// Joins the live ``ToolInvocationRecord``s of one session to the SDK tool
/// calls that started their runs (task ^xhmws92).
///
/// One tool run has two ids. The record carries the run's `completionToken`
/// as its ``ToolInvocationRecord/correlationID``. The SDK `.toolCalls` entry
/// carries the `Transcript.ToolCall.id`, which
/// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` reports after the diff of
/// the submission. The rule of FoundationModelsExtras forbids to put one id in
/// the place of the other. This join does not do that: it finds the SDK id for
/// a record, and ``SessionEvent/toolInvocation(_:toolCallID:)`` carries the
/// two ids side by side.
///
/// The join reads the transcript when the open record arrives. The SDK waits
/// in the tool call at that time, and the `.toolCalls` entry that announced
/// the call is already in the transcript. The record names its tool, but not
/// its arguments. So the record joins the first announced call that has the
/// same tool name, no output yet, and no run yet. When one round calls one
/// tool more than one time and the SDK runs those calls at the same time, the
/// open records can arrive in a different order than the calls. Then two runs
/// of that tool can each get the id of the other call.
///
/// ``RoutedSessionActor`` holds one value for the whole life of the session.
struct ToolCallRunJoin {
    /// The SDK tool-call id of each joined run that is still open, keyed by
    /// the run's `completionToken`. The close record of the run takes its
    /// entry out.
    private var toolCallIDsByCorrelationID: [String: String] = [:]

    /// The calls that a run already joined. Each call joins one run only.
    private var claims = OpenToolCallClaims()

    /// The SDK tool-call id of the call that started the run of `record`.
    ///
    /// An open record joins the first call of `entries` that has the tool
    /// name of the record, no `.toolOutput` entry, and no run yet. A close
    /// record gets the id that its open record joined.
    ///
    /// - Parameters:
    ///   - record: The live record that the outbox forwarded.
    ///   - entries: The transcript entries that the submission in flight
    ///     appended. Between two submissions there are none.
    /// - Returns: The SDK id, or `nil` when no call joins the run.
    mutating func toolCallID(for record: ToolInvocationRecord, in entries: [Transcript.Entry]) -> String? {
        guard record.closedAt == nil else {
            return toolCallIDsByCorrelationID.removeValue(forKey: record.correlationID)
        }
        guard let call = claims.claim(named: record.tool, in: entries) else { return nil }
        toolCallIDsByCorrelationID[record.correlationID] = call.id
        return call.id
    }
}

/// The open SDK tool calls that one consumer already claimed, so that each
/// call goes to one claim only.
///
/// A claim takes the first call of the entries that has the tool name, no
/// `.toolOutput` entry, and no claim yet. ``ToolCallRunJoin`` claims a call
/// for each run, and the tool hooks of the session claim a call for each
/// hooked tool call (``RoutedSessionActor/claimHookedToolCall(named:)``).
/// Each consumer holds its own value, because each one claims each call one
/// time.
struct OpenToolCallClaims {
    /// The SDK ids that a claim already took, among the calls that can still
    /// be claimed.
    private var claimedToolCallIDs: Set<String> = []

    /// Claims the first open call of `entries` that has the name `toolName`
    /// and no claim yet.
    ///
    /// The claims of the calls that got an output go first, so the set holds
    /// only calls that are still open.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool of the call.
    ///   - entries: The transcript entries that the submission in flight
    ///     appended.
    /// - Returns: The claimed call, or `nil` when no open call has the name.
    mutating func claim(named toolName: String, in entries: [Transcript.Entry]) -> Transcript.ToolCall? {
        let openCalls = InFlightTranscript.openCalls(in: entries)
        claimedToolCallIDs.formIntersection(openCalls.map(\.id))
        guard
            let call = openCalls.first(where: { call in
                call.toolName == toolName && !claimedToolCallIDs.contains(call.id)
            })
        else { return nil }
        claimedToolCallIDs.insert(call.id)
        return call
    }
}
