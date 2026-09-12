import Foundation

/// The rendered output a background call returns in place of its result:
/// the `pending` discriminator, the run's `completionToken`, and a `next`
/// field that tells the model what to do instead of answering.
///
/// The `completionToken` is the run's key in the session's `SessionMailbox`
/// and the `correlationID` on every event the run posts. The wrapped tool
/// owns the `next` sentence through
/// ``BackgroundTool/collectInstruction(forCompletionToken:)``;
/// a tool that supplies none gets ``defaultCollectInstruction(forCompletionToken:)``.
/// ``rendered`` is the authoritative wire form.
///
/// **One envelope, two conditions.** A background call always answers with
/// this envelope. When the run is still going, `pending` is `true` and the
/// model must collect the result later. When the run settled inside the grace
/// the tool declared through ``BackgroundTool/inlineSettleGrace``, `pending`
/// is `false` and the envelope also carries the run's ``outcome`` and its
/// ``detail``. The model then reads the result in the same tool output, and
/// the `next` sentence tells it not to wait. There is no second shape of
/// output to recognize: only the `pending` field changes what the model does.
public struct PendingRunEnvelope: Codable, Sendable, Equatable {
    /// Whether the run is still going.
    ///
    /// `true` when the model must collect the result later, `false` when
    /// ``detail`` holds it already. It is the discriminator a reader branches
    /// on.
    public let pending: Bool

    /// The run's completion token: a ULID string that is also the run's
    /// event `correlationID`.
    public let completionToken: String

    /// The settled run's outcome, as its wire word, or `nil` while the run is
    /// still going.
    public let outcome: String?

    /// The settled run's result, or `nil` while the run is still going.
    ///
    /// It is the terminal event's `detail`, cut to the same length as the
    /// detail the `wait` tool reports.
    public let detail: String?

    /// What the model must do instead of answering, as plain prose.
    public let next: String

    /// Creates the envelope for a run that is still going, with the default
    /// `next` text.
    ///
    /// - Parameter completionToken: The run's completion token.
    init(completionToken: String) {
        self.init(
            completionToken: completionToken,
            next: Self.defaultCollectInstruction(forCompletionToken: completionToken)
        )
    }

    /// Creates the envelope for a run that is still going, with `next` as its
    /// sentence.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - next: The collect sentence, as plain prose.
    init(completionToken: String, next: String) {
        self.pending = true
        self.completionToken = completionToken
        self.outcome = nil
        self.detail = nil
        self.next = next
    }

    /// Creates the envelope for a run that settled before the call answered.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - outcome: The run's outcome.
    ///   - detail: The run's result.
    ///   - next: The sentence that tells the model to answer from `detail`.
    init(completionToken: String, outcome: String, detail: String, next: String) {
        self.pending = false
        self.completionToken = completionToken
        self.outcome = outcome
        self.detail = detail
        self.next = next
    }

    /// Returns this envelope with `detail` replaced.
    ///
    /// The capping layer uses it to cut a settled envelope's result without
    /// touching the control fields around it.
    ///
    /// - Parameter detail: The result to carry.
    /// - Returns: The same envelope with the new result, or this envelope
    ///   unchanged when it carries no result at all.
    func replacing(detail: String) -> PendingRunEnvelope {
        guard let outcome else { return self }
        return PendingRunEnvelope(
            completionToken: completionToken, outcome: outcome, detail: detail, next: next
        )
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

    /// The `next` text a settled envelope carries when the wrapped tool
    /// supplies none: the result is here, and nothing is left to collect.
    ///
    /// - Parameter completionToken: The run's completion token.
    /// - Returns: The default `next` text for a settled `completionToken`.
    public static func defaultResultInstruction(forCompletionToken completionToken: String) -> String {
        "This run is finished and its result is the detail field above. Answer from that result now. "
            + "Do not call the wait tool for completionToken \"\(completionToken)\", "
            + "and never reply that the result will arrive later."
    }

    /// The fixed text before the `completionToken` slot of a run that is
    /// still going.
    private static let renderedPendingPrefix = "{\"pending\":true,\"completionToken\":\""

    /// The fixed text before the `completionToken` slot of a settled run.
    private static let renderedSettledPrefix = "{\"pending\":false,\"completionToken\":\""

    /// The fixed text that opens the `outcome` field of a settled run.
    private static let renderedOutcomeInfix = "\",\"outcome\":\""

    /// The fixed text that opens the `detail` field of a settled run.
    private static let renderedDetailInfix = "\",\"detail\":\""

    /// The fixed text between the field before it and the `next` body.
    private static let renderedMidfix = "\",\"next\":\""

    /// The fixed text after the `next` body in the wire form.
    private static let renderedSuffix = "\"}"

    /// The first Unicode scalar value that is not a JSON control character.
    private static let firstUnescapedScalarValue: UInt32 = 0x20

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
    ///
    /// The fields are always written in this order: `pending`,
    /// `completionToken`, then `outcome` and `detail` when the run settled,
    /// then `next`. ``decoded(fromRendered:)`` rebuilds the text from the
    /// decoded values and compares it, so this one property fixes the shape
    /// that recognition accepts.
    var rendered: String {
        var text = pending ? Self.renderedPendingPrefix : Self.renderedSettledPrefix
        text += completionToken
        if let outcome {
            text += Self.renderedOutcomeInfix + Self.jsonStringBody(of: outcome)
        }
        if let detail {
            text += Self.renderedDetailInfix + Self.jsonStringBody(of: detail)
        }
        text += Self.renderedMidfix + Self.jsonStringBody(of: next) + Self.renderedSuffix
        return text
    }

    /// Whether `text` is exactly a rendered envelope: the fixed frame around a
    /// valid ULID token, a `next` field, and the result fields of a settled
    /// run when it carries one. A decorator such as `TokenCappingTool` uses
    /// this to tell control-plane data from ordinary tool output.
    ///
    /// - Parameter text: The rendered tool output to test.
    /// - Returns: `true` iff `text` is a rendered envelope.
    public static func isRendered(text: String) -> Bool {
        decoded(fromRendered: text) != nil
    }

    /// The envelope `text` renders, or `nil` when `text` is not one.
    ///
    /// Recognition is exact. The text must start with one of the two fixed
    /// prefixes, carry a valid ULID in the token slot, decode as this type,
    /// and render back to the same bytes. A settled envelope must carry both
    /// result fields, and a pending one neither, so no partly filled envelope
    /// is accepted.
    ///
    /// - Parameter text: The rendered tool output to read.
    /// - Returns: The decoded envelope, or `nil`.
    static func decoded(fromRendered text: String) -> PendingRunEnvelope? {
        let prefixes = [renderedPendingPrefix, renderedSettledPrefix]
        guard
            text.hasSuffix(renderedSuffix),
            let prefix = prefixes.first(where: { text.hasPrefix($0) })
        else {
            return nil
        }
        let afterPrefix = text.dropFirst(prefix.count)
        let completionToken = String(afterPrefix.prefix(ULID.stringLength))
        guard
            ULID(completionToken) != nil,
            let decoded = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
            decoded.completionToken == completionToken,
            decoded.pending == (decoded.detail == nil),
            decoded.pending == (decoded.outcome == nil),
            text == decoded.rendered
        else {
            return nil
        }
        return decoded
    }
}
