import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^0m997jr: the relay of the executor channel of one pass finds the
/// first streamed output of any kind (response text, reasoning text,
/// tool-call arguments) and reports it as the first token of the pass, and
/// it forwards each event unchanged and in order. Task ^kg3yjc9: it also
/// reports the first output event of a pass at once, so a pass that sends
/// only that one event reads as buffered.
@Suite("Pass output relay: the first streamed output of a pass, from the executor channel")
struct PassOutputRelayTests {
    /// The type of the events of a pass.
    typealias Event = LanguageModelExecutorGenerationChannel.Event

    /// The token count each event of these tests reports.
    private static let tokenCount = 1

    /// A response text event.
    private static let responseText = Event.response(action: .appendText("Looking. ", tokenCount: tokenCount))

    /// A reasoning text event.
    private static let reasoningText = Event.reasoning(action: .appendText("Think. ", tokenCount: tokenCount))

    /// A tool-call arguments event.
    private static let toolCallArguments = Event.toolCalls(
        action: .toolCall(id: "call-0", name: "lookup", action: .appendArguments(#"{"value":"#, tokenCount: tokenCount)))

    /// A metadata event, as the MLX executor sends before its prefill.
    private static let metadata = Event.response(action: .updateMetadata(["modelID": "test-model"]))

    /// A usage event, as an executor sends at the end of a pass.
    private static let usage = Event.response(
        action: .updateUsage(
            input: .init(totalTokenCount: 10, cachedTokenCount: 0),
            output: .init(totalTokenCount: 3, reasoningTokenCount: 0)))

    @Test("response text, reasoning text and tool-call arguments are output; metadata and usage are not")
    func classifiesOutputEvents() {
        #expect(PassOutputRelay.isOutput(Self.responseText))
        #expect(PassOutputRelay.isOutput(Self.reasoningText))
        #expect(PassOutputRelay.isOutput(Self.toolCallArguments))
        #expect(!PassOutputRelay.isOutput(Self.metadata))
        #expect(!PassOutputRelay.isOutput(Self.usage))
    }

    /// Runs `events` through the relay of a pass whose observer is
    /// `observer`, and reads the outer channel as the SDK does.
    ///
    /// - Parameters:
    ///   - events: The events the pass sends, in order.
    ///   - observer: The pass observer of the session.
    /// - Returns: How many events the outer channel gave.
    private static func relay(_ events: [Event], reportingTo observer: GenerationPassObserver) async throws -> Int {
        let outer = LanguageModelExecutorGenerationChannel()
        let reader = Task {
            var count = 0
            for try await _ in outer {
                count += 1
                if count == events.count { break }
            }
            return count
        }
        try await PassOutputRelay.relay(into: outer, reportingTo: observer) { channel in
            for event in events {
                await channel.send(event)
            }
        }
        return try await reader.value
    }

    /// The first-output phases of `observer`.
    ///
    /// - Parameter observer: The pass observer.
    /// - Returns: The phases that are first outputs.
    private static func firstOutputs(of observer: GenerationPassObserver) -> [GenerationCallPhase] {
        observer.takePhases().filter {
            if case .firstOutput = $0 { return true }
            return false
        }
    }

    /// Whether `phase` is the first output event of a pass, at any instant.
    ///
    /// - Parameter phase: A phase of the observer.
    /// - Returns: `true` for ``GenerationCallPhase/firstOutputEvent(at:)``.
    private static func isFirstOutputEvent(_ phase: GenerationCallPhase) -> Bool {
        if case .firstOutputEvent = phase { return true }
        return false
    }

    @Test("a pass that streams its tool-call arguments reports one first output, and each event reaches the SDK")
    func streamedArgumentsReportTheFirstOutput() async throws {
        let observer = GenerationPassObserver()
        let events = [Self.metadata, Self.toolCallArguments, Self.toolCallArguments, Self.usage]

        let forwarded = try await Self.relay(events, reportingTo: observer)

        #expect(forwarded == events.count)
        #expect(Self.firstOutputs(of: observer).count == 1)
    }

    @Test("a pass that sends its whole output in one event reports no first output: its split is unknown")
    func oneOutputEventReportsNoFirstOutput() async throws {
        let observer = GenerationPassObserver()
        let events = [Self.metadata, Self.toolCallArguments, Self.usage]

        let forwarded = try await Self.relay(events, reportingTo: observer)

        #expect(forwarded == events.count)
        #expect(Self.firstOutputs(of: observer).isEmpty)
    }

    @Test("a pass that sends its whole output in one event reports that event, so its call reads as buffered")
    func oneOutputEventIsReportedAsTheFirstOutputEvent() async throws {
        let observer = GenerationPassObserver()

        _ = try await Self.relay([Self.metadata, Self.toolCallArguments, Self.usage], reportingTo: observer)

        let phases = observer.takePhases()
        #expect(phases.count == 1)
        #expect(phases.allSatisfy(Self.isFirstOutputEvent))
    }

    @Test("a pass that streams reports its first output event once, before its first output")
    func streamedPassReportsItsFirstOutputEventOnce() async throws {
        let observer = GenerationPassObserver()
        let events = [Self.reasoningText, Self.responseText, Self.responseText, Self.usage]

        _ = try await Self.relay(events, reportingTo: observer)

        let phases = observer.takePhases()
        #expect(phases.first.map(Self.isFirstOutputEvent) == true)
        #expect(phases.filter(Self.isFirstOutputEvent).count == 1)
        #expect(phases.count == 2)
    }

    @Test("a pass that sends no output event reports no output event")
    func passWithoutOutputReportsNoOutputEvent() async throws {
        let observer = GenerationPassObserver()

        _ = try await Self.relay([Self.metadata, Self.usage], reportingTo: observer)

        #expect(observer.takePhases().isEmpty)
    }
}
