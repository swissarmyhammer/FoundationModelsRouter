import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the run plane's ``RunKind`` vocabulary: the raw value of each
/// kind, what an unknown raw value does, and the cancellation authority a kind
/// carries through a background run's own canceler.
///
/// Everything runs against a bare `SessionMailbox` and the fake background runs
/// of `BackgroundRunFixtures`, so the suite needs no network and no GPU.
@Suite("Run plane: the run kinds and the cancellation authority each one carries")
struct RunPlaneTests {
    // MARK: - rawValue: the wire vocabulary

    @Test(
        arguments: [
            (RunKind.swiftTask, "swiftTask"),
            (RunKind.process, "process"),
        ]
    )
    func rawValueNamesTheKind(kind: RunKind, expected: String) {
        #expect(kind.rawValue == expected)
    }

    @Test func codableRoundTripPreservesEveryKind() throws {
        for kind in [RunKind.swiftTask, .process] {
            let data = try JSONEncoder().encode(kind)

            #expect(try JSONDecoder().decode(RunKind.self, from: data) == kind)
        }
    }

    @Test func decodingAnUnrecognizedRawValueThrowsRatherThanCrashing() {
        // `mcpRequest` is the phase 4 kind, which this enum does not carry yet.
        let data = Data("\"mcpRequest\"".utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RunKind.self, from: data)
        }
    }

    // MARK: - A tracked process run

    @Test("a run tracked as a process is listed under that kind, and cancel() reports its canceler's authoritative .stopped")
    func processRunIsListedAndCancelReportsStopped() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(
            on: mailbox,
            latch: latch,
            kind: .process,
            cancelerOutcome: .stopped
        )

        let runs = await mailbox.backgroundRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.completionToken == token)
        #expect(runs.first?.kind == .process)

        // `killpg(SIGKILL)` is authoritative, so this canceler reports
        // certainty — `.stopped`, never the `.cancelled` a cooperative request
        // reports — and the mailbox passes it through verbatim.
        #expect(await mailbox.cancel(completionToken: token) == .reported(.stopped))

        // Let the killed run's body end, so the test leaves no suspended
        // continuation behind.
        await latch.open()
        _ = await mailbox.wait(completionToken: token, seconds: 5)
    }

    @Test("sweep() invokes a tracked process run's own canceler and posts the .stopped outcome that canceler reports")
    func sweepPostsTheProcessCancelerOutcome() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let counter = CancelCounter()
        let token = await trackFakeRun(
            on: mailbox,
            latch: latch,
            kind: .process,
            detailOnSettle: "exit 137",
            cancelerOutcome: .stopped,
            counter: counter
        )

        let terminals = await mailbox.sweep()

        // The canceler ran once, and its outcome — not a guess of the run
        // plane's own — is what the terminal event carries.
        #expect(await counter.count == 1)
        #expect(terminals.count == 1)
        #expect(terminals.first?.correlationID == token)
        #expect(terminals.first?.kind == .completed)
        #expect(terminals.first?.outcome == .stopped)
        #expect(await mailbox.backgroundRuns().isEmpty)

        await latch.open()
    }
}
