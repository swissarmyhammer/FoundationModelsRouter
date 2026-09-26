import FoundationModels
import MLXFoundationModels
import Synchronization

/// The per-session `FoundationModels.LanguageModel` over a wrapped model
/// (`generation-queue.md`, sections 5.3 and 5.6).
///
/// There is one wrapper for each backend a container makes: each session,
/// each fork, and each summarizer backend. Each wrapper has its own
/// ``SessionLanguageModelState``, whose identity is the executor cache key of
/// the wrapper. The wrapper reports the start and the end of each pass to the
/// observer of its session (``GenerationPassObserver``), so the stall watch
/// counts only the time inside a pass. It is also the seam of the per-pass
/// session work that must run on the task of the executor call, such as the
/// prompt-cache scope: the key of the session, or no cache for a summarizer
/// call.
///
/// A wrapper holds no queue and runs each pass directly. The session submits
/// each whole SDK call of its backend to the ``GenerationQueue`` of the model
/// (``LanguageModelSessionBackend/generationQueue``), so the queue item is the
/// submission, and each pass of that submission runs inside it.
///
/// The wrapper keeps the raw model in ``SessionLanguageModelState/wrapped``. A
/// caller that needs the raw model (the `as? MLXLanguageModel` cast of
/// thinking control, the eviction of the loader) reads the raw model it keeps
/// itself, and never casts this wrapper.
struct SessionLanguageModel: LanguageModel, Sendable {
    /// The per-session state of this wrapper: its identity, the raw model,
    /// the pass observer, the prompt-cache scope, and the pass watches.
    let state: SessionLanguageModelState

    /// Makes a wrapper with a new per-session state over `wrapped`.
    ///
    /// - Parameter wrapped: The raw model whose executor runs each pass.
    init(wrapping wrapped: any LanguageModel) {
        state = SessionLanguageModelState(wrapped: wrapped)
    }

    /// Passed through unchanged from the wrapped model.
    var capabilities: LanguageModelCapabilities { state.wrapped.capabilities }

    /// The executor cache key of this wrapper. It compares by the identity of
    /// this wrapper's state.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(state: state)
    }

    /// The executor every `LanguageModelSession` over a
    /// ``SessionLanguageModel`` drives. The SDK caches one executor for each
    /// distinct ``Configuration``, so there is one executor for each wrapper,
    /// and the wrapped executor is built one time for each wrapper.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares by the identity of the
        /// per-session state, and not by the wrapped model: two sessions with
        /// equal keys would share one executor.
        struct Configuration: Sendable, Hashable {
            /// The per-session state of the wrapper.
            let state: SessionLanguageModelState

            /// Identity equality on the per-session state.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same state object.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.state === rhs.state
            }

            /// Hashes by the `ObjectIdentifier` of the per-session state.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(state))
            }
        }

        /// The model type this executor serves.
        typealias Model = SessionLanguageModel

        /// The per-session state of the wrapper.
        private let state: SessionLanguageModelState

        /// The wrapped model's own executor, built one time and reused.
        private let innerRespond: ExecutorPassthrough.Respond

        /// Stores `configuration` and builds the wrapped model's executor one
        /// time.
        ///
        /// - Parameter configuration: The per-session state of the wrapper.
        /// - Throws: What the wrapped executor's initializer throws.
        init(configuration: Configuration) throws {
            state = configuration.state
            innerRespond = try ExecutorPassthrough.make(wrapping: configuration.state.wrapped)
        }

        /// Runs one pass of the wrapped executor under the prompt-cache scope
        /// of its wrapper, and reports its start and its end to the observer
        /// of its session.
        ///
        /// The pass is the executor call of the SDK itself, not a copy: it
        /// calls the wrapped executor with the same `request` and over the
        /// same `channel` that the SDK gave this call, on the task of this
        /// call.
        ///
        /// The pass binds the scope itself, around the call of the wrapped
        /// executor (``SessionLanguageModelState/withPromptCacheScope(_:)``).
        /// A task-local reaches the executor of the fork only when it is
        /// bound on the task that calls that executor: the SDK can run this
        /// executor on another task than the SDK call, and the submission
        /// that holds the SDK call runs on a task that the worker of the
        /// queue makes.
        ///
        /// The observer of the session gets the start of the pass before the
        /// wrapped executor runs, and the end of the pass on every exit.
        ///
        /// The pass watches of the wrapper run beside the wrapped executor,
        /// and each has ended before this call returns to the SDK
        /// (``SessionLanguageModelState/withPassWatches(_:)``).
        ///
        /// - Parameters:
        ///   - request: The generation request, passed through unchanged.
        ///   - model: This wrapper. Unread: the state arrives through the
        ///     configuration.
        ///   - channel: The outer channel the wrapped executor streams into.
        /// - Throws: What the wrapped executor throws.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: SessionLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let observer = state.passObserver
            observer?.passStarted()
            defer { observer?.passEnded() }
            try await state.withPassWatches {
                try await state.withPromptCacheScope {
                    try await innerRespond(request, channel)
                }
            }
        }
    }
}

