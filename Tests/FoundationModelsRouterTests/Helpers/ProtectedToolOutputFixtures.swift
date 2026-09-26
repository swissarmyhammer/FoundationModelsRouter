import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// Shared fixtures for the tool-output protection tests: a host rule that
/// protects a loaded skill, and transcripts that hold one protected and one
/// unprotected tool output, followed by plain answers.
///
/// The rule and the transcript shape follow the host that asked for the
/// protection: a `skills` tool call with the argument `op` equal to
/// `use skill` loads a skill body, and that body must stay in the transcript
/// word for word through every compaction.
enum ProtectedToolOutputFixtures {
    /// The name of the tool whose `use skill` output the rule protects.
    static let skillsToolName = "skills"

    /// The `op` argument value of a call that loads a skill.
    static let useSkillOperation = "use skill"

    /// The `op` argument value of a `skills` call that loads no skill.
    static let listSkillsOperation = "list skills"

    /// The name of the tool whose output the rule never protects.
    static let searchToolName = "search"

    /// How many times the skill and search texts repeat their sentence, so
    /// each output is much larger than a summary of it.
    static let outputRepeatCount = 40

    /// The protected skill body. Distinct from every other fixture text, so a
    /// test can find it word for word.
    static let skillBody = String(
        repeating: "SKILL-BODY: read the card, then write the test first. ", count: outputRepeatCount)

    /// The unprotected search output.
    static let searchOutput = String(
        repeating: "search result content that compaction may elide. ", count: outputRepeatCount)

    /// The output of a `skills` call that lists skills and loads none.
    static let skillListOutput = String(
        repeating: "skill list: tdd, review, commit. ", count: outputRepeatCount)

    /// The id of the call that loads the skill, and of its output entry.
    static let skillCallId = "call-skill"

    /// The id of the search call, and of its output entry.
    static let searchCallId = "call-search"

    /// The id of the call that lists skills, and of its output entry.
    static let listCallId = "call-list"

    /// How many plain answers follow the tool-using answers, so the
    /// tool-using answers are not the newest answers of the transcript.
    static let recentAnswerCount = 4

    /// The index the first plain recent answer takes, above the index of
    /// every tool-using answer so no two fixture entries share an id.
    static let firstRecentAnswerIndex = 10

    /// The arguments of a `skills` call, decoded by the rule.
    private struct SkillsArguments: Decodable {
        /// The operation the call asks for.
        let op: String
    }

    /// The host rule: protect the output of a `skills` call whose `op` is
    /// ``useSkillOperation``, and nothing else.
    static let rule: ToolOutputProtection = { call, _ in
        guard call.toolName == skillsToolName else { return false }
        let arguments = try? JSONDecoder().decode(
            SkillsArguments.self, from: Data(call.arguments.jsonString.utf8))
        return arguments?.op == useSkillOperation
    }

