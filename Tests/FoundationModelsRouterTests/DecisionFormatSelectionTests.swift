import Foundation
import FoundationModelsDecision
import Testing

@testable import FoundationModelsRouter

/// Tests of ``DecisionFormatSelection``: the prompt format of a decision
/// model comes from its `decider_config.json` file (decision D13).
@Suite("The prompt format of a decision model")
struct DecisionFormatSelectionTests {
    /// The temperature of the fixture file.
    private static let fixtureTemperature = 0.7

    /// A small `decider_config.json` file.
    private static let deciderConfigJSON = """
        {"layout": "plain", "temperature": \(fixtureTemperature), "isolated_levels": true}
        """

    /// Data that is not JSON.
    private static let malformedJSON = "this is not JSON"

    /// The contents of a `decider_config.json` file give the decider format,
    /// with the configuration of the file.
    @Test("a decider_config.json file gives DeciderPromptFormat with its configuration")
    func configurationGivesDeciderFormat() throws {
        let format = try DecisionFormatSelection.format(deciderConfiguration: Data(Self.deciderConfigJSON.utf8))
        #expect((format as? DeciderPromptFormat)?.configuration.temperature == Self.fixtureTemperature)
    }

    /// No `decider_config.json` file gives the generic format.
    @Test("no decider_config.json file gives GenericPromptFormat")
    func noConfigurationGivesGenericFormat() throws {
        let format = try DecisionFormatSelection.format(deciderConfiguration: nil)
        #expect(format is GenericPromptFormat)
    }

    /// A `decider_config.json` file that is not valid JSON throws.
    @Test("a malformed decider_config.json file throws a DecodingError")
    func malformedConfigurationThrows() {
        #expect(throws: DecodingError.self) {
            try DecisionFormatSelection.format(deciderConfiguration: Data(Self.malformedJSON.utf8))
        }
    }
}
