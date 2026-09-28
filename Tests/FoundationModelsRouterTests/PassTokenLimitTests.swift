import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^dzw15st: the backend shows a tool call only after the model ended
/// it, so the repetition watch cannot stop a tool call while the model
/// generates it. ``RepetitionDetection/passTokenLimit`` bounds each
/// generation pass instead.
@Suite("The pass token limit bounds a generation that the repetition watch cannot read")
struct PassTokenLimitTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "PassTokenLimitTests"

    /// A resolved working context larger than the default pass token limit.
    private static let largeContext = 32_768

    /// A resolved working context smaller than the default pass token limit.
    private static let smallContext = 12_288

    /// An explicit ceiling a caller names, larger than the default limit.
    private static let requestedCeiling = 20_000

    /// A pass token limit a host names, smaller than any context here.
    private static let hostLimit = 4_096

    /// The prompt each message of this suite sends.
    private static let prompt = "fix the bug"

    /// The window of the stored detection.
    private static let storedWindow = 512

    /// The minimum line length of the stored detection.
    private static let storedMinimumLineLength = 8

    /// The recoveries per answer of the stored detection.
    private static let storedRecoveries = 1

    @Test("the default is 16,384 tokens, and a detection that names none carries it")
    func defaultIsNamed() {
        #expect(RepetitionDetection.defaultPassTokenLimit == 16_384)
        #expect(RepetitionDetection().passTokenLimit == RepetitionDetection.defaultPassTokenLimit)
    }

    @Test("with no ceiling from the caller, the limit bounds a larger context")
    func limitBoundsLargerContext() {
        let ceiling = ResponseTokenCeiling(
            requested: nil, contextTokens: Self.largeContext, repetitionDetection: RepetitionDetection())
        #expect(ceiling.resolved == RepetitionDetection.defaultPassTokenLimit)
        #expect(ceiling.requested == nil)
    }

    @Test("with no ceiling from the caller, a smaller context stays the ceiling")
    func smallerContextStays() {
        let ceiling = ResponseTokenCeiling(
            requested: nil, contextTokens: Self.smallContext, repetitionDetection: RepetitionDetection())
        #expect(ceiling.resolved == Self.smallContext)
    }

    @Test("with an unknown context, the limit is the ceiling")
    func unknownContextGivesTheLimit() {
        let ceiling = ResponseTokenCeiling(requested: nil, contextTokens: 0, repetitionDetection: RepetitionDetection())
        #expect(ceiling.resolved == RepetitionDetection.defaultPassTokenLimit)
    }

    @Test("a ceiling the caller names wins over the limit")
    func requestedCeilingWins() {
        let ceiling = ResponseTokenCeiling(
            requested: Self.requestedCeiling, contextTokens: Self.largeContext,
            repetitionDetection: RepetitionDetection())
        #expect(ceiling.resolved == Self.requestedCeiling)
    }

    @Test("a detection that is not enabled sets no limit")
    func disabledDetectionSetsNoLimit() {
        let ceiling = ResponseTokenCeiling(
            requested: nil, contextTokens: Self.largeContext, repetitionDetection: RepetitionDetection(isEnabled: false))
        #expect(ceiling.resolved == Self.largeContext)
    }

    @Test("an answer with no ceiling from the caller gives the backend the limit of its session")
    func sessionGivesTheBackendTheLimit() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, context: Self.largeContext,
            repetitionDetection: RepetitionDetection(passTokenLimit: Self.hostLimit),
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let _: String = try await fixture.session.respond(to: Self.prompt)

        #expect(fixture.log.requestedCeilings == [Self.hostLimit])
    }

    @Test("the log line of a stop names the limit")
    func logLineNamesTheLimit() {
        let detection = RepetitionDetection(passTokenLimit: Self.hostLimit)
        #expect(detection.loggedValues.contains("passTokenLimit = \(Self.hostLimit)"))
    }

    @Test("a stored detection with no limit key loads with the default limit")
    func storedDetectionWithoutTheKeyLoads() throws {
        let stored = """
            {"isEnabled": true, "windowTokens": \(Self.storedWindow), \
            "minimumLineLength": \(Self.storedMinimumLineLength), "recoveriesPerTurn": \(Self.storedRecoveries)}
            """
        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: Data(stored.utf8))
        #expect(
            decoded
                == RepetitionDetection(
                    windowTokens: Self.storedWindow, minimumLineLength: Self.storedMinimumLineLength,
                    recoveriesPerAnswer: Self.storedRecoveries, passTokenLimit: RepetitionDetection.defaultPassTokenLimit))
    }

    @Test("a detection with a limit encodes and decodes to the same value")
    func limitRoundTrips() throws {
        let detection = RepetitionDetection(isEnabled: false, passTokenLimit: Self.hostLimit)
        let decoded = try JSONDecoder().decode(RepetitionDetection.self, from: JSONEncoder().encode(detection))
        #expect(decoded == detection)
    }
}
