import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

import FoundationModelsRouter

/// # Canonical usage reference for ``SessionProjection``.
///
/// ``SessionProjection`` is the `@MainActor`/`@Observable` mirror of one
/// ``RoutedSession``. A SwiftUI view holds one projection, gives it the events
/// of each answer, and then reads ``SessionProjection/transcript`` and
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
/// own ``LoadedLLMContainer`` and ``LanguageModelSessionBackend``. Each
/// conformance writes only the members its protocol still requires: the rest
/// come from the `public` defaults the two protocols supply.
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

    /// A scripted stand-in for the model, so the example answer runs with no
    /// network, GPU, or download.
    private enum ProjectionExampleHarness {
        /// The text fragments the scripted model produces, in order.
        ///
        /// More than one fragment, because the projection must merge a run of
        /// ``SessionEvent/textDelta(_:)`` events into one transcript row. A
        /// single fragment would not show that.
        static let answerFragments = ["Refunds post ", "in 5 to 7 days."]

        /// The whole answer, which is what the projection must merge the
        /// fragments back into.
        static var answer: String { answerFragments.joined() }

        /// The input tokens the scripted model meters for each submission.
        static let promptTokens = 128

        /// The output tokens the scripted model meters for each submission.
        static let completionTokens = 32

        /// A session backend that plays a fixed script instead of running a
        /// model: it streams ``answerFragments``, grows a prompt/response
        /// transcript for each submission, and meters a fixed cost for each
        /// submission.
        ///
        /// The script never reads the prompt. It answers every submission the
        /// same way, so nothing here can match an input to an expected output.
        ///
        /// The transcript matters. The router reads the backend transcript
        /// after each submission, and the difference is what produces the
        /// ``SessionEvent/entryRecorded(id:kind:)`` event that gives a
        /// projection row its durable identity.
        ///
        /// `@unchecked Sendable` invariant: `entries` and `usage` change only
        /// inside the methods below, and the owning session calls exactly one
        /// backend method at a time, through its one pump. Each fork hands
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
                recordSubmission(prompt: prompt)
                return answer
            }

            /// Answers exactly as ``respond(to:maxTokens:)`` does, and ignores
            /// `grammar`. A script is not a model, so nothing here can obey a
            /// grammar. The example makes no guided call.
            func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
                recordSubmission(prompt: prompt)
                return answer
            }

            /// Records the submission, then streams one chunk for each
            /// fragment of ``answerFragments``.
            ///
            /// The session reads a streaming submission through
            /// `streamResponseFragments(to:maxTokens:)`, whose `public` default
            /// carries each chunk this stream yields. That is why the harness
            /// writes no fragment method of its own.
            func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
                recordSubmission(prompt: prompt)
                let fragments = answerFragments
                return AsyncThrowingStream { continuation in
                    for fragment in fragments {
                        continuation.yield(fragment)
                    }
                    continuation.finish()
                }
            }

            func makeFork() -> any LanguageModelSessionBackend {
                ScriptedBackend(entries: entries)
            }

            func transcriptEntries() -> [Transcript.Entry] {
                entries
            }

            func usageTokenCounts() -> (input: Int, output: Int)? {
                usage
            }

            /// Appends the prompt and the answer of one submission to the
            /// transcript, and adds the cost of that submission to the running
            /// totals.
            ///
            /// - Parameter prompt: The prompt of the submission.
            private func recordSubmission(prompt: String) {
                entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
                entries.append(
                    .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: answer))])))
                usage = (usage.input + promptTokens, usage.output + completionTokens)
            }
        }

        /// A resident generation model that vends a ``ScriptedBackend`` for
        /// every session.
        ///
        /// The two factories below are the whole conformance. The tool-carrying
        /// variants and `languageModel` come from the `public` defaults
        /// ``LoadedLLMContainer`` supplies, and the default `languageModel`
        /// traps — which is the honest answer for a container that holds a
        /// script instead of a model.
        private struct ScriptedContainer: LoadedLLMContainer {
            /// The scripted counter of this container: one token per `Character`.
            let tokenCounter: any TokenCounter = CharacterTokenCounter()

            func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
                ScriptedBackend()
            }

            func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
                ScriptedBackend(entries: Array(transcript))
            }
        }

        /// Resolves an offline profile and opens one session over the scripted
        /// model.
        ///
        /// - Returns: A session that answers each message with ``answer``.
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

    // MARK: - Bind a projection to an answer

    @Test("Drive a SessionProjection from the event stream of an answer and read the rows it projects")
    @MainActor
    func projectOneStreamedAnswer() async throws {
        let session = try await ProjectionExampleHarness.makeSession()

        // One projection observes the session for its whole life. In SwiftUI
        // this is `@State private var projection = SessionProjection()`, and
        // the view reads it directly, because it is `@Observable`.
        let projection = SessionProjection()
        #expect(projection.phase == .idle)
        #expect(projection.transcript.isEmpty)

        // `apply(eventsFrom:)` drains the event stream of the answer and updates the
        // projection on the main actor as each event arrives. In SwiftUI this
        // one call is the whole body of a `.task` modifier, and the view
        // redraws itself while the call runs.
        try await projection.apply(
            eventsFrom: session.streamEvents(to: "When does my refund post?"))

        // The projection merged the run of text fragments into one row. The
        // model produced two fragments, and the row carries them joined, so
        // this measures the merge rather than the script: a projection that
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

        // The answer ended, so the projection is idle again. A view binds this to
        // show or hide a progress indicator.
        #expect(projection.phase == .idle)

        // The projection also accumulates the metered cost of every answer it
        // observes, which a view shows in a status bar.
        #expect(projection.tokensIn == ProjectionExampleHarness.promptTokens)
        #expect(projection.tokensOut == ProjectionExampleHarness.completionTokens)
    }
}
