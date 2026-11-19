import Foundation
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The observer of the delivered prompts of a session (D206): an answer
/// gives the prompt text of each user-type mail that it delivers to the one
/// observer of the session, so the recap maker of the directory knows the
/// user prompts of the turns since the last recap.
@Suite("RoutedSessionActor: the observer of the delivered prompts")
struct SessionDeliveredPromptTests {
    /// The prompt of the turn of each test.
    private static let prompt = "summarize the build logs"

    /// The prompts that an observer got, in order.
    private final class Recorder: Sendable {
        /// The prompts, behind one lock: the session calls the observer on
        /// its own executor.
        private let prompts = Mutex<[DeliveredPrompt]>([])

        /// The prompts so far.
        var all: [DeliveredPrompt] { prompts.withLock { $0 } }

        /// Appends `delivered`.
        ///
        /// - Parameter delivered: The prompts of one delivery.
        func record(_ delivered: [DeliveredPrompt]) {
            prompts.withLock { $0 += delivered }
        }
    }

    /// Makes a session over a stub backend with an observer of its delivered
    /// prompts.
    ///
    /// - Parameter recorder: The recorder that the observer fills.
    /// - Returns: The fixture of the session.
    /// - Throws: What the resolve of the profile throws.
    private static func makeObservedSession(recordingTo recorder: Recorder) async throws -> StubBackendSessionFixture
    {
        let fixture = try await StubBackendSessionFixture.make(
            tempDirPrefix: "SessionDeliveredPromptTests", tracer: nil, responseText: "done", usageIncrement: nil)
        let actor = try #require(fixture.session as? RoutedSessionActor)
        actor.observeDeliveredPrompts { recorder.record($0) }
        return fixture
    }

    /// The production change that makes this test fail: a session that tells
    /// no observer the text of the prompts it delivers.
    @Test("an answer gives the text of its user prompt to the observer")
    func anAnswerGivesTheTextOfItsPromptToTheObserver() async throws {
        let recorder = Recorder()
        let fixture = try await Self.makeObservedSession(recordingTo: recorder)

        _ = try await fixture.session.respond(to: Self.prompt)

        #expect(recorder.all.map(\.text) == [Self.prompt])
        await fixture.end()
    }

    /// The production change that makes this test fail: a delivered prompt
    /// with no id of its mail, so a prompt that a failed submission gives
    /// back counts two times.
    @Test("each delivered prompt names its mail")
    func eachDeliveredPromptNamesItsMail() async throws {
        let recorder = Recorder()
        let fixture = try await Self.makeObservedSession(recordingTo: recorder)

        let id = try fixture.session.send(Self.prompt)
        _ = try await fixture.session.awaitTerminal(of: id)

        #expect(recorder.all.map(\.mail) == [id])
        await fixture.end()
    }
}
