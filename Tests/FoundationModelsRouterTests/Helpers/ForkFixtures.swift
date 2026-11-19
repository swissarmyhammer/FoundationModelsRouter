import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// A backend that answers as a ``StubSessionBackend`` does, and holds each
/// call whose prompt holds ``heldPrompt`` until the test releases it: a turn
/// that runs while the test forks its session.
///
/// The held call sends ``entered`` when it starts, and then waits for
/// ``release``. Both are real signals, not the clock. Each ``AwaitedEvent``
/// allows one waiter, so the backend holds one call.
final class PromptHoldingBackend: LanguageModelSessionBackend {
    /// Sent when the held call starts.
    let entered = AwaitedEvent()

    /// Sent by the test to let the held call return.
    let release = AwaitedEvent()

    /// The text that marks the prompt of the held call, or `nil` to hold no
    /// call.
    private let heldPrompt: String?

    /// The backend that gives each answer and the transcript.
    private let inner: StubSessionBackend

    /// Makes a backend that holds the calls of `heldPrompt`.
    ///
    /// - Parameters:
    ///   - heldPrompt: The text that marks the prompt of the held call, or
    ///     `nil` to hold no call.
    ///   - instructions: The instructions of the session.
    init(heldPrompt: String?, instructions: String?) {
        self.heldPrompt = heldPrompt
        self.inner = StubSessionBackend(instructions: instructions)
    }

    /// Holds a call of the held prompt until ``release``, then answers as a
    /// ``StubSessionBackend`` does.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the call.
    ///   - maxTokens: The ceiling of the answer.
    /// - Returns: The answer.
    /// - Throws: ``EventNeverArrived`` when the held call is cancelled.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        if let heldPrompt, prompt.contains(heldPrompt) {
            entered.signal()
            try await release.wait()
        }
        return try await inner.respond(to: prompt, maxTokens: maxTokens)
    }

    /// Streams the answer of ``respond(to:maxTokens:)`` as one chunk.
    ///
    /// The stream is pull-based, so no relay task outlives the consumer.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the call.
    ///   - maxTokens: The ceiling of the answer.
    /// - Returns: The stream of the one chunk.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let streamed = FirstCallFlag()
        return AsyncThrowingStream { [streamed] in
            guard streamed.take() else { return nil }
            return try await self.respond(to: prompt, maxTokens: maxTokens)
        }
    }

    /// Answers a guided call as a ``StubSessionBackend`` does, with no hold.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the call.
    ///   - grammar: The grammar of the call.
    ///   - maxTokens: The ceiling of the answer.
    /// - Returns: The answer.
    /// - Throws: What the inner backend throws.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
    }

    /// Forks the inner backend.
    func makeFork() -> any LanguageModelSessionBackend {
        inner.makeFork()
    }

    /// The transcript of the inner backend.
    func transcriptEntries() -> [Transcript.Entry] {
        inner.transcriptEntries()
    }

    /// The usage of the inner backend.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        inner.usageTokenCounts()
    }

    /// The cached input token count of the inner backend.
    func cachedInputTokenCount() -> Int? {
        inner.cachedInputTokenCount()
    }
}

/// A container whose new sessions run on a ``PromptHoldingBackend`` and
/// whose seeded sessions (a fork, a restore) run on a plain
/// ``StubSessionBackend``. It keeps the last holding backend, so a test can
/// release the held call.
final class ForkTestContainer: PlainTranscriptStubContainer, Sendable {
    /// The text that marks the prompt of the held call, or `nil`.
    private let heldPrompt: String?

    /// The last holding backend that the container made.
    private let lastHolding = Mutex<PromptHoldingBackend?>(nil)

    /// Makes a container.
    ///
    /// - Parameter heldPrompt: The text that marks the prompt of the held
    ///   call of each new session, or `nil` to hold no call.
    init(heldPrompt: String?) {
        self.heldPrompt = heldPrompt
    }

    /// The last holding backend that the container made, or `nil`.
    var lastHoldingBackend: PromptHoldingBackend? {
        lastHolding.withLock { $0 }
    }

    /// Makes a holding backend and keeps it.
    ///
    /// - Parameter instructions: The instructions of the session.
    /// - Returns: The new backend.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        let backend = PromptHoldingBackend(heldPrompt: heldPrompt, instructions: instructions)
        lastHolding.withLock { $0 = backend }
        return backend
    }
}

/// A test tool that forks the session of its call at the call
/// (``SessionForkCut/callingToolCall``), as the `fork session` tool of
/// Multitool does (D205). It answers with the id of the fork, and keeps the
/// summary of each fork it made.
final class ForkingTool: Tool, Sendable {
    /// The error of a call that runs outside a tool call of a session.
    struct NoToolContext: Error {}

    /// The model-facing name a scripted call names.
    static let toolName = "fork-here"

    /// The text that starts the output of the tool, before the id of the
    /// fork.
    static let outputPrefix = "forked "

