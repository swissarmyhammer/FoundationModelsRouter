import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds ``SubmissionBoundaryTool`` to the public surface (task ^f33q8gw).
///
/// This target imports the module plainly and has no test helpers of the
/// module. The compiler is the first assertion: when the protocol or its
/// requirement loses `public`, the conformer below does not compile. A
/// consumer (for example the MultiTool of FoundationModelsMultitool) conforms
/// from another package in the same way. `SubmissionBoundaryToolPublicSurfaceTests`
/// in the unit target mounts a conformer on a session.
@Suite("SubmissionBoundaryTool conformance over a plain import")
struct SubmissionBoundaryToolConformancePublicSurfaceTests {
    /// The arguments of the two test tools.
    @Generable
    struct ProbeArguments {
        /// The value the model sends.
        let value: String
    }

    /// The model-facing name of the conforming tool.
    private static let conformerName = "conforming-boundary-probe"

    /// A tool that conforms to ``SubmissionBoundaryTool`` from outside the
    /// module. Its hook does nothing: this suite reads the conformance only.
    private struct ConformingTool: SubmissionBoundaryTool {
        let name = SubmissionBoundaryToolConformancePublicSurfaceTests.conformerName
        let description = "test-only tool that conforms to SubmissionBoundaryTool"

        func submissionWillBegin() async {}

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    /// A tool with no ``SubmissionBoundaryTool`` conformance.
    private struct PlainTool: Tool {
        let name = "plain-tool"
        let description = "test-only tool with no submission-boundary conformance"

        func call(arguments: ProbeArguments) async throws -> String {
            arguments.value
        }
    }

    @Test("a cast of an `any Tool` to `any SubmissionBoundaryTool` finds a conformer and misses a plain tool")
    func theCastFindsOnlyAConformer() {
        let tools: [any Tool] = [PlainTool(), ConformingTool()]

        let conformers = tools.compactMap { $0 as? any SubmissionBoundaryTool }

        #expect(conformers.map(\.name) == [Self.conformerName])
    }
}
