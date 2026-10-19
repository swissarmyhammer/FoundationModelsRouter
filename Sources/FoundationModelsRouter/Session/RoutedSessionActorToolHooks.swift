import FoundationModels

/// ``RoutedSessionActor``'s tool hooks (task ^8d73hct): the
/// ``ToolCallHooks`` that each model call of the session binds, and the
/// claim of the SDK tool call of each hooked tool body.
extension RoutedSessionActor {
    /// The tool hooks that a model call of this session binds, or `nil` for
    /// a session of a router with no dispatcher.
    ///
    /// - Returns: The hooks of this session, with the claim of
    ///   ``claimHookedToolCall(named:)``.
    func makeToolCallHooks() -> ToolCallHooks? {
        guard let hooks else { return nil }
        return ToolCallHooks(hooks: hooks) { await self.claimHookedToolCall(named: $0) }
    }

    /// Claims the SDK tool call of a hooked tool body that runs now: the
    /// first call of the submission in flight that has the name `toolName`,
    /// no output, and no hook claim yet (``OpenToolCallClaims``).
    ///
    /// The hook layer calls it from inside the tool call. The SDK waits in
    /// the tool call at that time, so the `.toolCalls` entry of the call is
    /// in the entries of the submission, and no pass of the backend writes
    /// the transcript. When one round calls one tool more than one time and
    /// the SDK runs those calls at the same time, two calls can each get the
    /// id of the other call, as for ``ToolCallRunJoin``.
    ///
    /// - Parameter toolName: The name of the tool of the call.
    /// - Returns: The SDK tool call, or `nil` when no open call has the name.
    func claimHookedToolCall(named toolName: String) -> Transcript.ToolCall? {
        toolHookClaims.claim(named: toolName, in: unrecordedTranscriptEntries())
    }
}
