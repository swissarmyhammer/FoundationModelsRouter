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
        // No caller until the dependent tracing cards open this span.
        // periphery:ignore
        static let compact = prefix + "compact"

        /// One ``Router/resolve(profile:reporting:)`` call: the whole joint
        /// fit and the loads under it.
        // No caller until the dependent tracing cards open this span.
        // periphery:ignore
        static let resolve = prefix + "resolve"

        /// One model load into residency, inside a resolve.
        // No caller until the dependent tracing cards open this span.
        // periphery:ignore
        static let load = prefix + "load"

        /// One ``RoutedSession/fork(workingDirectory:)`` call.
        // No caller until the dependent tracing cards open this span.
        // periphery:ignore
        static let fork = prefix + "fork"

        /// The whole life of one session, from the handle that vends it to
        /// ``RoutedSession/close()``.
        // No caller until the dependent tracing cards open this span.
        // periphery:ignore
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

        /// The span id of the session the work runs on.
        static let sessionId = "session.id"

        /// The id of the turn the work belongs to, unique inside its session.
        static let turnId = "turn.id"

        /// The surface that started the turn. See ``RouterTracing/TurnEntryPoint``.
        static let turnEntryPoint = "turn.entry_point"

        /// The model-facing name of the called tool.
        // No caller until the dependent tracing cards write this attribute.
        // periphery:ignore
        static let toolName = "tool.name"

        /// The ``ModelSlot`` the model fills.
        // No caller until the dependent tracing cards write this attribute.
        // periphery:ignore
        static let slot = "slot"

        /// The chosen candidate's footprint estimate, in bytes.
        // No caller until the dependent tracing cards write this attribute.
        // periphery:ignore
        static let footprintBytes = "footprint.bytes"

        /// The budget the fit ran against, in bytes.
        // No caller until the dependent tracing cards write this attribute.
        // periphery:ignore
        static let budgetBytes = "budget.bytes"

        /// How many tokens went into the model call.
        static let tokensIn = "tokens.in"

        /// How many tokens came out of the model call.
        static let tokensOut = "tokens.out"

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
