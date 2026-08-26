import FoundationModels

/// The untyped entry point that mounts a tool for a session: Router's
/// tool-instancing seams hold plain `[any Tool]` lists, so this is where the
/// existential is opened and the decorator chosen.
///
/// `Session/ToolOutputCapping.swift` extends this namespace with
/// ``sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)``.
public enum ToolDetachment {
    /// Wraps `tool` on the session plane an ambient ``ToolContext`` names —
    /// the entry point for a binder outside this package that mounts its own
    /// inner calls. The decision and every guarantee are those of
    /// ``wrapping(tool:sessionID:mailbox:sink:op:configuration:)``.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - context: The enclosing call's ambient context.
    ///   - sink: The upstream sink the run's events are posted to.
    ///   - op: The registration site's `"verb noun"` op, or `nil`.
    ///   - configuration: The mount, unless `tool` declares its own.
    /// - Returns: The mounted tool.
    public static func wrapping(
        tool: any Tool,
        inheriting context: ToolContext,
        sink: any OperationEventSink,
        op: String? = nil,
        configuration: DetachConfiguration
    ) -> any Tool {
        wrapping(
            tool: tool,
            sessionID: context.sessionID,
            mailbox: context.mailbox,
            sink: sink,
            op: op,
            configuration: configuration
        )
    }

    /// Mounts `tool`: a `String`-output tool becomes a ``BackgroundTool`` or a
    /// ``RunToCompletionTool`` per the mount it declares through
    /// ``DetachmentParameterProviding/detachmentMount`` or, when it declares
    /// none, per `configuration`. Any other tool becomes the binding-only
    /// ``ContextBindingTool``, because the pending envelope replaces output
    /// on the `String` wire alone.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink the run's events are posted to.
    ///   - op: The registration site's `"verb noun"` op, or `nil`.
    ///   - configuration: The mount, unless `tool` declares its own.
    /// - Returns: The mounted tool.
    public static func wrapping(
        tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        op: String? = nil,
        configuration: DetachConfiguration
    ) -> any Tool {
        func openArguments<A: ConvertibleFromGeneratedContent & Sendable>(
            _ argumentsType: A.Type, of candidate: any Tool
        ) -> any Tool {
            guard let typed = candidate as? any Tool<A, String> else { return candidate }
            // The tool's own declaration wins over the site's configuration.
            let mount = (typed as? any DetachmentParameterProviding)?.detachmentMount ?? configuration
            switch mount.mode {
            case .background:
                return BackgroundTool(
                    wrapping: typed, sessionID: sessionID, mailbox: mailbox, sink: sink,
                    op: op, timeout: mount.timeout
                )
            case .runToCompletion:
                return RunToCompletionTool(
                    wrapping: typed, sessionID: sessionID, mailbox: mailbox, sink: sink,
                    op: op, timeout: mount.timeout
                )
            }
        }
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard tool is any Tool<T.Arguments, String> else {
                return ContextBindingTool<T.Arguments, T.Output>(
                    wrapping: tool,
                    sessionID: sessionID,
                    mailbox: mailbox,
                    sink: sink,
                    op: op
                )
            }
            // A type-system bridge: `Tool` conformance already guarantees
            // `Sendable` arguments, and this cast restates that fact where
            // the generic system can see it. The fallback is unreachable.
            let erasedArguments: Any = T.Arguments.self
            guard
                let argumentsType =
                    erasedArguments as? any (ConvertibleFromGeneratedContent & Sendable).Type
            else {
                return tool
            }
            return openArguments(argumentsType, of: tool)
        }
        return open(tool)
    }
}
