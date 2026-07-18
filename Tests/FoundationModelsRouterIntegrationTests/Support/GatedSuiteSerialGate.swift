@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model suite in this
/// target.
///
/// Each suite here is independently `.serialized` (Swift Testing serializes
/// *within* a `@Suite`), but distinct `@Suite` types still run concurrently
/// with each other by default — the target has five of them
/// (`IntegrationTests`, `RecordingHandleIntegrationTests`,
/// `SessionTreeRestorationIntegrationTests`,
/// `TranscriptReconstructionIntegrationTests`,
/// `LanguageModelSessionBackendIntegrationTests`), and nothing previously
/// stopped them all from resolving/loading real models at the same time.
/// With real ~15-20GB models in the `.standard`/`.flash` slots (replacing the
/// former tiny `SmolLM-135M` placeholder), that concurrency is a real RAM
/// risk. Every gated `@Test` body in this target acquires this single
/// value-1 permit for its duration, making the whole gated tier serial
/// across files, not just within one.
enum GatedSuiteSerialGate {
    static let shared = AsyncSemaphore(value: 1)
}
