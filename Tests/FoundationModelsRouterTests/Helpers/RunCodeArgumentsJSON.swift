/// The JSON text of the arguments of the `runCode` tool calls that the test
/// models write, so each argument shape has one owner (tasks ^8eq31j0 and
/// ^z9fsh1t).
///
/// Each `code` holds no quote, no backslash and no line feed, so it stands
/// in the JSON text as it is.
enum RunCodeArgumentsJSON {
    /// The arguments of one call that runs `code`: the JSON object
    /// `{"code": "<code>"}`.
    ///
    /// - Parameter code: The code of the call.
    /// - Returns: The JSON text of the arguments.
    static func running(_ code: String) -> String {
        #"{"code": "\#(code)"}"#
    }

    /// The arguments of one call that runs `code` with a nested `options`
    /// object, with the keys in one order at each depth.
    ///
    /// - Parameter code: The code of the call.
    /// - Returns: The JSON text of the arguments.
    static func keysInOneOrder(running code: String) -> String {
        #"{"code": "\#(code)", "options": {"limit": 8, "follow": true}}"#
    }

    /// The same arguments as ``keysInOneOrder(running:)``, with the keys in
    /// the other order at each depth and with no whitespace.
    ///
    /// - Parameter code: The code of the call.
    /// - Returns: The JSON text of the arguments.
    static func keysInOtherOrder(running code: String) -> String {
        #"{"options":{"follow":true,"limit":8},"code":"\#(code)"}"#
    }
}