    /// The `Tool` name requirement.
    let name = ForkingTool.toolName

    /// The `Tool` description requirement. The scripted model picks its call
    /// by name and never reads it.
    let description = "test-only tool that forks the session of the call at the call"

    /// The directory each call forks through.
    private let directory: RouterSessionDirectory

    /// The summary of each fork, in call order.
    private let forks = Mutex<[SessionSummary]>([])

    /// Makes a tool that forks through `directory`.
    ///
    /// - Parameter directory: The directory each call forks through.
    init(directory: RouterSessionDirectory) {
        self.directory = directory
    }

    /// The summary of each fork the tool made, in call order.
    var forkSummaries: [SessionSummary] {
        forks.withLock { $0 }
    }

    /// Forks the session of the call at the call.
    ///
    /// - Parameter arguments: The arguments of the call. The tool does not
    ///   read them.
    /// - Returns: ``outputPrefix`` and the id of the fork.
    /// - Throws: ``NoToolContext`` outside a tool call of a session, or the
    ///   error of the fork.
    func call(arguments: AmbientToolArguments) async throws -> String {
        guard let source = ToolContext.current?.sessionID else { throw NoToolContext() }
        let summary = try await directory.fork(
            SessionForkRequest(sourceID: source, cut: .callingToolCall, forker: .session(source)))
        forks.withLock { $0.append(summary) }
        return Self.outputPrefix + summary.id.description
    }
}

/// A test tool that forks the session of its call at a cut that the test
/// arms (D205): a turn cut of a source whose answer runs, made from inside
/// that answer, where the SDK waits in the tool call. A call with no armed
/// cut forks nothing, and an armed cut serves one call. The tool keeps the
/// outcome of that fork. An error of another type than
/// `SessionDirectoryError` fails the call, and then the tool keeps no
/// outcome.
final class TurnCutForkingTool: Tool, Sendable {
    /// The error of a call that runs outside a tool call of a session.
    struct NoToolContext: Error {}

    /// The model-facing name a scripted call names.
    static let toolName = "fork-at-cut"

    /// The output of a call that forked or tried to fork.
    static let forkOutput = "fork tried"

    /// The output of a call with no armed cut.
    static let idleOutput = "no cut"

    /// The `Tool` name requirement.
    let name = TurnCutForkingTool.toolName

    /// The `Tool` description requirement. The scripted model picks its call
    /// by name and never reads it.
    let description = "test-only tool that forks the session of the call at an armed cut"

    /// The directory each fork goes through.
    private let directory: RouterSessionDirectory

    /// The cut of the next call, or `nil` when no cut is armed.
    private let armedCut = Mutex<SessionForkCut?>(nil)

    /// The outcome of the fork of the armed call, or `nil` before that call.
    private let forkOutcome = Mutex<Result<SessionSummary, SessionDirectoryError>?>(nil)

    /// Makes a tool that forks through `directory`.
    ///
    /// - Parameter directory: The directory each fork goes through.
    init(directory: RouterSessionDirectory) {
        self.directory = directory
    }

    /// Arms `cut` for the next call.
    ///
    /// - Parameter cut: The cut of the fork of the next call.
    func arm(_ cut: SessionForkCut) {
        armedCut.withLock { $0 = cut }
    }

    /// The outcome of the fork of the armed call, or `nil` before that call.
    var outcome: Result<SessionSummary, SessionDirectoryError>? {
        forkOutcome.withLock { $0 }
    }

    /// Forks the session of the call at the armed cut, when a cut is armed.
    ///
    /// - Parameter arguments: The arguments of the call. The tool does not
    ///   read them.
    /// - Returns: ``forkOutput``, or ``idleOutput`` with no armed cut.
    /// - Throws: ``NoToolContext`` outside a tool call of a session, or an
    ///   error of the fork that is not a `SessionDirectoryError`.
    func call(arguments: AmbientToolArguments) async throws -> String {
        guard let source = ToolContext.current?.sessionID else { throw NoToolContext() }
        guard let cut = armedCut.withLock({ $0.take() }) else { return Self.idleOutput }
        let request = SessionForkRequest(sourceID: source, cut: cut, forker: .session(source))
        let outcome: Result<SessionSummary, SessionDirectoryError>
        do {
            outcome = .success(try await directory.fork(request))
        } catch let error as SessionDirectoryError {
            outcome = .failure(error)
        }
        forkOutcome.withLock { $0 = outcome }
        return Self.forkOutput
    }
}

/// The one place where the fork suites map a thrown error to a
/// `SessionDirectoryError`.
enum DirectoryErrorCapture {
    /// Gives the error of `body`, or `nil` when it throws none.
    ///
    /// - Parameter body: The work that can throw.
    /// - Returns: The error as a directory error, or `nil` when `body` throws
    ///   no error or an error of another type.
    static func error<Value>(of body: () async throws -> Value) async -> SessionDirectoryError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? SessionDirectoryError
        }
    }
}

