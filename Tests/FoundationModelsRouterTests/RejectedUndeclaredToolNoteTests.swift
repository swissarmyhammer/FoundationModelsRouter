import FoundationModels
@testable import FoundationModelsRouter
import MLXLMCommon
import Testing

/// Task ^eesq24a: the tool error of a call to an undeclared tool names the
/// tools that the model can call.
///
/// Recursive Flint asks for a `shell` tool in nearly every child session of
/// the ACP agent (flint4, 2026-11-14). The parser's detail, "The function was
/// not present in the supplied tool definitions", does not say what to call
/// instead, and a tester called `shell` two times and gave up.
@Suite("The tool error of an undeclared tool names the tools of the session")
struct RejectedUndeclaredToolNoteTests {
    /// The tools of the session in these tests.
    private static let declared = ["skills", "runCode", "searchTools"]

    /// A rejection of a call to `toolName` for `reason`.
    private static func error(_ reason: RejectedToolCall.Reason, toolName: String) -> RejectedToolCallError {
        RejectedToolCallError(
            RejectedToolCall(
                reason: reason, format: .json, toolName: toolName, rawText: "<tool_call>raw</tool_call>",
                detail: "The function was not present in the supplied tool definitions."))
    }

    @Test("a call to an undeclared tool names each declared tool and says that the called tool does not exist")
    func undeclaredToolNamesTheDeclaredTools() throws {
        let retry = try #require(
            RejectedToolCallRetry(error: Self.error(.undeclaredTool, toolName: "shell"), declaredToolNames: Self.declared))

        let note = retry.prompt(retrying: nil)

        #expect(note.contains(#"There is no tool "shell""#))
        for name in Self.declared {
            #expect(note.contains("\"\(name)\""))
        }
        #expect(note.contains(RejectedToolCall.Reason.undeclaredTool.rawValue))
        #expect(!note.contains("<tool_call>raw</tool_call>"))
    }

    @Test("a call that is rejected for another reason names no declared tool")
    func otherReasonNamesNoDeclaredTool() throws {
        let retry = try #require(
            RejectedToolCallRetry(
                error: Self.error(.invalidArguments, toolName: "runCode"), declaredToolNames: Self.declared))

        let note = retry.prompt(retrying: nil)

        #expect(!note.contains("searchTools"))
        #expect(note.contains(RejectedToolCall.Reason.invalidArguments.rawValue))
    }
}
