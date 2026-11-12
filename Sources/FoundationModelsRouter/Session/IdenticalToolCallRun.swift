import FoundationModels
import FoundationModelsExtras

/// A tool call that the model made again and again with the same arguments
/// (task ^8eq31j0): its tool and how many identical calls came one after
/// the other.
///
/// A ``RepetitionStop`` carries it when the answer made the same call more
/// than one time in a row, and the recovery prompt names it, so the model
/// knows what it repeated. The run journal records it in ``WatchStop``.
public struct RepeatedToolCall: Sendable, Equatable, Codable {
    /// The name of the tool.
    public let toolName: String

    /// How many identical calls came one after the other, the last call
    /// included.
    public let count: Int

    /// Creates a report of a repeated tool call.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool.
    ///   - count: How many identical calls came one after the other.
    public init(toolName: String, count: Int) {
        self.toolName = toolName
        self.count = count
    }
}

/// One tool call as the count of identical consecutive tool calls compares
/// it (task ^8eq31j0): two calls are identical when they have the same tool
/// name and the same arguments. The recovery budget compares the calls of an
/// answer the same way (task ^0jbps9v).
struct ToolCallIdentity: Sendable, Hashable {
    /// The name of the tool.
    let toolName: String

    /// The JSON text of the arguments of the call.
    let argumentsJSON: String

    /// Creates the identity of one call.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool.
    ///   - argumentsJSON: The JSON text of the arguments of the call.
    init(toolName: String, argumentsJSON: String) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }

    /// Creates the identity of a call from the arguments that the tool body
    /// gets, or `nil` when the arguments do not give their generated content.
    ///
    /// The JSON text of the generated content of the arguments
    /// (``ToolArgumentsContent``) compares the arguments.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool.
    ///   - arguments: The arguments of the call.
    init?(toolName: String, arguments: some Any) {
        guard let content = ToolArgumentsContent.of(arguments) else { return nil }
        self.init(toolName: toolName, argumentsJSON: content.jsonString)
    }

    /// Creates the identity of the call that gave `result`, or `nil` when
    /// the arguments of the call do not give their generated content
    /// (task ^0jbps9v).
    ///
    /// The JSON text of the generated content of the arguments compares the
    /// arguments, as for the arguments that the tool body gets.
    ///
    /// - Parameter result: The tool result that the model reads next.
    init?(result: ToolResultAppend) {
        guard let arguments = result.arguments else { return nil }
        self.init(toolName: result.toolName, argumentsJSON: arguments.jsonString)
    }
}

/// The run of identical consecutive tool calls of one answer (task ^8eq31j0).
///
/// The session adds each tool call of the answer before its tool body runs.
/// A call that is identical to the last call adds one to the count. Any other
/// call starts a new run. A call that cannot be compared ends the run. The
/// pump starts a new run for each new answer, and a recovery or a final pass
/// of the same answer keeps the run.
struct IdenticalToolCallRun: Sendable, Equatable {
    /// The last call of the run, or `nil` before a call or after a call that
    /// cannot be compared.
    private(set) var call: ToolCallIdentity?

    /// How many identical calls came one after the other, the last call
    /// included.
    private(set) var count = 0

    /// Adds the next tool call of the answer to the run.
    ///
    /// - Parameter next: The identity of the call, or `nil` when the call
    ///   cannot be compared.
    mutating func add(_ next: ToolCallIdentity?) {
        guard let next else {
            self = Self()
            return
        }
        count = next == call ? count + 1 : 1
        call = next
    }

    /// The repeated tool call of the run, or `nil` when the run holds only
    /// one call or none.
    var repeatedToolCall: RepeatedToolCall? {
        guard let call, count > 1 else { return nil }
        return RepeatedToolCall(toolName: call.toolName, count: count)
    }
}
