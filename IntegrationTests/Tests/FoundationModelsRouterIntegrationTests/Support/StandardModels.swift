import FoundationModelsRouter

/// The standard models that the matrixed real-model suites run each test on.
///
/// A suite of the matrix takes the model as the argument of each test,
/// `@Test(arguments: StandardModels.all)`, so every claim of the suite holds on
/// every model of the list.
enum StandardModels {
    /// Qwen 3.8 27B, dense, in the `mxfp4` quantization: the product's
    /// standard model.
    static let qwen38: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

    /// Recursive Flint, a 40B mixture of experts with about 2.5B active per
    /// token, at the 8-bit oQ8e quantization. It always reasons, and it calls
    /// tools in the GLM format.
    static let flint: ModelRef = "mlx-community/flint-oQ8e"

    /// Every model of the matrix, in the order the tests run them.
    static let all: [ModelRef] = [qwen38, flint]
}
