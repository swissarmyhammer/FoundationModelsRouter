import Foundation
import FoundationModels
import FoundationModelsRouter
import Testing

/// The wall-clock ceiling this suite runs under.
///
/// One minute rather than the shared ``integrationTestBudgetMinutes`` the
/// model-loading suites take: this suite loads no model, touches no GPU, and
/// encodes one small value.
private let toolCallAttachmentSurfaceTimeLimitMinutes = 1

/// The schema name the probe tool attaches under.
private let probeSchemaName = "FileChangeSet"

/// The JSON document the probe tool attaches.
private let probeContentJSON = #"{"changes":[]}"#

/// The arguments the probe tool takes: one string it echoes back.
@Generable
private struct ProbeArguments {
    let note: String
}

/// The reach proof for `ToolContext.attach(_:)` and `ToolCallAttachment`.
///
/// This file imports the Router with a plain `import`, from a package that is
/// not the Router's own. The root test target lives in the Router's package,
/// where a `package` symbol is reachable with a plain `import`, so only this
/// package can prove that a symbol is `public`. The body of ``call(arguments:)``
/// is the proof: the compiler must type-check `ToolContext.current?.attach(_:)`
/// and `ToolCallAttachment.init(schemaName:contentJSON:)` here.
private struct AttachingProbeTool: Tool {
    let name = "attachment_probe"
    let description = "Attaches one record to its call and echoes the note."

    func call(arguments: ProbeArguments) async throws -> String {
        ToolContext.current?.attach(
            ToolCallAttachment(schemaName: probeSchemaName, contentJSON: probeContentJSON)
        )
        return "probe recorded: \(arguments.note)"
    }
}

// MARK: - Suite

/// The public surface a tool reaches when it hands the Router a structured
/// record of what its call did (Ask 4a).
///
/// Not gated: the suite loads no model and touches no GPU, so it needs neither
/// the target-wide permit nor the metallib bootstrap.
@Suite(
    "Ask 4a surface: ToolContext.attach and ToolCallAttachment are public",
    .timeLimit(.minutes(toolCallAttachmentSurfaceTimeLimitMinutes))
)
struct ToolCallAttachmentSurfaceTests {
    @Test("a ToolCallAttachment round-trips through Codable and compares equal")
    func attachmentRoundTripsThroughCodable() throws {
        let attachment = ToolCallAttachment(schemaName: probeSchemaName, contentJSON: probeContentJSON)

        let encoded = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(ToolCallAttachment.self, from: encoded)

        #expect(decoded == attachment)
        #expect(decoded.schemaName == probeSchemaName)
        #expect(decoded.contentJSON == probeContentJSON)
    }

    @Test("a tool that attaches outside any run still returns its output: attach on a nil context is a no-op")
    func attachOutsideAnyRunIsANoOp() async throws {
        // No run binds a context here, so the optional chain in the probe's
        // body skips the attach and the call completes.
        #expect(ToolContext.current == nil)

        let rendered = try await AttachingProbeTool().call(arguments: ProbeArguments(note: "ping"))

        #expect(rendered == "probe recorded: ping")
    }
}
