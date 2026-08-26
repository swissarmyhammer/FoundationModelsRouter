import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the ``PendingRunEnvelope`` wire form: rendering, recognition,
/// the default `next` sentence, and the run-plane detail cap.
@Suite("PendingRunEnvelope: the background handle's wire form")
struct PendingRunEnvelopeTests {
    /// How many freshly generated tokens the round-trip test renders and
    /// recognizes — enough that a token-dependent shape defect cannot hide.
    private static let wireFormTokenSampleCount = 32

    /// Asserts that `text` contains every element of `facts`, each after the
    /// previous one.
    private static func expect(_ text: String, saysInOrder facts: [String]) {
        var searchStart = text.startIndex
        for fact in facts {
            guard let found = text.range(of: fact, range: searchStart..<text.endIndex) else {
                Issue.record("\"\(fact)\" is missing, or out of order, in: \(text)")
                return
            }
            searchStart = found.upperBound
        }
    }

    @Test("every freshly generated token renders to a recognized envelope that decodes back to itself")
    func renderedEnvelopeRoundTripsForFreshTokens() throws {
        for _ in 0..<Self.wireFormTokenSampleCount {
            let completionToken = ULID.generate().ulidString
            let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

            #expect(PendingRunEnvelope.isRendered(text: rendered))
            let decoded = try MountFixtures.decodeEnvelope(rendered)
            #expect(decoded.pending)
            #expect(decoded.completionToken == completionToken)
        }
    }

    /// The text shapes the default sentence must not carry: a `runCode`
    /// snippet, the snippet-level `wait` call, any call syntax, and the
    /// run-plane state names no host reports on the wire.
    private static let forbiddenDefaultCollectInstructionFragments = [
        "runCode",
        "return await wait",
        "wait(",
        "snippet",
        "settled",
        "deadline_elapsed",
    ]

    @Test("the default next sentence says: the run continues in the background, do not answer, the session reports the result when the run settles, and wait with the same completionToken collects it earlier")
    func defaultCollectInstructionTeachesTheCollectStep() throws {
        let completionToken = ULID.generate().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let next = try MountFixtures.decodeEnvelope(rendered).next
        #expect(
            next == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
        )
        Self.expect(
            next,
            saysInOrder: [
                // The run goes on behind the turn.
                "continues in the background",
                // Do not answer, and do not invent the result.
                "not answer",
                "never invent",
                // The session reports the result when the run settles.
                "reports the result",
                "settles",
                // The earlier collect step, carrying the real token.
                "wait tool",
                completionToken,
                // What to do when the collect step comes back empty.
                "wait again",
                "same completionToken",
            ]
        )
        for fragment in Self.forbiddenDefaultCollectInstructionFragments {
            #expect(!next.contains(fragment), "default sentence must not say \(fragment)")
        }
    }

    @Test("the rendered envelope fits the run plane's detail cap, which truncates from the front")
    func renderedEnvelopeFitsTheRunPlaneDetailCap() {
        // `BackgroundTool` carries the rendered envelope as the synthesized
        // progress event's `detail`, and the mailbox keeps a detail's
        // TRAILING characters — so an envelope that outgrew the cap would
        // lose the completionToken the model needs.
        let rendered = PendingRunEnvelope(completionToken: ULID.generate().ulidString).rendered

        #expect(rendered.count <= ToolContext.terminalDetailTailLimit)
    }

    @Test("an envelope is recognized whatever collect sentence it carries: the default, a tool's own, and one that needs JSON escaping")
    func renderedEnvelopeIsRecognizedWithAnyCollectInstruction() throws {
        let completionToken = ULID.generate().ulidString
        let sentences = [
            PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken),
            MountFixtures.CollectSentenceTool.collectInstruction(forCompletionToken: completionToken),
            // Quotes, a backslash, a newline, and a tab all need escaping
            // inside the JSON string the `next` field is.
            "Say \"\(completionToken)\" \\ twice\n\tthen stop.",
        ]

        for next in sentences {
            let rendered = PendingRunEnvelope(completionToken: completionToken, next: next).rendered

            #expect(PendingRunEnvelope.isRendered(text: rendered))
            let decoded = try MountFixtures.decodeEnvelope(rendered)
            #expect(decoded.completionToken == completionToken)
            #expect(decoded.next == next)
        }
    }

    @Test("an envelope with anything added to or removed from it is not recognized")
    func alteredLengthIsRejected() {
        let completionToken = ULID.generate().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let tampered = [
            rendered + " ",
            " " + rendered,
            String(rendered.dropLast()),
            String(rendered.dropFirst()),
            // Both slots shortened to a 25-character stub.
            rendered.replacingOccurrences(
                of: completionToken, with: String(completionToken.dropLast())
            ),
        ]

        for text in tampered {
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }

    @Test("an envelope whose twin slots hold a same-length non-ULID is not recognized")
    func nonULIDTokenSlotsAreRejected() {
        let completionToken = ULID.generate().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let notAToken = String(repeating: "!", count: ULID.stringLength)
        let tampered = rendered.replacingOccurrences(of: completionToken, with: notAToken)

        #expect(tampered.count == rendered.count)
        #expect(!PendingRunEnvelope.isRendered(text: tampered))
    }

    @Test("neither ordinary tool output nor an envelope missing its next instruction is recognized")
    func nonEnvelopeOutputIsRejected() {
        let completionToken = ULID.generate().ulidString

        let notEnvelopes = [
            "",
            "fast: x",
            "{}",
            // The instruction-free wire form this envelope used to render.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\"}",
            // The same facts as JSON, but not this envelope's byte shape.
            "{\"completionToken\":\"\(completionToken)\",\"pending\":true,\"next\":\"wait\"}",
            // The frame, but a `next` field that is not a JSON string.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"next\":\"a\"b\"}",
            // The frame, but the `next` field is not closed.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\",\"next\":\"open}",
        ]

        for text in notEnvelopes {
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }
}
