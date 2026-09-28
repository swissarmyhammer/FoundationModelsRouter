import Foundation
import Logging
import Tracing

/// The router's telemetry vocabulary: the name of every span it opens, the key
/// of every attribute those spans carry, the label of every logger, the key of
/// every log metadata value, and the rules that say which tracer and which
/// logger a call uses.
///
/// One home for the vocabulary (rule 3 of the OpenTelemetry design of
/// 2026-09-28), so a name is written once and read everywhere. Each name
/// starts with the module name. A name here is part of the router's observable
/// surface: a dashboard, a query or an alert that a host application builds on
/// it must keep working, so change a name only as a deliberate break.
///
/// The package uses only the telemetry APIs: `swift-distributed-tracing` for
/// spans and `swift-log` for logs. They are abstractions and not exporters.
/// Until a host application bootstraps a backend, `InstrumentationSystem.tracer`
/// is a no-op tracer and each logger writes through the default handler of
/// swift-log. The library bootstraps no backend.
///
/// The type was `RouterTracing` before it covered logs. It is internal, so the
/// rename needs no deprecated alias.
///
/// ## No content in the telemetry
///
/// A span attribute, a log message and a log metadata value must never carry
/// prompt text, response text, tool arguments, tool output, or embed input
/// text. A finished span and a log record leave the process through whatever
/// backend the host application bootstrapped, and the router cannot know where
/// that backend sends what it receives, so the payload stays free of the
/// caller's own content. Identifiers, names, counts and sizes are safe; content
/// is not.
///
/// For a log record this means:
///
/// - The message is a constant text.
/// - Each variable value is a metadata value, under a ``LogMetadataKey``.
/// - An error is logged by its type and a safe code (``errorMetadata(_:)``),
///   never by its description, because a description can carry model content.
///
/// The rule is proved, not merely stated: `SpanContentSafetyTests` drives a
/// submission, a tool call, a compaction and an embed against an `InMemoryTracer`, reads
/// every attribute value of every recorded span, and fails on any value that
/// carries the fixture's own content. Each new span the router learns to open
/// is held to that one test.
enum RouterTelemetry {
    /// What every span name, logger label and log metadata key begins with.
    private static let prefix = "FoundationModelsRouter."

    /// The operation name of every span the router opens.
    ///
    /// Each name begins with the module's own prefix, so a span the router
    /// opened stays recognizable in a trace that also holds the spans of the
    /// host application.
    ///
    /// The span of one tool call inside a submission is not in this list:
    /// the tool hosting of FoundationModelsExtras opens it, with the name
    /// `FoundationModelsExtras.tool` and the attributes `tool.name`,
    /// `tool.run_kind` and `tool.outcome`.
    enum SpanName {
        /// One ``RoutedModel/embed(texts:)`` call.
        static let embed = prefix + "embed"

        /// One submission of a session: one SDK call of the chain that
        /// answers its messages, with every tool call inside it.
        static let submission = prefix + "submission"

        /// One compaction of a session's transcript, driven by a caller or by the
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
        /// session then goes on to do is measured by its own ``submission``,
        /// ``compact`` and ``fork`` spans. Which of the three shapes made the
        /// session is written on the span as
        /// ``RouterTelemetry/AttributeKey/sessionOrigin``.
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
        /// Written only once the child exists, so a fork that failed carries
        /// no such key. Read beside ``sessionId``, the two
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
        /// ``RouterTelemetry/SessionOrigin``.
        static let sessionOrigin = "session.origin"

        /// The id of the submission, unique in its session.
        static let submissionId = "submission.id"

        /// Why the session made the submission. See
        /// ``SubmissionStart/Cause``: `message`, `mail`, or `continuation`.
        static let submissionCause = "submission.cause"

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

        /// The transcript's estimated size, in tokens, before a compaction ran.
        static let tokensBefore = "tokens.before"

        /// The transcript's estimated size, in tokens, after a compaction ran.
        static let tokensAfter = "tokens.after"

        /// What asked for the compaction. See ``RouterTelemetry/CompactionTrigger``.
        static let compactionTrigger = "compaction.trigger"

        /// The summarizer tier that wrote the compaction's applied summary: `flash`
        /// for the profile's flash slot, or `own-model` for the session's own
        /// model.
        ///
        /// The span does not have this key when no summary applied.
        static let compactionTier = "compaction.tier"

