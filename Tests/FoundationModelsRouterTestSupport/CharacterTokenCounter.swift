import FoundationModels
import FoundationModelsRouter

/// The ``TokenCounter`` of the scripted backends: one token per `Character`.
///
/// A scripted backend has no tokenizer, so its counter states its own rule.
/// The rule is the simplest one that needs no number: every `Character` of
/// the text the model reads is one token. A transcript counts the content of
/// every entry the model reads again, the way the live counter renders it:
/// the text of the instructions, the prompts and the responses, the name and
/// the arguments of every tool call, and the text and the structure of every
/// tool output. A reasoning entry is not replayed to the model, so it counts
/// nothing.
public struct CharacterTokenCounter: TokenCounter {
    /// Creates the counter.
    public init() {}

    /// The number of `Character`s in `text`.
    public func count(_ text: String) -> Int {
        text.count
    }

    /// The number of `Character`s in the content of every entry of
    /// `transcript` that the model reads.
    public func count(_ transcript: Transcript) throws -> Int {
        transcript.reduce(0) { $0 + Self.content(of: $1).count }
    }

    /// The first `limit` `Character`s of `text`.
    public func prefix(of text: String, tokens limit: Int) -> String {
        guard limit > 0 else { return "" }
        return String(text.prefix(limit))
    }

    /// The text the model reads of `entry`, joined with no separator.
    ///
    /// - Parameter entry: The entry to read.
    /// - Returns: The content, or the empty string for an entry the model
    ///   does not read again.
    public static func content(of entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions(let instructions):
            return text(of: instructions.segments)
        case .prompt(let prompt):
            return text(of: prompt.segments)
        case .response(let response):
            return text(of: response.segments)
        case .toolCalls(let calls):
            return calls.map { $0.toolName + $0.arguments.jsonString }.joined()
        case .toolOutput(let output):
            return toolOutputContent(of: output.segments)
        case .reasoning:
            return ""
        @unknown default:
            return ""
        }
    }

    /// The `.text` content of `segments`, joined with no separator. A
    /// `.structure` segment of an instructions, prompt or response entry is
    /// bookkeeping the model does not read, so it counts nothing.
    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.map { segment -> String in
            if case .text(let text) = segment { return text.content }
            return ""
        }.joined()
    }

    /// The `.text` content and the `.structure` JSON of `segments`, joined
    /// with no separator: the content of a tool output, which the model reads
    /// whole.
    private static func toolOutputContent(of segments: [Transcript.Segment]) -> String {
        segments.map { segment -> String in
            if case .text(let text) = segment { return text.content }
            if case .structure(let structure) = segment { return structure.content.jsonString }
            return ""
        }.joined()
    }
}
