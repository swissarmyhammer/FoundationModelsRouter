import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// # Canonical usage reference for ``SessionProjection``.
///
/// ``SessionProjection`` is the `@MainActor`/`@Observable` mirror of one
/// ``RoutedSession``. A SwiftUI view holds one projection, gives it the events
/// of each turn, and then reads ``SessionProjection/transcript`` and
/// ``SessionProjection/phase`` to draw the conversation. The example below is
/// that pattern, in the shape a reader copies into an application:
///
/// ```swift
/// struct ConversationView: View {
///     let session: RoutedSession
///     @State private var projection = SessionProjection()
///     @State private var prompt = ""
///
///     var body: some View {
///         List(projection.transcript) { row in
///             TranscriptRowView(row: row)
///         }
///         .overlay { if projection.phase != .idle { ProgressView() } }
///         .onSubmit {
///             let text = prompt
///             Task { try? await projection.apply(eventsFrom: session.streamEvents(to: text)) }
///         }
///     }
/// }
/// ```
///
/// This file uses a plain `import FoundationModelsRouter`, not
/// `@testable import`. The plain import is the proof: every router symbol this
/// file names is public, so an application outside this package can write the
/// same code. That includes the two conformances in
/// ``ProjectionExampleHarness`` — a plain-import consumer really can supply its
/// own ``LoadedLLMContainer`` and ``LanguageModelSessionBackend``.
///
/// The example runs offline in the normal unit-test target. No network, no GPU,
/// and no download. The only code that departs from an application is
/// ``ProjectionExampleHarness``, which scripts the model. It builds its router
/// from this suite's shared offline fixtures rather than from its own copy of
/// them, because how the router is stubbed is not what this example teaches. An
/// application builds `Router(recordingsDir:)` with a configured
/// `LiveModelLoader` instead. Every line after the
/// `ProjectionExampleHarness.makeSession` call is real usage.
@Suite("Examples: bind a SessionProjection to a session")
struct ProjectionExampleTests {
    // MARK: - Unit-test seam (the ONLY non-production code in this file)

    /// A scripted stand-in for the model, so the example turn runs with no
    /// network, GPU, or download.
    private enum ProjectionExampleHarness {
        /// The text fragments the scripted model produces, in order.
        ///
        /// More than one fragment, because the projection must fold a run of
        /// ``SessionEvent/textDelta(_:)`` events into one transcript row. A
        /// single fragment would not show that.
        static let answerFragments = ["Refunds post ", "in 5 to 7 days."]

        /// The whole answer, which is what the projection must fold the
        /// fragments back into.
        static var answer: String { answerFragments.joined() }

        /// The input tokens the scripted model meters for each turn.
        static let promptTokens = 128

        /// The output tokens the scripted model meters for each turn.
        static let completionTokens = 32

        /// A session backend that plays a fixed script instead of running a
        /// model: it streams ``answerFragments``, grows a prompt/response
        /// transcript for each turn, and meters a fixed cost for each turn.
        ///
        /// The script never reads the prompt. It answers every turn the same
        /// way, so nothing here can match an input to an expected output.
        ///
        /// The transcript matters. The router reads the backend transcript
        /// after each turn, and the difference is what produces the
        /// ``SessionEvent/entryRecorded(id:kind:)`` event that gives a
        /// projection row its durable identity.
        ///
        /// `@unchecked Sendable` invariant: `entries` and `usage` change only
        /// inside the methods below, and the owning session calls exactly one
        /// backend method at a time under its own turn lock. Each fork hands
        /// off to a new instance rather than sharing state, so no two contexts
        /// ever write to one instance.
        private final class ScriptedBackend: LanguageModelSessionBackend, @unchecked Sendable {
            /// The transcript this backend has accumulated, in order.
            private var entries: [Transcript.Entry]

            /// The running token totals this backend reports.
            private var usage: (input: Int, output: Int) = (0, 0)

            /// Creates a scripted backend.
            ///
            /// - Parameter entries: The transcript to start from. Empty for a
            ///   new session, and the parent history for a fork.
            init(entries: [Transcript.Entry] = []) {
                self.entries = entries
            }

            func respond(to prompt: String, maxTokens: Int?) async throws -> String {
                recordTurn(prompt: prompt)
                return answer
            }

            /// Answers exactly as ``respond(to:maxTokens:)`` does, and ignores
            /// `grammar`. A script is not a model, so nothing here can obey a
            /// grammar. The example makes no guided call.
            func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
                recordTurn(prompt: prompt)
                return answer
            }

            func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
                streamTurn(prompt: prompt) { $0 }
            }

            func streamResponseFragments(
                to prompt: String,
                maxTokens: Int?
            ) -> AsyncThrowingStream<ResponseFragment, Error> {
                streamTurn(prompt: prompt) { ResponseFragment(text: $0) }
            }

