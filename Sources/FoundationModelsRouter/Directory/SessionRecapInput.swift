import Foundation

/// The input of the recap call of a session (D206): the previous recap, the
/// user prompts since the last recap, the tool calls of those turns, and the
/// last final message.
///
/// ``prompt(countingWith:)`` makes the prompt of the call
/// (``SessionRecapPrompt``). Each user prompt is cut to
/// ``promptCharacterLimit`` characters, and the last message to
/// ``lastMessageCharacterLimit`` characters. The whole prompt holds at most
/// ``tokenLimit`` tokens of the flash model: when it holds more, the oldest
/// prompts go first, then the oldest tool calls, and last the end of the last
/// message.
struct SessionRecapInput: Sendable, Equatable {
    /// The most characters of one user prompt in the input.
    static let promptCharacterLimit = 500

    /// The most characters of the last final message in the input.
    static let lastMessageCharacterLimit = 2_000

    /// The most tokens of the input.
    static let tokenLimit = 4_000

    /// The most characters of the target of one tool call line.
    static let targetCharacterLimit = 200

    /// The keys of the arguments of a tool call that name its target, in the
    /// order of preference: the first key with a text value gives the target.
    private static let targetKeys = [
        "path", "file_path", "filePath", "file", "paths", "target", "url", "uri", "directory", "command", "query",
        "pattern",
    ]

    /// The text between the items of a list value of a target.
    private static let targetSeparator = ", "

    /// The recap that the record holds, or `nil`.
    var previousRecap: String?

    /// The user prompts since the last recap, the oldest first.
    var prompts: [String]

    /// The tool call lines since the last recap, the oldest first
    /// (``toolCallLine(name:argumentsJSON:)``).
    var toolCalls: [String]

    /// The last final message, or `nil`.
    var lastMessage: String?

    /// The prompt of the recap call, in at most ``tokenLimit`` tokens of
    /// `counter`.
    ///
    /// - Parameter counter: The counter of the flash model.
    /// - Returns: The prompt.
    func prompt(countingWith counter: any TokenCounter) -> String {
        var input = SessionRecapInput(
            previousRecap: previousRecap,
            prompts: prompts.map { String($0.prefix(Self.promptCharacterLimit)) },
            toolCalls: toolCalls,
            lastMessage: lastMessage.map { String($0.prefix(Self.lastMessageCharacterLimit)) })
        while counter.count(input.text) > Self.tokenLimit, !input.prompts.isEmpty {
            input.prompts.removeFirst()
        }
        while counter.count(input.text) > Self.tokenLimit, !input.toolCalls.isEmpty {
            input.toolCalls.removeFirst()
        }
        input.fitLastMessage(countingWith: counter)
        return input.text
    }

    /// The prompt of this input as it is, with no cut.
    private var text: String {
        SessionRecapPrompt.text(
            previousRecap: previousRecap, prompts: prompts, toolCalls: toolCalls, lastMessage: lastMessage)
    }

    /// Cuts the end of the last message, so the prompt holds at most
    /// ``tokenLimit`` tokens. A prompt that fits keeps its message.
    ///
    /// - Parameter counter: The counter of the flash model.
    private mutating func fitLastMessage(countingWith counter: any TokenCounter) {
        let excess = counter.count(text) - Self.tokenLimit
        guard excess > 0, let message = lastMessage else { return }
        lastMessage = counter.prefix(of: message, tokens: counter.count(message) - excess)
    }

    /// One line of a tool call: the name of the tool, and the target that its
    /// arguments name (a path, a URL, a command or a query), when they name
    /// one.
    ///
    /// - Parameters:
    ///   - name: The name of the tool.
    ///   - argumentsJSON: The arguments of the call, as JSON.
    /// - Returns: The line.
    static func toolCallLine(name: String, argumentsJSON: String) -> String {
        guard let target = target(inArguments: argumentsJSON) else { return name }
        return name + " " + target
    }

    /// The target that the arguments of a tool call name, as one line of at
    /// most ``targetCharacterLimit`` characters.
    ///
    /// - Parameter argumentsJSON: The arguments of the call, as JSON.
    /// - Returns: The target, or `nil` for arguments that are not a JSON
    ///   object or that name no target.
    private static func target(inArguments argumentsJSON: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]
        guard let object, let target = targetKeys.lazy.compactMap({ text(of: object[$0]) }).first else { return nil }
        return String(target.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(targetCharacterLimit))
    }

    /// The text of one argument value: a text, or a list of texts.
    ///
    /// - Parameter value: The value of an argument, or `nil`.
    /// - Returns: The text, or `nil` for a value that holds no text.
    private static func text(of value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.isEmpty ? nil : text
        case let texts as [String]:
            return texts.isEmpty ? nil : texts.joined(separator: targetSeparator)
        default:
            return nil
        }
    }
}
