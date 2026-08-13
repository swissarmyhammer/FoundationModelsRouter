/// The one home of the rule that pairs a `.toolOutput` transcript entry back
/// to the tool call it answers — shared by the live diff path
/// (`RoutedSessionActor.emitSessionEvents(for:dispatchedToolCallIds:completedToolCallIds:onEvent:)`)
/// and the cold seeding path (``SessionProjection/transcriptRows(from:)``), so
/// the two can never drift apart on how a completion finds its call.
enum ToolCallOutputPairing {
    /// The id of the tool call a `.toolOutput` entry answers, drawn from the
    /// call ids the same pairing scope already announced.
    ///
    /// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` and its paired
    /// ``ToolCallStatus/running`` status both carry
    /// ``ToolCallPayload/id`` — the model's own id for the call. A completion a
    /// client cannot map back onto one of those ids is unattributable, and
    /// mapping it is the only thing the id is for.
    ///
    /// Measured against macOS 27 FoundationModels, with two calls in one
    /// `.toolCalls` entry: `Transcript.ToolOutput.id` is the id of the call it
    /// answers (`c0` and `c1`, in request order), so `outputEntryId` normally
    /// already *is* the call id and the first branch below returns it. That
    /// invariant is the SDK's, undocumented and unenforced, and this router
    /// does not rely on it: an entry id that names no announced call would
    /// otherwise be emitted verbatim, leaving a client with a completion it
    /// cannot attribute *and* — because the same id is what the live diff's
    /// closing sweep matches on — the real call reported `.failed` moments
    /// later. Falling back to the oldest call still outstanding is the correct
    /// pairing under the SDK's own ordering, which emits one `.toolOutput` per
    /// call in request order.
    ///
    /// The pairing scope is the caller's: the live path scopes `dispatched`
    /// and `completed` to one turn's diff, and the cold path resets them at
    /// each `.prompt` entry, which is where a turn's diff begins.
    ///
    /// - Parameters:
    ///   - outputEntryId: The `.toolOutput` entry's own id.
    ///   - dispatched: Every call id this scope has announced, in request order.
    ///   - completed: The ids already resolved by an earlier `.toolOutput`
    ///     in this same scope.
    /// - Returns: The announced call id this output completes, or
    ///   `outputEntryId` unchanged when the scope announced no call still
    ///   outstanding — a shape with nothing to correlate to, where inventing a
    ///   pairing would be worse than reporting what the transcript said.
    static func completedToolCallId(
        forOutputEntryId outputEntryId: String,
        dispatched: [String],
        completed: Set<String>
    ) -> String {
        guard !dispatched.contains(outputEntryId) else { return outputEntryId }
        return dispatched.first { !completed.contains($0) } ?? outputEntryId
    }
}
