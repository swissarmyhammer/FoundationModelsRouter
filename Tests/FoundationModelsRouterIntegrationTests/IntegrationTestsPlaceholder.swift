import Testing

@testable import FoundationModelsRouter

// Placeholder for the gated, real-model integration suite (milestone 7).
// These tests download and run real models and are not part of the default
// fast `swift test` signal; they will be enabled and fleshed out later. The
// target exists from the bootstrap so the build graph is in place.
@Suite("Integration (gated)")
struct IntegrationTestsPlaceholder {
    /// Anchors the placeholder target so it compiles and links against the
    /// router module. Replaced by the real gated suite in milestone 7.
    @Test("integration target compiles", .disabled("real-model suite lands in milestone 7"))
    func integrationTargetCompiles() {
        #expect(FoundationModelsRouter.moduleName == "FoundationModelsRouter")
    }
}
