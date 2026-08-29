import Tracing

/// The router's tracing vocabulary: the name of every span it opens, the key
/// of every attribute those spans carry, and the rule that says which tracer a
/// call opens its span through.
///
/// One home for the vocabulary, so a name is written once and read everywhere.
/// A name here is part of the router's observable surface: a dashboard, a
/// query or an alert that a host application builds on it must keep working,
/// so change a name only as a deliberate break.
///
/// The package traces through `swift-distributed-tracing`, which is an
/// abstraction and not an exporter. Until a host application bootstraps a
/// backend, `InstrumentationSystem.tracer` is a no-op tracer, so an
/// application that does not trace pays nothing.
///
/// ## No content on a span
///
/// A span attribute must never carry prompt text, response text, tool
/// arguments, tool output, or embed input text. A finished span leaves the
/// process through whatever backend the host application bootstrapped, and the
/// router cannot know where that backend sends what it receives, so the
/// payload stays free of the caller's own content. Identifiers, names, counts
/// and sizes are safe; content is not.
///
/// The rule is proved, not merely stated: `SpanContentSafetyTests` drives a
/// turn, a tool call, a fold and an embed against an `InMemoryTracer`, reads
/// every attribute value of every recorded span, and fails on any value that
/// carries the fixture's own content. Each new span the router learns to open
/// is held to that one test.
enum RouterTracing {
    /// The operation name of every span the router opens.
    ///
    /// Each name begins with the module's own prefix, so a span the router
    /// opened stays recognizable in a trace that also holds the spans of the
    /// host application.
    enum SpanName {
        /// What every name below begins with.
        private static let prefix = "FoundationModelsRouter."

        /// One ``RoutedModel/embed(texts:)`` call.
        static let embed = prefix + "embed"

        /// One whole turn on a session: the prompt in, the answer out, and
        /// every tool call between the two.
        static let turn = prefix + "turn"

        /// One tool call inside a turn.
        // No caller until the dependent tracing cards open this span.
        // periphery:ignore
        static let tool = prefix + "tool"

        /// One fold of a session's transcript, driven by a caller or by the
        /// auto-compaction budget.
        static let compact = prefix + "compact"

        /// One ``Router/resolve(profile:reporting:)`` call: the whole joint
        /// fit and the loads under it.
        static let resolve = prefix + "resolve"

        /// One model load into residency, inside a resolve.
        static let load = prefix + "load"

        /// One ``RoutedSession/fork(workingDirectory:)`` call.
        static let fork = prefix + "fork"

        /// One session coming into existence: a session vended over a
        /// resident model, a session restored from disk, or a forked child.
        ///
        /// The span covers the construction, and on the restore path the
        /// transcript-tree read the construction is built from. What the
        /// session then goes on to do is measured by its own ``turn``,
        /// ``compact`` and ``fork`` spans. Which of the three shapes made the
        /// session is written on the span as
        /// ``RouterTracing/AttributeKey/sessionOrigin``.
        static let session = prefix + "session"
    }

    /// The key of every attribute a router span carries.
    ///
    /// Read the type's own rule above before adding a key: a key here names an
    /// identifier, a name, a count or a size, and never a piece of the
    /// caller's content.
    enum AttributeKey {
        /// The recording root id of the router that resolved the model.
        static let routerId = "router.id"

        /// The chosen model reference, in canonical string form.
        static let modelRef = "model.ref"

        /// The name of the authored ``ProfileDefinition`` a resolve ran.
        static let profileDefinitionName = "profile.definition_name"

        /// The key that names the model one slot chose, on a span that reports
        /// every slot at once.
        ///
        /// A load span speaks for one slot, so it names its model under
        /// ``modelRef`` and its slot under ``slot``. A resolve span speaks for
        /// all three slots at once, and one key cannot hold three answers
        /// without losing which answer belongs to which slot — so the resolve
        /// span writes one key for each: `model.ref.standard`,
        /// `model.ref.flash` and `model.ref.embedding`.
        ///
        /// - Parameter slot: The slot whose chosen model the key names.
        /// - Returns: The attribute key for that slot.
        static func chosenModelRef(slot: ModelSlot) -> String {
            "\(modelRef).\(slot.rawValue)"
        }

        /// The span id of the session the work runs on.
        ///
        /// On a fork span this names the *parent* — the session the fork was
        /// asked of. The child the fork produced is named by
        /// ``forkChildSessionId``.
        static let sessionId = "session.id"

        /// The span id of the child session one fork produced.
        ///
        /// Written only once the child exists, so a fork that was refused or
        /// that failed carries no such key. Read beside ``sessionId``, the two
        /// keys of a fork span say which session was forked and which session
        /// came out of it.
        static let forkChildSessionId = "fork.child_session_id"

