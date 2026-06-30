import Testing

// The router module under test.
@testable import FoundationModelsRouter

// The MLX products the router builds on. These imports are the real
// assertion: if any product name is wrong or any module fails to build for
// macOS 27, this test target will not compile.
import MLXLMCommon
import MLXLLM
import MLXEmbedders
import MLXHuggingFace
import MLXFoundationModels
import MLXGuidedGeneration

@Suite("Bootstrap")
struct BootstrapTests {
    /// The module and every MLX product it depends on link and import.
    /// Compilation of this file is the substantive check; the assertion just
    /// anchors a running test.
    @Test("module and MLX products import and link")
    func moduleAndMLXProductsImport() {
        #expect(FoundationModelsRouter.moduleName == "FoundationModelsRouter")
    }
}
