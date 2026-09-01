import Testing

import FoundationModelsRouter

/// Pins ``RestoredSession/instructionsDivergencePhrase`` — the exact text a
/// person greps a repository of committed transcripts for.
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: were that constant to lose `public`, this file would stop
/// compiling before a single test ran. That is the assertion that matters,
/// because the reader this phrase serves works from another package, where
/// `@testable` is not available.
///
/// The expected text stands here as a literal rather than as a second read of
/// the same constant. A constant compared with itself passes for every phrase,
/// so only a literal fails when a person edits the phrase.
@Suite("RestoredSession.instructionsDivergencePhrase: the grep target holds its exact text")
struct InstructionsDivergencePhrasePublicSurfaceTests {
    /// The exact text every saved grep of a committed transcript looks for.
    ///
    /// A change to this string is a change to the contract, and it strands
    /// every grep a person already saved.
    private static let savedGrepTarget =
        "restored session instructions differ from the recorded instructions"

    @Test("the published phrase is the exact text a saved grep looks for")
    func publishedPhraseIsTheExactSavedGrepTarget() {
        #expect(RestoredSession.instructionsDivergencePhrase == Self.savedGrepTarget)
    }
}
