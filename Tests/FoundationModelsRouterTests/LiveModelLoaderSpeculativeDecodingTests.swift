import Testing

@testable import FoundationModelsRouter

/// Proves that a ``LiveModelLoader`` gives its speculative decoding switch to
/// the GGUF loader of the Extras `HubModelLoader`. No test loads a model: each
/// reads the options of that loader.
@Suite("Speculative decoding of the live loader")
struct LiveModelLoaderSpeculativeDecodingTests {
    @Test("a live loader lets a GGUF model decode speculatively by default")
    func speculatesByDefault() throws {
        let loader = LiveModelLoader()

        #expect(try loader.requireGGUFModelLoader().options.speculativeDecoding)
    }

    @Test("a live loader made with speculativeDecoding false turns it off for a GGUF model")
    func switchReachesTheGGUFLoader() throws {
        let loader = LiveModelLoader(speculativeDecoding: false)

        #expect(try !loader.requireGGUFModelLoader().options.speculativeDecoding)
    }
}