/// The per-session state of one ``SessionLanguageModel``.
///
/// It is a class because its identity is the executor cache key of the
/// wrapper: one state is one session, so one executor. The per-pass work of a
/// session (its prompt-cache scope, the report of a pass, its pass watches)
/// keeps its session data here.
final class SessionLanguageModelState: Sendable {
    /// Work that runs beside each pass of this wrapper, on a child task of
    /// the pass (``withPassWatches(_:)``). The pass cancels it when the
    /// wrapped executor returns, and waits for it to end.
    ///
    /// It is the one place where the owner can read the transcript of the
    /// `LanguageModelSession` of this wrapper while a call of that session is
    /// in flight. The SDK writes its transcript with no guard between two
    /// passes of a tool loop, and a read from another task in that window
    /// aborts the process (task ^vg6bmq6). Inside a pass, the SDK guards its
    /// writes. A watch must end soon after its cancel, because the pass does
    /// not return to the SDK before that.
    typealias PassWatch = @Sendable () async -> Void

    /// The identity of one pass watch, which ``removePassWatch(_:)`` takes.
    ///
    /// It is a class because its object identity is the key: each call of
    /// ``addPassWatch(_:)`` makes a new object, so each watch has a key that
    /// no other watch has. It holds no stored value.
    final class PassWatchID: Hashable, Sendable {
        /// Identity equality.
        ///
        /// - Parameters:
        ///   - lhs: One identity.
        ///   - rhs: The other identity.
        /// - Returns: `true` when both are the same object.
        static func == (lhs: PassWatchID, rhs: PassWatchID) -> Bool {
            lhs === rhs
        }

