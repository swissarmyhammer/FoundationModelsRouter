import FoundationModels
import Synchronization

/// A `FoundationModels.LanguageModel` that submits each executor pass of a
/// wrapped model as one item of a ``GenerationQueue``
/// (`generation-queue.md`, section 5.3).
///
/// There is one wrapper for each backend a container makes: each session,
/// each fork, and each summarizer backend. Each wrapper has its own
/// ``QueuedLanguageModelState``, and all the wrappers of one container share
/// the queue of that container.
///
/// The wrapper keeps the raw model in ``QueuedLanguageModelState/wrapped``. A
/// caller that needs the raw model (the `as? MLXLanguageModel` cast of
/// thinking control, the eviction of the loader) reads the raw model it keeps
/// itself, and never casts this wrapper.
struct QueuedLanguageModel: LanguageModel, Sendable {
    /// The per-session state of this wrapper: its identity, the raw model,
    /// and the queue.
    let state: QueuedLanguageModelState

    /// Makes a wrapper with a new per-session state over `wrapped` and `queue`.
    ///
    /// - Parameters:
    ///   - wrapped: The raw model whose executor runs each pass.
    ///   - queue: The queue of the container of `wrapped`.
    init(wrapping wrapped: any LanguageModel, queue: GenerationQueue) {
        state = QueuedLanguageModelState(wrapped: wrapped, queue: queue)
    }

    /// Passed through unchanged from the wrapped model.
    var capabilities: LanguageModelCapabilities { state.wrapped.capabilities }

    /// The executor cache key of this wrapper. It compares by the identity of
    /// this wrapper's state.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(state: state)
    }

    /// The executor every `LanguageModelSession` over a
    /// ``QueuedLanguageModel`` drives. The SDK caches one executor for each
    /// distinct ``Configuration``, so there is one executor for each wrapper,
    /// and the wrapped executor is built one time for each wrapper.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares by the identity of the
        /// per-session state, and not by the queue and the wrapped model: two
        /// sessions with equal keys would share one executor.
        struct Configuration: Sendable, Hashable {
            /// The per-session state of the wrapper.
            let state: QueuedLanguageModelState

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
        typealias Model = QueuedLanguageModel

        /// The per-session state of the wrapper.
        private let state: QueuedLanguageModelState

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

        /// Submits one pass of the wrapped executor to the queue, and waits
        /// for the result of that pass.
        ///
        /// The item is the executor call of the SDK itself, not a copy: it
        /// calls the wrapped executor with the same `request` and over the
        /// same `channel` that the SDK gave this call. The worker of the
        /// queue runs it on a task of its own. That task inherits no
        /// task-local of this call, so the item binds each task-local that
        /// the pass needs. The pass needs none now.
        ///
        /// The pass reports to the observer of its session, when the session
        /// installed one (task ^ake8sax): that the pass waits behind another
        /// item, that the worker starts it, and that it left the queue. The
        /// last report comes on every exit, after the result of the item, and
        /// also after a wait that a cancellation ended.
        ///
        /// - Parameters:
        ///   - request: The generation request, passed through unchanged.
        ///   - model: This wrapper. Unread: the state arrives through the
        ///     configuration.
        ///   - channel: The outer channel the wrapped executor streams into.
        /// - Throws: `CancellationError` when the task is cancelled while the
        ///   pass waits for the worker, or what the wrapped executor throws.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: QueuedLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let observer = state.passObserver
            defer { observer?.passEnded() }
            try await state.queue.runPass(onQueued: { observer?.passQueued() }) { [innerRespond] in
                observer?.passStarted()
                try await innerRespond(request, channel)
            }
        }
    }
}

/// The per-session state of one ``QueuedLanguageModel``.
///
/// It is a class because its identity is the executor cache key of the
/// wrapper: one state is one session, so one executor. The per-pass work of a
/// session (its prompt-cache key, the report of a queue wait) keeps its
/// session data here.
final class QueuedLanguageModelState: Sendable {
    /// The raw model whose executor runs each pass.
    let wrapped: any LanguageModel

    /// The queue of the container of ``wrapped``, which every wrapper of that
    /// container shares.
    let queue: GenerationQueue

    /// The observer that the session of this wrapper installed, or `nil`
    /// before it installs one. A lock guards it, because the session writes
    /// it from its actor while an executor reads it from the task of a pass.
    private let installedPassObserver = Mutex<GenerationPassObserver?>(nil)

    /// The observer each pass of this wrapper reports to, or `nil` when the
    /// session installed none.
    var passObserver: GenerationPassObserver? {
        installedPassObserver.withLock { $0 }
    }

    /// Gives `observer` the passes of this wrapper from the next pass on.
    ///
    /// - Parameter observer: The observer of the session of this wrapper.
    func reportPasses(to observer: GenerationPassObserver) {
        installedPassObserver.withLock { $0 = observer }
    }

    /// Stores the raw model and the queue.
    ///
    /// - Parameters:
    ///   - wrapped: The raw model whose executor runs each pass.
    ///   - queue: The queue of the container of `wrapped`.
    init(wrapped: any LanguageModel, queue: GenerationQueue) {
        self.wrapped = wrapped
        self.queue = queue
    }
}
