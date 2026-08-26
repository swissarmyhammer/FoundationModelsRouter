import Foundation

/// The rendered output a background call returns in place of its result:
/// the `pending` discriminator, the run's `completionToken`, and a `next`
/// field that tells the model what to do instead of answering.
///
/// The `completionToken` is the run's key in the session's ``SessionMailbox``
/// and the `correlationID` on every event the run posts. The wrapped tool
/// owns the `next` sentence through
/// ``DetachmentParameterProviding/detachmentCollectInstruction(forCompletionToken:)``;
/// a tool that supplies none gets ``defaultCollectInstruction(forCompletionToken:)``.
/// ``rendered`` is the authoritative wire form.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// Always `true` — the discriminator a reader branches on.
    public let pending: Bool

    /// The run's completion token: a ULID string that is also the run's
    /// event `correlationID`.
    public let completionToken: String

    /// What the model must do instead of answering, as plain prose.
    public let next: String

    /// Creates the envelope for `completionToken` with the default `next` text.
    ///
    /// - Parameter completionToken: The run's completion token.
    public init(completionToken: String) {
        self.init(
            completionToken: completionToken,
            next: Self.defaultCollectInstruction(forCompletionToken: completionToken)
        )
    }

    /// Creates the envelope for `completionToken` with `next` as its sentence.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - next: The collect sentence, as plain prose.
    public init(completionToken: String, next: String) {
        self.pending = true
        self.completionToken = completionToken
        self.next = next
    }

    /// The `next` text an envelope carries when the wrapped tool supplies
    /// none: the run continues in the background, the session reports the
    /// result when the run settles, and the `wait` tool with the same
    /// `completionToken` collects it earlier.
    ///
    /// - Parameter completionToken: The run's completion token.
    /// - Returns: The default `next` text for `completionToken`.
    public static func defaultCollectInstruction(forCompletionToken completionToken: String) -> String {
        "This run continues in the background. Do not answer yet, and never invent or guess its result. "
            + "The session reports the result when the run settles. "
            + "To collect it earlier, call the wait tool with completionToken \"\(completionToken)\"; "
            + "if the run is not finished yet, call wait again with the same completionToken."
    }

    /// The fixed text before the `completionToken` slot in the wire form.
    private static let renderedPrefix = "{\"pending\":true,\"completionToken\":\""

    /// The fixed text between the `completionToken` slot and the `next` body.
    private static let renderedMidfix = "\",\"next\":\""

    /// The fixed text after the `next` body in the wire form.
    private static let renderedSuffix = "\"}"

    /// The first Unicode scalar value that is not a JSON control character.
    private static let firstUnescapedScalarValue: UInt32 = 0x20

    /// Renders the wire form for `completionToken` and `next` — the one
    /// definition ``rendered`` and ``isRendered(text:)`` share.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - next: The collect sentence, as plain prose.
    /// - Returns: The envelope's JSON wire form.
    private static func rendered(forCompletionToken completionToken: String, next: String) -> String {
        renderedPrefix + completionToken + renderedMidfix + jsonStringBody(of: next) + renderedSuffix
    }

    /// The body of the JSON string literal for `text`: `"` and `\` escaped,
    /// control characters as JSON escapes, every other scalar verbatim.
    ///
    /// - Parameter text: The plain text to write as a JSON string body.
    /// - Returns: The escaped body, without the surrounding quotes.
    private static func jsonStringBody(of text: String) -> String {
        var body = ""
        body.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": body += "\\\""
            case "\\": body += "\\\\"
            case "\n": body += "\\n"
            case "\r": body += "\\r"
            case "\t": body += "\\t"
            default:
                if scalar.value < firstUnescapedScalarValue {
                    body += String(format: "\\u%04x", scalar.value)
                } else {
                    body.unicodeScalars.append(scalar)
                }
            }
        }
        return body
    }

    /// The envelope rendered as its JSON wire form.
    public var rendered: String {
        Self.rendered(forCompletionToken: completionToken, next: next)
    }

    /// Whether `text` is exactly a rendered pending envelope: the fixed frame
    /// around a valid ULID token and a `next` field, whatever sentence it
    /// carries. A decorator such as `TokenCappingTool` uses this to pass
    /// control-plane data through untouched.
    ///
    /// - Parameter text: The rendered tool output to test.
    /// - Returns: `true` iff `text` is a rendered pending envelope.
    public static func isRendered(text: String) -> Bool {
        guard text.hasPrefix(renderedPrefix), text.hasSuffix(renderedSuffix) else {
            return false
        }
        let afterPrefix = text.dropFirst(renderedPrefix.count)
        let completionToken = String(afterPrefix.prefix(ULID.stringLength))
        guard
            ULID(completionToken) != nil,
            afterPrefix.dropFirst(ULID.stringLength).hasPrefix(renderedMidfix),
            let decoded = try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
        else {
            return false
        }
        return text == rendered(forCompletionToken: completionToken, next: decoded.next)
    }
}