        /// How many strings one embed call embeds.
        static let embeddingInputCount = "embedding.input_count"

        /// The length of each vector an embed call produces.
        static let embeddingDimension = "embedding.dimension"
    }

    /// The value ``AttributeKey/compactionTrigger`` carries: what asked for a
    /// compaction.
    ///
    /// Both compaction paths run the same mechanics and open the same span, so the
    /// span alone cannot say which of the two opened it. This attribute says
    /// so, and it lets a query separate the compactions a caller drove from the
    /// compactions the auto-compaction budget drove.
    enum CompactionTrigger: String {
        /// ``RoutedSession/compact(prompt:budget:)``.
        case caller

        /// The auto-compaction budget: the proactive compaction before an answer, and
        /// the reactive compaction after a context overflow.
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
        /// ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:)``.
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

    /// The category of a logger: the part of its label after the module name.
    ///
    /// Each category names one area of the router, so a host can set a log
    /// level or a filter for one area.
    enum LogCategory: String, CaseIterable {
        /// The compaction of a transcript.
        case compaction = "Compaction"

        /// A rejected tool call that goes back to the model.
        case rejectedToolCall = "RejectedToolCall"

        /// A model call that makes no progress.
        case generation = "Generation"

        /// The discovery priming of an answer.
        case discoveryPriming = "DiscoveryPriming"

        /// A model call that stops so that its answer can compact.
        case compactionYield = "CompactionYield"

        /// The resident-model pool.
        case modelPool = "ModelPool"

        /// The recording of transcripts and their restore.
        case recording = "Recording"

        /// The retry after a context overflow.
        case overflowRetry = "OverflowRetry"

        /// The decode of the lines of a transcript file.
        case transcriptLineDecoding = "TranscriptLineDecoding"

        /// The delivery of mail to a session.
        case mailDelivery = "MailDelivery"

        /// A model call that repeats itself and stops.
        case repetitionStop = "RepetitionStop"

        /// The sidecar file of a session.
        case sessionSidecar = "SessionSidecar"

        /// The read of the metadata of a model repository.
        case repoMetadataReader = "RepoMetadataReader"

        /// The cache of the metadata of a model repository.
        case repoMetadataCache = "RepoMetadataCache"
    }

    /// The key of every metadata value of a router log record.
    ///
    /// Read the type's own rule above before adding a key: a key here names an
    /// identifier, a name, a count or a size, and never a piece of the
    /// caller's content. Each key begins with the module name and has the
    /// dotted form of an attribute key.
    enum LogMetadataKey {
        /// The ``LogCategory`` of an explicit logger (``logger(_:explicit:)``).
        static let category = prefix + "log.category"

        /// The id of the session.
        static let sessionId = prefix + AttributeKey.sessionId

        /// The id of a transcript entry.
        static let entryId = prefix + "entry.id"

        /// The id of a transcript segment.
        static let segmentId = prefix + "segment.id"

        /// The name of the response format of a prompt entry.
        static let responseFormatName = prefix + "response_format.name"

        /// The name of an SDK case that the router does not know.
        static let entryCase = prefix + "entry.case"

        /// What a failed encode tried to encode, as the router names it.
        static let encodeContext = prefix + "encode.context"

        /// The schema name of a structured segment.
        static let schemaName = prefix + "schema.name"

        /// The type of an error.
        static let errorType = prefix + "error.type"

        /// The code of an error.
        static let errorCode = prefix + "error.code"

        /// The path of a file.
        static let filePath = prefix + "file.path"

        /// A byte offset in a file.
        static let byteOffset = prefix + "file.byte_offset"

        /// The sequence number of a transcript event.
        static let eventSeq = prefix + "event.seq"

        /// The sequence number of a transcript event that a newer event
        /// replaces.
        static let supersededSeq = prefix + "event.superseded_seq"

        /// The report of a repetition stop (``RepetitionStop``).
        static let repetitionStop = prefix + "repetition_stop"

        /// The report of a generation stall (``GenerationStall``).
        static let generationStall = prefix + "generation_stall"

        /// The report of a pause of the mail delivery.
        static let mailDeliveryPause = prefix + "mail_delivery.pause"

        /// The size of the context window, in tokens.
        static let contextTokens = prefix + "tokens.context"

        /// The size of a prompt, in tokens.
        static let promptTokens = prefix + "tokens.prompt"

