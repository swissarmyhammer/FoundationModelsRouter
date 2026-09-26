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
/// prompt-cache key of the session.
///
/// A wrapper of a backend holds no queue: the session submits each whole SDK
/// call of its backend to the ``GenerationQueue`` of the model
/// (``LanguageModelSessionBackend/generationQueue``). A wrapper that a
/// recording handle gets (``LoadedLLMContainer/languageModel``) has a pass
/// queue instead (``SessionLanguageModelState/passQueue``). The consumer
/// drives that SDK session itself, so the Router never makes its SDK call and
/// cannot submit it whole. Each pass of such a wrapper is thus one item of the
/// queue, and it never runs at the same time as a submission of a session.
///
/// The wrapper keeps the raw model in ``SessionLanguageModelState/wrapped``. A
/// caller that needs the raw model (the `as? MLXLanguageModel` cast of
/// thinking control, the eviction of the loader) reads the raw model it keeps
/// itself, and never casts this wrapper.
struct SessionLanguageModel: LanguageModel, Sendable {
    /// The per-session state of this wrapper: its identity, the raw model,
    /// the pass observer, and the prompt-cache key of the session.
    let state: SessionLanguageModelState

    /// Makes a wrapper with a new per-session state over `wrapped`.
    ///
    /// The wrapper of the session of one backend has no pass queue, and runs
    /// each pass directly. The wrapper of a recording handle, whose SDK calls
    /// the Router does not make, gives `passQueue`: each of its passes is
    /// then one item of that queue.
    ///
    /// - Parameters:
    ///   - wrapped: The raw model whose executor runs each pass.
    ///   - passQueue: The queue of the container of `wrapped`, or `nil` (the
    ///     default) for the wrapper of a backend.
    init(wrapping wrapped: any LanguageModel, passQueue: GenerationQueue? = nil) {
        state = SessionLanguageModelState(wrapped: wrapped, passQueue: passQueue)
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
        /// of its session, and reports its start and its end to the observer
        /// of its session.
        ///
        /// The pass is the executor call of the SDK itself, not a copy: it
        /// calls the wrapped executor with the same `request` and over the
        /// same `channel` that the SDK gave this call, on the task of this
        /// call. A wrapper with a pass queue submits the pass to that queue
        /// as one item, whose task inherits no task-local of this call.
        ///
        /// The pass binds the scope itself, around the call of the wrapped
        /// executor (``SessionLanguageModelState/withPromptCacheScope(_:)``).
        /// A task-local reaches the executor of the fork only when it is
        /// bound on the task that calls that executor: the SDK can run this
        /// executor on another task than the SDK call, and the item of a pass
        /// queue runs on the task of the worker.
        ///
        /// The observer of the session gets the start of the pass before the
        /// wrapped executor runs, and the end of the pass on every exit.
        ///
        /// - Parameters:
        ///   - request: The generation request, passed through unchanged.
        ///   - model: This wrapper. Unread: the state arrives through the
        ///     configuration.
        ///   - channel: The outer channel the wrapped executor streams into.
        /// - Throws: `CancellationError` when the task is cancelled while a
        ///   queued pass waits for the worker, or what the wrapped executor
        ///   throws.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: SessionLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let pass: @Sendable () async throws -> Void = { [innerRespond, state] in
                let observer = state.passObserver
                observer?.passStarted()
                defer { observer?.passEnded() }
                try await state.withPromptCacheScope {
                    try await innerRespond(request, channel)
                }
            }
            guard let passQueue = state.passQueue else {
                return try await pass()
            }
            try await passQueue.submit(pass)
        }
    }
}

/// The per-session state of one ``SessionLanguageModel``.
///
/// It is a class because its identity is the executor cache key of the
/// wrapper: one state is one session, so one executor. The per-pass work of a
/// session (its prompt-cache key, the report of a pass) keeps its session
/// data here.
final class SessionLanguageModelState: Sendable {
    /// The raw model whose executor runs each pass.
    let wrapped: any LanguageModel

    /// The queue each pass of this wrapper is one item of, or `nil` for the
    /// wrapper of a backend, whose session submits each whole SDK call.
    let passQueue: GenerationQueue?

    /// What the session of this wrapper installs on it.
    private struct Installation {
        /// The observer each pass reports to, or `nil` before the session
        /// installs one.
        var passObserver: GenerationPassObserver?

        /// The id that keys the prompt cache of each pass, or `nil` before
        /// the session installs one.
        var promptCacheSessionID: String?
    }

    /// What the session of this wrapper installed. A lock guards it, because
    /// the session writes it from its actor while an executor reads it from
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

    /// The id that keys the prompt cache of each pass of this wrapper, or
    /// `nil` when no session installed one. A pass with no id binds no scope,
    /// so the fork keys it by the id of the first transcript entry.
    var promptCacheSessionID: String? {
        installation.withLock { $0.promptCacheSessionID }
    }

    /// Keys the prompt cache of each pass of this wrapper by `sessionID`,
    /// from the next pass on.
    ///
    /// - Parameter sessionID: The id of the session of this wrapper.
    func scopePromptCache(toSession sessionID: String) {
        installation.withLock { $0.promptCacheSessionID = sessionID }
    }

    /// Runs `body` with the prompt-cache scope of the session of this
    /// wrapper bound on the current task: `.session(id)` when the session
    /// installed an id, or no binding when it installed none.
    ///
    /// - Parameter body: The call of the wrapped executor.
    /// - Throws: What `body` throws.
    func withPromptCacheScope(_ body: () async throws -> Void) async rethrows {
        guard let sessionID = promptCacheSessionID else {
            return try await body()
        }
        try await MLXLanguageModel.$promptCacheScope.withValue(.session(sessionID)) {
            try await body()
        }
    }

    /// Stores the raw model and the pass queue.
    ///
    /// - Parameters:
    ///   - wrapped: The raw model whose executor runs each pass.
    ///   - passQueue: The queue each pass is one item of, or `nil`.
    init(wrapped: any LanguageModel, passQueue: GenerationQueue?) {
        self.wrapped = wrapped
        self.passQueue = passQueue
    }
}