    /// A `skills` call with `op` set to `operation`.
    ///
    /// The arguments hold one key only. A test compares entries it builds
    /// twice, and with two keys in the object, two parses of the same JSON
    /// compared unequal in one measured run out of two.
    ///
    /// - Parameters:
    ///   - id: The call id.
    ///   - operation: The `op` argument value.
    /// - Returns: The call.
    /// - Throws: What `GeneratedContent(json:)` throws.
    static func skillsCall(id: String, operation: String) throws -> Transcript.ToolCall {
        Transcript.ToolCall(
            id: id, toolName: skillsToolName, arguments: try GeneratedContent(json: #"{"op":"\#(operation)"}"#))
    }

    /// A `search` call.
    ///
    /// - Parameter id: The call id.
    /// - Returns: The call.
    /// - Throws: What `GeneratedContent(json:)` throws.
    static func searchCall(id: String) throws -> Transcript.ToolCall {
        Transcript.ToolCall(
            id: id, toolName: searchToolName, arguments: try GeneratedContent(json: #"{"query":"q"}"#))
    }

    /// A `.toolCalls` entry that holds `calls`.
    ///
    /// - Parameters:
    ///   - id: The entry id.
    ///   - calls: The calls, in request order.
    /// - Returns: The entry.
    static func toolCalls(id: String, _ calls: [Transcript.ToolCall]) -> Transcript.Entry {
        .toolCalls(Transcript.ToolCalls(id: id, calls))
    }

    /// A `.toolOutput` entry whose id is the id of the call it answers, the
    /// shape the SDK writes.
    ///
    /// - Parameters:
    ///   - callId: The id of the call the output answers.
    ///   - toolName: The tool that wrote the output.
    ///   - text: The output text.
    /// - Returns: The entry.
    static func toolOutput(callId: String, toolName: String, text: String) -> Transcript.Entry {
        .toolOutput(
            Transcript.ToolOutput(
                id: callId, toolName: toolName,
                segments: [.text(Transcript.TextSegment(id: "\(callId)-text", content: text))]))
    }

    /// A `.prompt` entry.
    ///
    /// - Parameter id: The entry id.
    /// - Returns: The entry.
    static func prompt(id: String) -> Transcript.Entry {
        .prompt(
            Transcript.Prompt(
                id: id, segments: [.text(Transcript.TextSegment(id: "\(id)-text", content: "question \(id)"))]))
    }

    /// A `.response` entry.
    ///
    /// - Parameter id: The entry id.
    /// - Returns: The entry.
    static func response(id: String) -> Transcript.Entry {
        .response(
            Transcript.Response(
                id: id, segments: [.text(Transcript.TextSegment(id: "\(id)-text", content: "answer \(id)"))]))
    }

    /// The `.toolCalls` entry of the answer that loads the skill.
    ///
    /// - Returns: The entry.
    /// - Throws: What ``skillsCall(id:operation:)`` throws.
    static func skillCallsEntry() throws -> Transcript.Entry {
        toolCalls(id: "calls-skill", [try skillsCall(id: skillCallId, operation: useSkillOperation)])
    }

    /// The protected `.toolOutput` entry of the answer that loads the skill.
    static var skillOutputEntry: Transcript.Entry {
        toolOutput(callId: skillCallId, toolName: skillsToolName, text: skillBody)
    }

    /// One answer that loads the skill: a prompt, the `skills` call, the skill
    /// body, and a response.
    ///
    /// - Returns: The entries of the answer.
    /// - Throws: What ``skillsCall(id:operation:)`` throws.
    static func skillAnswer() throws -> [Transcript.Entry] {
        [prompt(id: "prompt-skill"), try skillCallsEntry(), skillOutputEntry, response(id: "response-skill")]
    }

    /// One answer that searches: a prompt, the `search` call, its output, and
    /// a response.
    ///
    /// - Returns: The entries of the answer.
    /// - Throws: What ``searchCall(id:)`` throws.
    static func searchAnswer() throws -> [Transcript.Entry] {
        [
            prompt(id: "prompt-search"),
            toolCalls(id: "calls-search", [try searchCall(id: searchCallId)]),
            toolOutput(callId: searchCallId, toolName: searchToolName, text: searchOutput),
            response(id: "response-search"),
        ]
    }

    /// The plain answers that follow the tool-using answers.
    ///
    /// - Returns: The entries of ``recentAnswerCount`` answers with no tool
    ///   call.
    static func recentAnswers() -> [Transcript.Entry] {
        (firstRecentAnswerIndex..<firstRecentAnswerIndex + recentAnswerCount).flatMap { index in
            [prompt(id: "prompt-\(index)"), response(id: "response-\(index)")]
        }
    }

    /// The header, the skill answer, the search answer, then the plain
    /// answers.
    ///
    /// - Returns: The transcript.
    /// - Throws: What the call builders throw.
    static func transcript() throws -> Transcript {
        Transcript(
            entries: [TranscriptFixtures.makeInstructions()] + (try skillAnswer()) + (try searchAnswer())
                + recentAnswers())
    }

    /// The text of the `.toolOutput` entry with `id`, or `nil` when `entries`
    /// holds no such entry.
    ///
    /// - Parameters:
    ///   - entries: The entries to search.
    ///   - id: The entry id of the tool output.
    /// - Returns: The joined text of the output's segments.
    static func outputText(in entries: [Transcript.Entry], id: String) -> String? {
        entries.lazy.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry, output.id == id else { return nil }
            return Summarization.text(of: output.segments)
        }.first
    }
}