        /// The span id of the session a new session was made from, on the
        /// session span of the new session.
        ///
        /// Written only when there is a parent, so a vended root names none.
        /// Read beside ``sessionId``, the two keys of a session span say which
        /// session was made and which session it came out of.
        ///
        /// Distinct from ``forkChildSessionId`` because the two look at one
        /// fork from opposite ends: the fork span names the child it produced,
        /// and the child's own session span names the parent it came from.
        static let parentSessionId = "session.parent_id"

        /// How the session came into existence. See
        /// ``RouterTracing/SessionOrigin``.
        static let sessionOrigin = "session.origin"

        /// The id of the turn the work belongs to, unique inside its session.
        static let turnId = "turn.id"

        /// The surface that started the turn. See ``RouterTracing/TurnEntryPoint``.
        static let turnEntryPoint = "turn.entry_point"

        /// The model-facing name of the called tool.
        // No caller until the dependent tracing cards write this attribute.
        // periphery:ignore
        static let toolName = "tool.name"

        /// The ``ModelSlot`` the model fills.
        static let slot = "slot"

        /// The chosen candidate's footprint estimate, in bytes.
        static let footprintBytes = "footprint.bytes"

        /// The budget the fit ran against, in bytes.
        static let budgetBytes = "budget.bytes"

        /// How many tokens went into the model call.
        static let tokensIn = "tokens.in"

        /// How many tokens came out of the model call.
        static let tokensOut = "tokens.out"

        /// The transcript's estimated size, in tokens, before a fold ran.
        static let tokensBefore = "tokens.before"

        /// The transcript's estimated size, in tokens, after a fold ran.
        static let tokensAfter = "tokens.after"

        /// What asked for the fold. See ``RouterTracing/CompactionTrigger``.
        static let compactionTrigger = "compaction.trigger"

        /// The summarizer tier that wrote the fold's applied summary: `flash`
        /// for the profile's flash slot, `own-model` for the session's own
        /// model, or `deterministic` when no summarizer wrote one at all.
        ///
        /// The automatic fold degrades from tier to tier without throwing, so
        /// this key, and never an error record, is what says a degrade
        /// happened.
        static let compactionTier = "compaction.tier"

        /// How many strings one embed call embeds.
        static let embeddingInputCount = "embedding.input_count"

        /// The length of each vector an embed call produces.
        static let embeddingDimension = "embedding.dimension"
    }

    /// The value ``AttributeKey/turnEntryPoint`` carries: the surface a turn
    /// was started through.
    ///
    /// Every turn runs through one chokepoint, so the span alone cannot say
    /// which surface asked for it. This attribute says so, and it lets a query
    /// separate the turns a caller drove from the turns a queue driver
    /// dispatched.
    enum TurnEntryPoint: String {
        /// ``RoutedSession/respond(to:maxTokens:)``, and each further turn its
        /// run-plane drain runs.
        case respond

        /// ``RoutedSession/streamResponse(to:maxTokens:)`` or
        /// ``RoutedSession/streamEvents(to:maxTokens:)``.
        case stream

        /// ``RoutedSession/dispatchNextPrompt()``: a queued prompt, or a
        /// settled run's delivery turn.
        case dispatch
    }

    /// The value ``AttributeKey/compactionTrigger`` carries: what asked for a
    /// fold.
    ///
    /// Both fold paths run the same mechanics and open the same span, so the
    /// span alone cannot say which of the two opened it. This attribute says
    /// so, and it lets a query separate the folds a caller drove from the
    /// folds the auto-compaction budget drove.
    enum CompactionTrigger: String {
        /// ``RoutedSession/compact(prompt:budget:)``.
        case caller

        /// The auto-compaction budget: the proactive fold before a turn, and
        /// the reactive fold after a context overflow.
        case auto
    }

    /// The value ``AttributeKey/sessionOrigin`` carries: how a session came
    /// into existence.
    ///
    /// All three shapes are built by one factory and open one span, so the
    /// span alone cannot say which shape opened it. This attribute says so,
    /// and it lets a query separate the cost of reassembling a session from
    /// disk from the cost of vending a fresh one.
    enum SessionOrigin: String {
        /// A root session vended over a resident model, through
        /// ``RoutedLLM/makeSession(configuration:)`` or the surfaces that
        /// reach it.
        case new

        /// One node of a tree rebuilt from what is on disk, through
        /// ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``.
        case restored

        /// A child taken from a live session, through
        /// ``RoutedSession/fork(workingDirectory:)``.
        case forked
    }

    /// The tracer a call opens its span through.
    ///
    /// `nil` is the resolve-late shape, and it is the default the whole
    /// package carries: an application that bootstraps a tracing backend
    /// *after* it constructs its ``Router`` still traces, because nothing is
    /// captured until the call itself.
    ///
    /// - Parameter explicit: The tracer the handle was constructed with, or
    ///   `nil` to read the bootstrapped tracer now.
    /// - Returns: `explicit` when it is set, else `InstrumentationSystem.tracer`.
    static func tracer(explicit: (any Tracer)?) -> any Tracer {
        explicit ?? InstrumentationSystem.tracer
    }
}
