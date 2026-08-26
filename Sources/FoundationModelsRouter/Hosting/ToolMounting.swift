import FoundationModels

/// The untyped entry point that mounts a tool for a session: it opens the `any Tool` existential and picks the decorator.
public enum ToolMounting {
    /// Wraps `tool` on the session plane of `context`, for a binder outside this package that mounts its own inner calls.
    /// The result is that of ``wrapping(tool:sessionID:mailbox:sink:op:configuration:)``.
    /// - Returns: The mounted tool.
    public static func wrapping(
        tool: any Tool,
        inheriting context: ToolContext,
        sink: any OperationEventSink,
        op: String? = nil,
        configuration: ToolMount
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

    /// Mounts `tool`. A `String`-output tool becomes a ``BackgroundToolRunner`` or a ``RunToCompletionRunner``, per the mount it declares through ``BackgroundTool/mount`` or, when it declares none, per `configuration`.
    /// Any other tool becomes a ``ContextBindingTool``.
    /// - Parameter op: The registration site's `"verb noun"` op, or `nil`.
    /// - Returns: The mounted tool.
    public static func wrapping(
        tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        op: String? = nil,
        configuration: ToolMount
    ) -> any Tool {
        func openArguments<A: ConvertibleFromGeneratedContent & Sendable>(
            _ argumentsType: A.Type, of candidate: any Tool
        ) -> any Tool {
            guard let typed = candidate as? any Tool<A, String> else { return candidate }
            // The tool's own declaration wins over the site's configuration.
            let mount = (typed as? any BackgroundTool)?.mount ?? configuration
            switch mount.mode {
            case .background:
                return BackgroundToolRunner(
                    wrapping: typed, sessionID: sessionID, mailbox: mailbox, sink: sink,
                    op: op, timeout: mount.timeout
                )
            case .runToCompletion:
                return RunToCompletionRunner(
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