        /// The configured compaction target, in tokens.
        static let configuredTargetTokens = prefix + "tokens.configured_target"

        /// The rule that chose the target of an overflow retry.
        static let overflowRule = prefix + "overflow.rule"

        /// What an overflow retry does.
        static let overflowOutcome = prefix + "overflow.outcome"

        /// A measured size of the context, in tokens.
        static let measuredTokens = prefix + "tokens.measured"

        /// The compaction trigger of a budget, in tokens.
        static let triggerTokens = prefix + "tokens.trigger"

        /// Why a tool call was rejected.
        static let rejectionReason = prefix + "tool.rejection_reason"

        /// The model-facing name of a tool.
        static let toolName = prefix + "tool.name"

        /// The ordinal of a retry in its answer.
        static let retryOrdinal = prefix + "retry.ordinal"

        /// The summarizer tier of a compaction.
        static let summarizerTier = prefix + AttributeKey.compactionTier

        /// The divergence of a transcript from the recorded entries.
        static let divergence = prefix + "transcript.divergence"

        /// The case name of a ``CompactionShortfall``.
        static let shortfall = prefix + "compaction.shortfall"

        /// The room for a summary that a compaction target leaves, in tokens.
        static let allowedSummaryTokens = prefix + "tokens.allowed_summary"

        /// The size of the input of a summarizer call, in tokens.
        static let inputTokens = prefix + "tokens.input"

        /// The largest window of the summarizers, in tokens.
        static let windowTokens = prefix + "tokens.window"

        /// The size of a snapshot, in tokens.
        static let snapshotTokens = prefix + "tokens.snapshot"

        /// The type of a model container.
        static let containerType = prefix + "container.type"

        /// A model reference, in canonical string form.
        static let modelRef = prefix + AttributeKey.modelRef

        /// Every key above.
        static let allKeys = [
            category, sessionId, entryId, segmentId, responseFormatName, entryCase, encodeContext,
            schemaName, errorType, errorCode, filePath, byteOffset, eventSeq, supersededSeq,
            repetitionStop, generationStall, mailDeliveryPause, contextTokens, promptTokens,
            configuredTargetTokens, overflowRule, overflowOutcome, measuredTokens, triggerTokens,
            rejectionReason, toolName, retryOrdinal, summarizerTier, divergence, shortfall,
            allowedSummaryTokens, inputTokens, windowTokens, snapshotTokens, containerType, modelRef,
        ]
    }

    /// Makes a logger of the module for one category, with the label
    /// `FoundationModelsRouter.<category>`.
    ///
    /// Make the logger at call time, never in a stored `static let`. A logger
    /// keeps the handler of the time that it was made, so a stored logger
    /// misses a backend that the host bootstraps later, and a test capture
    /// that starts later.
    ///
    /// - Parameter category: The area of the router that logs.
    /// - Returns: A logger that writes through the logging backend of the host.
    static func makeLogger(_ category: LogCategory) -> Logger {
        Logger(label: prefix + category.rawValue)
    }

    /// The logger a call logs through.
    ///
    /// An explicit logger crosses a detached task, where a task-local logging
    /// context does not reach. The session pump is such a task. The explicit
    /// logger keeps its own label, so it gets the category as metadata.
    ///
    /// - Parameters:
    ///   - category: The area of the router that logs.
    ///   - explicit: The logger the owner was given, or `nil` for a logger of
    ///     the module.
    /// - Returns: `explicit` with the category as metadata when it is set,
    ///   else ``makeLogger(_:)``.
    static func logger(_ category: LogCategory, explicit: Logger?) -> Logger {
        guard var logger = explicit else { return makeLogger(category) }
        logger[metadataKey: LogMetadataKey.category] = .string(category.rawValue)
        return logger
    }

    /// The log metadata of an error: its type and its code.
    ///
    /// The description of an error is not safe: an error from the model or a
    /// tool can carry the caller's content in it. The type and the code name
    /// the failure and carry no content.
    ///
    /// - Parameter error: The error to log.
    /// - Returns: The type under ``LogMetadataKey/errorType`` and the code
    ///   under ``LogMetadataKey/errorCode``.
    static func errorMetadata(_ error: any Error) -> Logger.Metadata {
        [
            LogMetadataKey.errorType: "\(type(of: error))",
            LogMetadataKey.errorCode: "\((error as NSError).code)",
        ]
    }
}
