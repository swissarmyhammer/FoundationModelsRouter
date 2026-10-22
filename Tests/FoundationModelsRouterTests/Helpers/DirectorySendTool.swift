import FoundationModels
import FoundationModelsExtras
import Synchronization

@testable import FoundationModelsRouter

/// A test tool that sends a message through a ``RouterSessionDirectory``
/// from inside a turn, as the `sessions` tool of Multitool (MT-2) does
/// (ROUTER-5). Router has no `sessions` tool, so the loop guard suites
/// (`SessionMessageLoopGuardTests`) script a model that calls this one.
///
/// The sender is the session of the turn: the tool reads it from the ambient
/// ``ToolContext`` of the call, so the `send` runs inside the tool call of
/// that session, with the origin of its turn in scope. The text of the
/// message is the `value` argument of the call. The address is the route the
/// test set for the sender (``route(from:to:)``); a sender with no route
/// sends nothing.
///
/// A class, so the test reads back the receipts of the very instance the
/// sessions mounted.
final class DirectorySendTool: Tool, Sendable {
    /// What the tool records.
    private struct State {
        /// The address each sender sends to, by session id.
        var routes: [ULID: SessionAddress] = [:]

        /// The receipts of each send, by sender, in call order.
        var receipts: [ULID: [[SessionSendReceipt]]] = [:]
    }

    /// The error of a call that runs outside a tool call of a session.
    struct NoToolContext: Error {}

    /// The model-facing name a scripted call names.
    static let toolName = "directory-send"

    /// The text the tool answers with when the sender has no route.
    static let noRouteOutput = "no route"

    /// The `Tool` name requirement.
    let name = DirectorySendTool.toolName

    /// The `Tool` description requirement. The scripted model picks its call
    /// by name and never reads it.
    let description = "test-only tool that sends the value as a message through the session directory"

    /// The directory each call sends through.
    private let directory: RouterSessionDirectory

    /// The routes and the receipts, which the tool calls change from the
    /// tasks of the SDK.
    private let state = Mutex(State())

    /// Makes a tool that sends through `directory`.
    ///
    /// - Parameter directory: The directory each call sends through.
    init(directory: RouterSessionDirectory) {
        self.directory = directory
    }

    /// Sets the address that `sender` sends to.
    ///
    /// - Parameters:
    ///   - sender: The session id of the sender.
    ///   - address: The address of each message of `sender`.
    func route(from sender: ULID, to address: SessionAddress) {
        state.withLock { $0.routes[sender] = address }
    }

    /// The receipts of each send of `sender`, in call order.
    ///
    /// - Parameter sender: The session id of the sender.
    /// - Returns: One list of receipts for each send.
    func receipts(of sender: ULID) -> [[SessionSendReceipt]] {
        state.withLock { $0.receipts[sender, default: []] }
    }

    /// Sends the `value` of `arguments` from the session of the call to the
    /// route of that session, and records the receipts.
    ///
    /// - Parameter arguments: The arguments of the call; `value` is the text.
    /// - Returns: The outcome of each receipt, or ``noRouteOutput``.
    /// - Throws: ``NoToolContext`` outside a tool call of a session, or the
    ///   error of the send.
    func call(arguments: AmbientToolArguments) async throws -> String {
        guard let sender = ToolContext.current?.sessionID else { throw NoToolContext() }
        guard let address = state.withLock({ $0.routes[sender] }) else { return Self.noRouteOutput }
        let receipts = try await directory.send(
            OutgoingSessionMessage(from: .session(sender), to: address, text: arguments.value))
        state.withLock { $0.receipts[sender, default: []].append(receipts) }
        return receipts.map(\.outcome.rawValue).joined(separator: " ")
    }
}
