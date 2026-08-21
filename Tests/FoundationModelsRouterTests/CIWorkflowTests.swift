import Foundation
import Testing

/// Pins `.github/workflows/ci.yml` to the shared CI shape the org test
/// contract asks for: one call to the shared `swift-ci.yaml` workflow, with
/// `integration-package-path` naming the nested `IntegrationTests/` package.
///
/// The shared workflow's unit job then builds the nested package on every
/// run, and its integration job runs `swift test --package-path
/// IntegrationTests` after the unit job, through the shared workflow's own
/// `needs:` edge. So this suite pins the delegation and its one input, not
/// the edge. It also pins that no `integration-gate-env` input appears: the
/// unit/integration split is structural, and no environment variable selects
/// a suite here.
///
/// A later edit that points `uses:` somewhere else, drops
/// `integration-package-path`, or adds an environment-variable gate fails
/// this suite.
@Suite("CI workflow")
struct CIWorkflowTests {
    @Test("ci.yml calls the shared swift-ci.yaml workflow")
    func callsTheSharedWorkflow() throws {
        let callsShared = try Self.workflowContainsLine(
            "uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main"
        )
        #expect(
            callsShared,
            "ci.yml must call swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main."
        )
    }

    @Test("ci.yml points integration-package-path at the nested IntegrationTests package")
    func namesTheNestedIntegrationPackage() throws {
        let namesPackage = try Self.workflowContainsLine(
            "integration-package-path: IntegrationTests"
        )
        #expect(
            namesPackage,
            """
            ci.yml must set integration-package-path: IntegrationTests so the shared workflow \
            builds and runs the nested package, rather than falling back to repo-local jobs.
            """
        )
    }

    @Test("ci.yml passes no integration-gate-env input")
    func passesNoIntegrationGateEnv() throws {
        let gateEnvLines = try Self.workflowLines().filter { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("integration-gate-env:")
        }
        #expect(
            gateEnvLines.isEmpty,
            """
            ci.yml must pass no integration-gate-env input. The unit/integration split is \
            structural (the root package declares no integration target), and no environment \
            variable may select a suite; found: \(gateEnvLines)
            """
        )
    }

    /// Tells whether the workflow holds a line whose trimmed content equals
    /// the expected text.
    ///
    /// - Parameter expected: the line content to search for, without
    ///   indentation.
    /// - Returns: `true` when a line matches.
    /// - Throws: an error when the workflow file cannot be read.
    private static func workflowContainsLine(_ expected: String) throws -> Bool {
        try workflowLines().contains { line in
            line.trimmingCharacters(in: .whitespaces) == expected
        }
    }

    /// Reads `.github/workflows/ci.yml` from the repository root, resolved
    /// relative to this source file's own path (`#filePath` is
    /// `Tests/FoundationModelsRouterTests/CIWorkflowTests.swift`, two
    /// directories below the root). Keep this file directly inside
    /// `Tests/FoundationModelsRouterTests/`, or adjust the step count to match
    /// the new location.
    ///
    /// - Returns: each line of the workflow file.
    /// - Throws: an error when the file cannot be read.
    private static func workflowLines() throws -> [Substring] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FoundationModelsRouterTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repository root
        let workflow = repoRoot
            .appendingPathComponent(".github/workflows/ci.yml")
        let text = try String(contentsOf: workflow, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