        /// Hashes by the `ObjectIdentifier` of this object.
        ///
        /// - Parameter hasher: The hasher to feed.
        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }
    }

    /// The raw model whose executor runs each pass.
    let wrapped: any LanguageModel

    /// What the owner of this wrapper installs on it: the session of its
    /// backend, or the compaction that made its backend for a summarizer
    /// call.
    private struct Installation {
        /// The observer each pass reports to, or `nil` before the session
        /// installs one.
        var passObserver: GenerationPassObserver?

        /// The prompt-cache scope that each pass binds, or `nil` before the
        /// owner installs one.
        var promptCacheScope: MLXLanguageModel.PromptCacheScope?

        /// The watches each pass runs, by identity.
        var passWatches: [PassWatchID: PassWatch] = [:]
    }

    /// What the owner of this wrapper installed. A lock guards it, because
    /// the owner writes it from its actor while an executor reads it from
    /// the task of a pass.
    private let installation = Mutex(Installation())

    /// The observer each pass of this wrapper reports to, or `nil` when the
    /// session installed none.
    var passObserver: GenerationPassObserver? {
        installation.withLock { $0.passObserver }
    }

    /// Gives `observer` the passes of this wrapper from the next pass on.
    ///
    /// - Parameter observer: The observer of the session of this wrapper.
    func reportPasses(to observer: GenerationPassObserver) {
        installation.withLock { $0.passObserver = observer }
    }

    /// The prompt-cache scope that each pass of this wrapper binds, or `nil`
    /// when nothing installed one. A pass with no scope binds nothing, so
    /// the fork keys it by the id of the first transcript entry.
    var promptCacheScope: MLXLanguageModel.PromptCacheScope? {
        installation.withLock { $0.promptCacheScope }
    }

    /// Keys the prompt cache of each pass of this wrapper by `sessionID`,
    /// from the next pass on.
    ///
    /// - Parameter sessionID: The id of the session of this wrapper.
    func scopePromptCache(toSession sessionID: String) {
        installation.withLock { $0.promptCacheScope = .session(sessionID) }
    }

    /// Makes each pass of this wrapper keep no prompt cache, from the next
    /// pass on: each pass binds `.uncached`, so it checks out no cache and
    /// checks in none (task ^ptev9yy). A compaction sets it on the backend
    /// of each summarizer call, so that call adds no key to the cache of
    /// the model.
    ///
    /// The case is `.uncached`, never `.none`: the scope is optional, so
    /// `.none` is `Optional.none`, which binds no scope and adds a key.
    func keepNoPromptCache() {
        installation.withLock { $0.promptCacheScope = .uncached }
    }

    /// Runs `body` with the prompt-cache scope of this wrapper bound on the
    /// current task: `.session(id)` for the backend of a session,
    /// `.uncached` for the backend of a summarizer call, or no binding when
    /// nothing installed a scope.
    ///
    /// - Parameter body: The call of the wrapped executor.
    /// - Throws: What `body` throws.
    func withPromptCacheScope(_ body: () async throws -> Void) async rethrows {
        guard let scope = promptCacheScope else {
            return try await body()
        }
        try await MLXLanguageModel.$promptCacheScope.withValue(scope) {
            try await body()
        }
    }

    /// Runs `watch` beside each pass of this wrapper, from the next pass on,
    /// until ``removePassWatch(_:)`` takes it out.
    ///
    /// A pass that is running when this call adds the watch does not run
    /// it.
    ///
    /// - Parameter watch: The work to run beside each pass.
    /// - Returns: The identity of the watch, for ``removePassWatch(_:)``.
    func addPassWatch(_ watch: @escaping PassWatch) -> PassWatchID {
        let id = PassWatchID()
        installation.withLock { $0.passWatches[id] = watch }
        return id
    }

    /// Takes the watch `id` out, so the next pass does not run it. A pass
    /// that runs the watch now cancels it at its end, as before.
    ///
    /// - Parameter id: The identity that ``addPassWatch(_:)`` gave.
    func removePassWatch(_ id: PassWatchID) {
        installation.withLock { _ = $0.passWatches.removeValue(forKey: id) }
    }

    /// Runs `pass` with each pass watch of this wrapper on a child task
    /// beside it, then cancels the watches and waits for each to end.
    ///
    /// Thus each watch starts after the pass starts, and ends before this
    /// call returns. No watch runs while the SDK writes its transcript
    /// between two passes.
    ///
    /// - Parameter pass: The call of the wrapped executor.
    /// - Throws: What `pass` throws.
    func withPassWatches(_ pass: () async throws -> Void) async rethrows {
        let watches = installation.withLock { Array($0.passWatches.values) }
        guard !watches.isEmpty else {
            return try await pass()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for watch in watches {
                group.addTask { await watch() }
            }
            defer { group.cancelAll() }
            try await pass()
        }
    }

    /// Stores the raw model.
    ///
    /// - Parameter wrapped: The raw model whose executor runs each pass.
    init(wrapped: any LanguageModel) {
        self.wrapped = wrapped
    }
}