/// A router over a durable recordings root and one container, for the
/// suites of ``RouterSessionDirectory/fork(_:)`` (D205).
struct ForkFixture<Container: LoadedLLMContainer> {
    /// The cache and recordings folders of the test.
    let directories: TestDirectories

    /// The router whose sessions the test vends.
    let router: Router

    /// The resolved profile of ``router``.
    let profile: LanguageModelProfile

    /// The container of the sessions.
    let container: Container

    /// The user that forks, archives and sends in the tests.
    static var user: SessionMessageSender { .user(clientID: "fork-test-client") }

    /// The directory under test.
    var directory: RouterSessionDirectory { router.sessionDirectory }

    /// Makes a fixture whose sessions run over `container`. The directory
    /// gets the recording root of the router, as a host gives it, so it
    /// finds a recorded session that is not live.
    ///
    /// - Parameter container: The container of the sessions.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    static func make(over container: Container) async throws -> Self {
        let directories = TestDirectories(prefix: "RouterSessionDirectoryForkTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        return await make(router: router, profile: profile, over: container, in: directories)
    }

    /// A restart of this fixture: a new router with the id of ``router``,
    /// over the same folders and the same container, and so a new session
    /// directory that holds no live session. The sessions of this fixture
    /// are recorded sessions for it.
    ///
    /// - Returns: The restarted fixture. It shares the folders of this
    ///   fixture.
    /// - Throws: What the resolve of the profile throws.
    func restarted() async throws -> Self {
        let restarted = RouterTestFixtures.makeRouter(
            id: router.id, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir,
            recorder: JSONLRecorder(directory: directories.recordingsDir),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await restarted.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return await Self.make(router: restarted, profile: profile, over: container, in: directories)
    }

    /// Makes a fixture over `router`. The directory gets the recording root
    /// of the router, as a host gives it.
    ///
    /// - Parameters:
    ///   - router: The router of the fixture.
    ///   - profile: The resolved profile of `router`.
    ///   - container: The container of the sessions.
    ///   - directories: The folders of the test.
    /// - Returns: The fixture.
    private static func make(
        router: Router, profile: LanguageModelProfile, over container: Container, in directories: TestDirectories
    ) async -> Self {
        let root = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: directories.recordingsDir)
        await router.sessionDirectory.useRecordingRoots { [root] }
        return Self(directories: directories, router: router, profile: profile, container: container)
    }

    /// Vends a source session with `title` and `tools` that answered each
    /// prompt of `prompts`, in order.
    ///
    /// - Parameters:
    ///   - prompts: The prompts of the turns of the source.
    ///   - title: The title of the source.
    ///   - tools: The tools of the source. The default is no tool.
    /// - Returns: The source.
    /// - Throws: What an answer throws.
    func makeSource(
        answering prompts: [String], title: String? = nil, tools: [any Tool] = []
    ) async throws -> any RoutedSession {
        let source = profile.standard.makeSession(configuration: SessionConfiguration(tools: tools, title: title))
        for prompt in prompts {
            _ = try await source.respond(to: prompt)
        }
        return source
    }

    /// Forks `source` at `cut`, and gives the live fork.
    ///
    /// - Parameters:
    ///   - source: The source session.
    ///   - cut: The cut of the fork.
    ///   - firstPrompt: The first prompt of the fork, or `nil`.
    /// - Returns: The live fork.
    /// - Throws: The error of the fork, or the `#require` failure when the
    ///   fork is not live.
    func fork(
        _ source: any RoutedSession, at cut: SessionForkCut, firstPrompt: String? = nil
    ) async throws -> any RoutedSession {
        let summary = try await directory.fork(
            SessionForkRequest(sourceID: source.id, cut: cut, firstPrompt: firstPrompt, forker: Self.user))
        return try #require(directory.session(id: summary.id))
    }

    /// The error of a fork of `sourceID` at `cut`, or `nil` when the fork
    /// throws none.
    ///
    /// - Parameters:
    ///   - sourceID: The id of the source.
    ///   - cut: The cut of the fork.
    /// - Returns: The error as a directory error, or `nil`.
    func forkError(of sourceID: ULID, at cut: SessionForkCut) async -> SessionDirectoryError? {
        await DirectoryErrorCapture.error {
            try await directory.fork(SessionForkRequest(sourceID: sourceID, cut: cut, forker: Self.user))
        }
    }

    /// Closes `sessions` and removes the folders of the test.
    ///
    /// - Parameter sessions: The sessions the test made.
    func end(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
        directories.remove()
    }
}

extension ForkFixture where Container == ForkTestContainer {
    /// Makes a fixture over a ``ForkTestContainer``.
    ///
    /// - Parameter heldPrompt: The text that marks the prompt of the held
    ///   call of each new session, or `nil` (the default) to hold no call.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    static func make(heldPrompt: String? = nil) async throws -> Self {
        try await make(over: ForkTestContainer(heldPrompt: heldPrompt))
    }
}
