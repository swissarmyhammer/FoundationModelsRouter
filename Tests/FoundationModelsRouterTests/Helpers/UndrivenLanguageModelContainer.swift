@testable import FoundationModelsRouter

/// A ``PlainTranscriptStubContainer`` for suites that resolve a profile but
/// never drive a model answer. Each session it makes runs over a plain
/// ``StubSessionBackend``.
struct UndrivenLanguageModelContainer: PlainTranscriptStubContainer {
    /// Creates a stub session backend.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        StubSessionBackend()
    }
}
