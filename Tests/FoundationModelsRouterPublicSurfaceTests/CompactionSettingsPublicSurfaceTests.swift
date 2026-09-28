import Testing

import FoundationModelsRouter

/// Holds ``CompactionSettings`` and ``SessionConfiguration/compaction`` to the
/// access level a consumer outside this package needs (task ^83r6105). A host
/// makes the settings, sets each field, and gives them to a configuration.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("CompactionSettings over a plain import")
struct CompactionSettingsPublicSurfaceTests {
    /// The token limit of the budget the consumer sets.
    private static let budgetLimit = 4096

    /// The prompt the consumer sets.
    private static let prompt = CompactionPrompt(name: "consumer", text: "condense")

    @Test("a consumer makes the settings with the named defaults")
    func aConsumerMakesDefaultSettings() {
        let settings = CompactionSettings()

        #expect(settings.budget == nil)
        #expect(settings.prompt == .default)
        #expect(settings.toolOutputProtection == nil)
    }

    @Test("a consumer sets each field and gives the settings to a configuration")
    func aConsumerSetsEachField() {
        var settings = CompactionSettings()
        settings.budget = TokenBudget(limit: Self.budgetLimit)
        settings.prompt = Self.prompt
        settings.toolOutputProtection = { _, _ in true }

        var configuration = SessionConfiguration(compaction: settings)
        #expect(configuration.compaction.budget == TokenBudget(limit: Self.budgetLimit))
        #expect(configuration.compaction.prompt == Self.prompt)
        #expect(configuration.compaction.toolOutputProtection != nil)

        configuration.compaction = CompactionSettings()
        #expect(configuration.compaction.budget == nil)
    }
}