            func makeFork() -> any LanguageModelSessionBackend {
                ScriptedBackend(entries: entries)
            }

            func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
                makeFork()
            }

            func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
                ScriptedBackend(entries: Array(transcript))
            }

            func transcriptEntries() -> [Transcript.Entry] {
                entries
            }

            func usageTokenCounts() -> (input: Int, output: Int)? {
                usage
            }

            /// Records the turn, then streams one element for each fragment of
            /// ``answerFragments``.
            ///
            /// One implementation behind both streaming entry points, which
            /// differ only in the element they carry.
            ///
            /// - Parameters:
            ///   - prompt: The prompt this turn answers.
            ///   - element: Makes one stream element out of one fragment.
            /// - Returns: The stream of elements, in fragment order.
            private func streamTurn<Element: Sendable>(
                prompt: String,
                element: @escaping @Sendable (String) -> Element
            ) -> AsyncThrowingStream<Element, Error> {
                recordTurn(prompt: prompt)
                let fragments = answerFragments
                return AsyncThrowingStream { continuation in
                    for fragment in fragments {
                        continuation.yield(element(fragment))
                    }
                    continuation.finish()
                }
            }

            /// Appends the prompt and the answer of one turn to the transcript,
            /// and adds that turn's cost to the running totals.
            ///
            /// - Parameter prompt: The prompt this turn answers.
            private func recordTurn(prompt: String) {
                entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
                entries.append(
                    .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: answer))])))
                usage = (usage.input + promptTokens, usage.output + completionTokens)
            }
        }

        /// A resident generation model that vends a ``ScriptedBackend`` for
        /// every session.
        private struct ScriptedContainer: LoadedLLMContainer {
            func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
                ScriptedBackend()
            }

            func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
                makeSession(instructions: instructions)
            }

            func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
                ScriptedBackend(entries: Array(transcript))
            }

            func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
                makeSession(transcript: transcript)
            }

            /// Traps. This container holds a script, not a model, so it has no
            /// `LanguageModel` to give. Asking one for it is a programmer
            /// error, and the example never asks.
            var languageModel: any FoundationModels.LanguageModel {
                preconditionFailure("the scripted example container wraps no LanguageModel")
            }
        }

        /// Resolves an offline profile and opens one session over the scripted
        /// model.
        ///
        /// - Returns: A session that answers each turn with ``answer``.
        /// - Throws: Whatever profile resolution throws.
        static func makeSession() async throws -> RoutedSession {
            let router = RouterTestFixtures.makeRouter(
                cacheDir: RouterTestFixtures.makeTempDir(prefix: "ProjectionExampleTests"),
                loader: StubModelLoader(
                    container: ScriptedContainer(), dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return profile.standard.makeSession(instructions: "You are a terse support agent.")
        }
    }

    // MARK: - Bind a projection to a turn

    @Test("Drive a SessionProjection from a turn's event stream and read the rows it projects")
    @MainActor
    func projectOneStreamedTurn() async throws {
        let session = try await ProjectionExampleHarness.makeSession()

        // One projection observes the session for its whole life. In SwiftUI
        // this is `@State private var projection = SessionProjection()`, and
        // the view reads it directly, because it is `@Observable`.
        let projection = SessionProjection()
        #expect(projection.phase == .idle)
        #expect(projection.transcript.isEmpty)

        // `apply(eventsFrom:)` drains the turn's event stream and updates the
        // projection on the main actor as each event arrives. In SwiftUI this
        // one call is the whole body of a `.task` modifier, and the view
        // redraws itself while the call runs.
        try await projection.apply(
            eventsFrom: session.streamEvents(to: "When does my refund post?"))

        // The projection folded the run of text fragments into one row. The
        // model produced two fragments, and the row carries them joined, so
        // this measures the fold rather than the script: a projection that
        // opened a row for each fragment, or that dropped one, fails here.
        // `transcript` is `Identifiable`, so a view puts it straight into a
        // `List` or a `ForEach`.
        #expect(projection.transcript.count == 1)
        let row = try #require(projection.transcript.first)
        #expect(row.kind == .text(ProjectionExampleHarness.answer))

        // The row adopted the id of the transcript entry the session recorded,
        // so a view can join the row back to the durable transcript.
        #expect(row.sourceEntryId != nil)
        #expect(row.id == row.sourceEntryId)

        // The turn ended, so the projection is idle again. A view binds this to
        // show or hide a progress indicator.
        #expect(projection.phase == .idle)

        // The projection also accumulates the metered cost of every turn it
        // observes, which a view shows in a status bar.
        #expect(projection.tokensIn == ProjectionExampleHarness.promptTokens)
        #expect(projection.tokensOut == ProjectionExampleHarness.completionTokens)
    }
}
