import Testing

import FoundationModelsRouter

/// Holds the refusal of a wait that can never end to the access level a
/// consumer outside this package needs (tasks ^1psqdm9 and ^qhgfajc): an
/// in-band tool body that waits for an answer of its own session is refused
/// with ``GenerationQueueError``.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("GenerationQueueError surface over a plain import")
struct GenerationQueuePublicSurfaceTests {
    /// The label a consumer shows for `error`, or `nil` for an error that is
    /// not a refused wait.
    ///
    /// - Parameter error: The error a call threw.
    /// - Returns: The label, which names the model.
    private static func refusalLabel(for error: any Error) -> String? {
        guard case .waitInsideOpenSubmission(let model) = error as? GenerationQueueError else { return nil }
        return "a tool waited inside its submission on \(model.stringValue)"
    }

    @Test("a consumer matches the refusal of a wait inside an open submission, and reads its model")
    func aConsumerMatchesTheRefusedWait() {
        let model: ModelRef = "org/refused"
        let refusal = GenerationQueueError.waitInsideOpenSubmission(model: model)

        #expect(Self.refusalLabel(for: refusal) == "a tool waited inside its submission on org/refused")
        #expect(refusal.errorDescription?.contains(model.stringValue) == true)
    }
}
