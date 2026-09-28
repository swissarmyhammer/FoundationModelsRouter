import Foundation
import FoundationModels
import FoundationModelsRouter
import Operations

/// The shape of the `agents` tool of FoundationModelsAgents (task ^ggpyaem):
/// one `OperationTool` with one background operation, `start agent`, and three
/// synchronous operations, `list agents`, `check agent` and `cancel agent`.
///
/// This file imports the router module and `Operations`, as the
/// FoundationModelsAgents tool files do. The `@Operation` macro writes
/// `ToolMount` into the code it makes, and `start agent` writes it in its
/// mount. The file compiles only when `ToolMount` is not ambiguous between the
/// two modules (task ^cs9w81q).
enum AgentOperationFixtures {
    /// The name of the fused tool.
    static let toolName = "agents"

    /// The name of the agent that each operation of a test acts on.
    static let agentName = "scout"

    /// The context that each operation runs against.
    struct Context: Sendable {
        /// The latch that the body of `start agent` waits on, so a test
        /// decides when the background run ends.
        let startGate: RunLatch
    }

    /// The output of each operation: one line that names what it did.
    struct Output: Encodable, Sendable {
        /// What the operation did.
        let result: String
    }

    /// The JSON output of an operation whose result is `result`, encoded as
    /// `OperationTool` encodes an output.
    ///
    /// - Parameter result: The result line of the operation.
    /// - Returns: The JSON text that the tool returns for that output.
    /// - Throws: What `JSONEncoder` throws.
    static func encodedOutput(_ result: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(Output(result: result)), as: UTF8.self)
    }

    /// The JSON arguments of one call of the tool.
    ///
    /// - Parameters:
    ///   - op: The `"verb noun"` of the called operation.
    ///   - name: The agent name, or `nil` for an operation with no name.
    /// - Returns: The arguments as a JSON object.
    static func arguments(op: String, name: String?) -> String {
        guard let name else { return #"{"op":"\#(op)"}"# }
        return #"{"op":"\#(op)","name":"\#(name)"}"#
    }

    /// Makes the fused tool over the four operations.
    ///
    /// - Parameter startGate: The latch that the body of `start agent` waits
    ///   on.
    /// - Returns: The tool.
    /// - Throws: What `OperationTool.init` throws when the schemas do not
    ///   fuse.
    static func makeTool(startGate: RunLatch) throws -> OperationTool<Context> {
        try OperationTool(
            name: toolName,
            description: "starts, lists, checks and cancels agents",
            context: Context(startGate: startGate),
            operations: [
                AnyOperation(StartAgent.self), AnyOperation(ListAgents.self),
                AnyOperation(CheckAgent.self), AnyOperation(CancelAgent.self),
            ]
        )
    }
}

/// Starts an agent. The call returns a token at once, and the run ends when
/// the start gate of the context opens.
@Generable
@Operation(verb: "start", noun: "agent", description: "Start an agent", mount: ToolMount(mode: .background))
struct StartAgent {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension StartAgent {
    /// Waits for the start gate, then reports the started agent.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The result `"started <name>"`.
    func execute(in context: AgentOperationFixtures.Context) async throws -> AgentOperationFixtures.Output {
        await context.startGate.waitUntilOpen()
        return AgentOperationFixtures.Output(result: "started \(name)")
    }
}

/// Lists the agents. The call answers in band.
@Generable
@Operation(verb: "list", noun: "agents", description: "List the agents")
struct ListAgents {
    /// A name filter, which the fixture does not read.
    @Guide(description: "The agent name filter")
    var filter: String?
}

extension ListAgents {
    /// Reports the one agent of the fixture.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The result `"listed <agent name>"`.
    func execute(in context: AgentOperationFixtures.Context) async throws -> AgentOperationFixtures.Output {
        AgentOperationFixtures.Output(result: "listed \(AgentOperationFixtures.agentName)")
    }
}

/// Checks an agent. The call answers in band.
@Generable
@Operation(verb: "check", noun: "agent", description: "Check an agent")
struct CheckAgent {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension CheckAgent {
    /// Reports the checked agent.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The result `"checked <name>"`.
    func execute(in context: AgentOperationFixtures.Context) async throws -> AgentOperationFixtures.Output {
        AgentOperationFixtures.Output(result: "checked \(name)")
    }
}

/// Cancels an agent. The call answers in band.
@Generable
@Operation(verb: "cancel", noun: "agent", description: "Cancel an agent")
struct CancelAgent {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension CancelAgent {
    /// Reports the cancelled agent.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The result `"cancelled <name>"`.
    func execute(in context: AgentOperationFixtures.Context) async throws -> AgentOperationFixtures.Output {
        AgentOperationFixtures.Output(result: "cancelled \(name)")
    }
}
