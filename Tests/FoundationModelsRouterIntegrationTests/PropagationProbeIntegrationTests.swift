import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as the rest of this target: unset
/// (the default, and on any CI/GPU-less box) this whole suite is skipped, so
/// `swift test` stays green without network or a GPU. Kept as its own
/// file-scoped constant rather than sharing another file's — Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let propagationProbeIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var propagationProbeIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[propagationProbeIntegrationEnvVar] != nil
}

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let propagationProbeModel: ModelRef = RealModels.standard

/// The probe tool's model-facing `name`, bound once.
///
/// Four places have to name the same tool for the probe to mean anything: the
/// tool's own declaration, the ``ToolContext`` the test binds around
/// `respond()`, the turn's instructions and prompt, and the transcript scan that
/// counts how many times the model asked for it. A single constant is what keeps
/// a rename from silently turning the probe into a test of a tool nobody
/// mounted.
private let propagationProbeToolName = "context_probe"

// MARK: - Suite

/// The phase-1 **propagation probe** (task c25mpnw; eventplan.md §"Phases"
/// phase 1, §"The ambient context" effect 3): when Apple's
/// `LanguageModelSession.respond` calls a tool, does the `@TaskLocal`
/// ``ToolContext`` bound around `respond()` arrive inside the tool's
/// `call(arguments:)`, or is it `nil`?
///
/// One probe tool reads `ToolContext.current` from inside `call(arguments:)`
/// and records whether it was present (and the `completionToken` it observed,
/// proving the arriving context is the test's own binding rather than a
/// stray one). The test binds the context around `respond()` and forces one
/// probe-tool call on the MLX path (`MLXLanguageModel` over
/// ``RealModels/standard``) and one on the system model
/// (`SystemLanguageModel.default`). Each path's verdict is a definite
/// boolean: a run where the model never invokes the probe fails via
/// `#require` — never a silent skip-as-pass.
///
/// **Observed answer (real run, Apple Silicon, macOS 27.0 build 26A5388g,
/// MacOSX27.0.sdk, Swift 6.4, 2026-08-04): the context PROPAGATES on both
/// paths.** On the MLX path
/// (`MLXLanguageModel` over Qwen3.6-27B) and on `SystemLanguageModel.default`
/// alike, `ToolContext.current` was non-`nil` inside `call(arguments:)` and
/// carried exactly the `completionToken` the test bound — Apple's tool
/// dispatch runs the tool inside the calling task's structured-concurrency
/// tree, so the task local survives `respond()`. Both tests below assert
/// this observed verdict as a hard boolean; a future SDK that starts
/// dispatching tools on a detached task breaks them loudly.
///
/// Reconfirmed 2026-08-08 under a full `FM_ROUTER_INTEGRATION_TESTS=1 swift
/// test`, this time with the tool call proved rather than assumed: both paths
/// recorded exactly one `context_probe` call in the session's own transcript,
/// `call(arguments:)` ran, and the arriving context carried the bound
/// `completionToken` (task `^f9zt7c5`).
///
/// Branch decision executed per the observed answer: native tools get the
/// ambient context free, so the tool-side event-subscription protocol and
/// its conformance-cast wiring were deleted (task ^ew49xjj on this board).
/// Code mode was unaffected either way — `ToolInvoker` binds the context
/// itself with no Apple code in the path.
///
/// ## Why this probe cannot be handed to pre-discovery seeding (`^f9zt7c5`)
///
/// The failure this probe once reported — a first assistant turn carrying zero
/// tool calls — is a member of the very class `^s4405wc` ("pre-discovery
/// seeding") exists to make structurally impossible. The two cards are
/// nonetheless **independent**, and seeding is not the fix here, for two
/// reasons that both come straight from what seeding does.
///
/// 1. **Seeding would answer the question by removing it.** `DiscoveryPrimer`
///    invokes the designated tool **host-side** — it opens the `any Tool`
///    existential and awaits `call(arguments:)` itself — then splices the
///    finished `.toolCalls`/`.toolOutput` pair into the transcript. Apple's
///    dispatch never runs. A seeded call would therefore fill this probe's
///    observation log from a direct, same-task call, which propagates a task
///    local trivially, and the probe would report `true` while testing nothing
///    about `LanguageModelSession`. Seeding defeats this probe rather than
///    fixing it, so it must never be used here.
/// 2. **The opt-in is not even reachable.** `DiscoveryPriming` is configured on
///    `RoutedModel.makeSession(...)` and consumed by a private method on
///    `RoutedSessionActor`. This probe drives a raw
///    `LanguageModelSession(model:tools:instructions:)`, deliberately, because
///    the whole question is about Apple's own machinery.
///
/// What `^s4405wc` does contribute is the diagnosis. Its recorded finding — that
/// upfront prose only shifts the frequency of the zero-tool-call class — is why
/// this probe no longer treats "no tool call" and "no propagation" as one
/// outcome, and why the real cause here turned out to be an inherited cache
/// rather than the prompt (see ``makeUncontaminatedContainer()``).
@Suite(
    "Gated propagation probe: does the ToolContext task local survive respond()? (task c25mpnw)",
    .serialized,
    .timeLimit(.minutes(15)),
    .enabled(if: propagationProbeIntegrationEnabled)
)
struct PropagationProbeIntegrationTests {
    // MARK: - Probe tool

    /// The scripted tool argument schema the turn's prompt reliably drives:
    /// a single required string field, the smallest surface a model can
    /// reliably fill in when directly instructed to call this tool — the
    /// same shape ``RecordingHandleIntegrationTests``' `EchoArguments` uses.
    @Generable
    struct ProbeArguments {
        let note: String
    }

    /// What the probe tool observed inside one `call(arguments:)`.
    private struct ProbeObservation: Sendable {
        /// Whether `ToolContext.current` was non-`nil` inside the call.
        let contextWasPresent: Bool

        /// The `completionToken` of the arriving context, or `nil` when no
        /// context arrived — matched against the token the test bound, so a
        /// present context is provably the test's own binding.
        let observedCompletionToken: String?
    }

    /// Collects every ``ProbeObservation`` the probe tool records — an actor
    /// so the tool can append from whatever task Apple's machinery invokes
    /// `call(arguments:)` on.
    private actor ProbeObservationLog {
        private(set) var observations: [ProbeObservation] = []

        func record(_ observation: ProbeObservation) {
            observations.append(observation)
        }
    }

    /// The probe: a real `FoundationModels.Tool` conformer whose whole job
    /// is to read `ToolContext.current` from inside `call(arguments:)` —
    /// the exact read a native tool would perform for ambient capabilities —
    /// and record what it saw.
    private struct ContextProbeTool: FoundationModels.Tool {
        let name = propagationProbeToolName
        let description = "Records a probe observation for the given note."

        let log: ProbeObservationLog

        func call(arguments: ProbeArguments) async throws -> String {
            let context = ToolContext.current
            await log.record(
                ProbeObservation(
                    contextWasPresent: context != nil,
                    observedCompletionToken: context?.completionToken
                )
            )
            return "probe recorded: \(arguments.note)"
        }
    }

    /// A sink that drops every event — the probe never posts, but a real
    /// ``ToolContext`` needs one.
    ///
    /// Deliberately file-local even though `ElicitationRoutingTests` (in the
    /// `FoundationModelsRouterTests` target) defines an identical no-op sink:
    /// that copy is `private` inside a suite in a *different test target*, and
    /// SwiftPM forbids any target from depending on a test target, so the two
    /// modules cannot see each other's test code. This target's `Support/`
    /// directory (home of `GatedSuiteSerialGate`) is equally target-local, so
    /// moving the sink there would not deduplicate across targets either — the
    /// only genuine share would be a new non-test support library target added
    /// to Package.swift solely to carry this two-line no-op across test
    /// modules.
    private struct DiscardingSink: OperationEventSink {
        func post(_ event: OperationEvent) async {}
    }

    // MARK: - Shared fixtures

    /// The tool-forcing instructions shape ``RecordingHandleIntegrationTests``
    /// already proved drives a real tool call.
    private static let probeInstructions = """
        You always respond to the user by calling the `\(propagationProbeToolName)` tool with \
        the user's exact text as its `note` argument, then report the tool's result back \
        to the user.
        """

    /// The turn prompt that forces the probe-tool call.
    private static let probePrompt =
        "Call the \(propagationProbeToolName) tool with the note 'ping'."

    /// The response-token bound for the probe turn — room for a
    /// tool-calling round plus a short final answer.
    private static let probeMaxTokens = 512

    /// How much of the turn's final answer a diagnostic quotes — enough to tell
    /// a refusal from an announcement from an answer the model produced out of
    /// its own training, short enough to keep a failure message readable.
    private static let diagnosticAnswerPrefixLength = 400

    /// Builds the ``ToolContext`` the test binds around `respond()` — a
    /// real mailbox and a minted completion token, so a context that arrives
    /// inside the probe is checkable as this exact binding.
    private static func makeBoundContext(completionToken: String) -> ToolContext {
        ToolContext(
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: DiscardingSink(),
            tool: propagationProbeToolName,
            op: propagationProbeToolName,
            completionToken: completionToken,
            isCancelled: { false }
        )
    }

    /// Loads the real `.standard` model directly through a real
    /// ``LiveModelLoader`` and returns its concrete
    /// ``MLXFoundationModelsContainer`` — the same technique the rest of
    /// this target's gated suites use.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: propagationProbeModel,
            slot: .standard,
            context: RealModels.context,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// Loads ``propagationProbeModel`` after dropping whatever another gated
    /// suite left cached for it, so this turn's generation depends on nothing
    /// but this turn's own prompt.
    ///
    /// `MLXLanguageModel` keeps a process-global container cache keyed by model
    /// id, and alongside it a per-model prompt cache that stores each completed
    /// round's KV state as content-addressed chunks shared by *every*
    /// conversation on that model. Every gated suite in this target drives the
    /// same ``RealModels/standard``, so by the time this suite runs, that shared
    /// pool holds chunks from other suites' conversations — several of which are
    /// themselves tool-calling turns.
    ///
    /// That inheritance decides this probe's outcome. Measured 2026-08-08: run
    /// alone the turn calls the probe tool every time, but under a full
    /// `FM_ROUTER_INTEGRATION_TESTS=1 swift test` it reproducibly emitted no
    /// tool call and answered `"I have called the context_probe tool with the
    /// note 'ping'."` — narrating a call it never made, exactly as a model does
    /// when its context already contains one. Dropping the model first turns
    /// that back into a real dispatched call (task `^f9zt7c5`).
    ///
    /// `MLXLanguageModel.evict()` is the narrow instrument: it drops this one
    /// model from the container cache and purges this one model's prompt cache,
    /// leaving every other model alone. Deliberately not
    /// `MLXLanguageModel.evictAll()`, which also evicts models this suite never
    /// touches and so perturbs sibling suites. This is the same instrument the
    /// probe already applies when its turn ends, moved to the front as well: the
    /// probe both leaves a clean cache behind and requires a clean one in front.
    ///
    /// The first load is cheap — a container is a small value and
    /// ``LiveModelLoader/preload(container:)`` is a no-op, so weights only
    /// materialize on the turn's own `respond()`.
    ///
    /// - Returns: A container for ``propagationProbeModel`` with no inherited
    ///   prompt-cache state.
    /// - Throws: If either load fails.
    private func makeUncontaminatedContainer() async throws -> MLXFoundationModelsContainer {
        let inherited = try await makeContainer()
        await inherited.model.evict()
        return try await makeContainer()
    }

    // MARK: - One turn's measured facts

    /// Everything one probe turn did, gathered before any assertion runs.
    ///
    /// The probe originally read only ``observations``, and an empty
    /// `observations` has two completely different causes that a single
    /// assertion cannot tell apart (task `^f9zt7c5`): the model never asked for
    /// the tool, or it asked and the call never reached `call(arguments:)`. The
    /// session's own transcript settles that, because it records what the model
    /// asked for independently of what the SDK then did about it — so the
    /// transcript's account of the turn is measured alongside the tool's.
    private struct ProbeTurn: Sendable {
        /// The turn's final assistant text.
        let responseContent: String

        /// Whether the turn's `.instructions` entry advertised the probe tool to
        /// the model — the difference between a model that declined a tool it
        /// could see and a tool that was never mounted or never rendered.
        let toolWasVisibleToModel: Bool

        /// How many calls to the probe tool the transcript records — the model's
        /// own decision, independent of whether the SDK then dispatched them.
        let recordedCallCount: Int

        /// Every entry kind the transcript carries after the turn, in order.
        let transcriptOutline: String

        /// What the probe tool recorded from inside `call(arguments:)` — empty
        /// when the tool body never ran.
        let observations: [ProbeObservation]

        /// The `completionToken` the test bound around `respond()`.
        let boundCompletionToken: String
    }

    /// Whether an `.instructions` entry of `transcript` advertises `tool`.
    ///
    /// - Parameters:
    ///   - tool: The tool `name` to look for among the advertised definitions.
    ///   - transcript: The session transcript to read.
    /// - Returns: `true` when some `.instructions` entry defines that tool.
    private static func advertisesTool(_ tool: String, in transcript: Transcript) -> Bool {
        transcript.contains { entry in
            guard case .instructions(let instructions) = entry else { return false }
            return instructions.toolDefinitions.contains { $0.name == tool }
        }
    }

    /// Counts the calls to `tool` that `transcript` records.
    ///
    /// - Parameters:
    ///   - transcript: The session transcript to read.
    ///   - tool: The tool `name` to count calls to.
    /// - Returns: How many recorded calls name that tool.
    private static func callCount(in transcript: Transcript, to tool: String) -> Int {
        transcript.reduce(0) { total, entry in
            guard case .toolCalls(let calls) = entry else { return total }
            return total + calls.filter { $0.toolName == tool }.count
        }
    }

    /// Names every entry kind `transcript` carries, in transcript order.
    ///
    /// - Parameter transcript: The session transcript to outline.
    /// - Returns: The comma-separated kind names.
    private static func outline(of transcript: Transcript) -> String {
        transcript
            .map { TranscriptEntryMapper.event(from: $0).kind.rawValue }
            .joined(separator: ", ")
    }

    /// Quotes `text` for a diagnostic, clipped to
    /// ``diagnosticAnswerPrefixLength`` characters.
    ///
    /// - Parameter text: The text to quote.
    /// - Returns: The quoted text, marked as clipped when it was.
    private static func quoted(_ text: String) -> String {
        guard text.count > diagnosticAnswerPrefixLength else { return "\"\(text)\"" }
        return "\"\(text.prefix(diagnosticAnswerPrefixLength))…\" "
            + "(clipped from \(text.count) characters)"
    }

    /// Drives one probe turn — binding a fresh ``ToolContext`` around
    /// `session.respond` — and measures what it did without judging it.
    ///
    /// - Parameters:
    ///   - session: The session to drive one turn on.
    ///   - log: The probe tool's observation log.
    /// - Returns: The turn's measured facts.
    /// - Throws: Whatever `session.respond` throws.
    private static func runProbeTurn(
        session: LanguageModelSession,
        log: ProbeObservationLog
    ) async throws -> ProbeTurn {
        let boundCompletionToken = SessionMailbox.makeCompletionToken()
        let context = makeBoundContext(completionToken: boundCompletionToken)

        let response = try await ToolContext.$current.withValue(context) {
            try await session.respond(
                to: probePrompt,
                options: GenerationOptions(maximumResponseTokens: probeMaxTokens)
            )
        }
        let transcript = session.transcript
        return ProbeTurn(
            responseContent: response.content,
            toolWasVisibleToModel: advertisesTool(propagationProbeToolName, in: transcript),
            recordedCallCount: callCount(in: transcript, to: propagationProbeToolName),
            transcriptOutline: outline(of: transcript),
            observations: await log.observations,
            boundCompletionToken: boundCompletionToken
        )
    }

    // MARK: - The verdict

    /// Drives one probe turn and returns the path's definite verdict: whether
    /// the task-local ``ToolContext`` arrived inside the probe's
    /// `call(arguments:)`.
    ///
    /// Checks the turn in four stages, so a failure names *which* thing failed
    /// instead of leaving the reader to guess from an empty observation list
    /// (task `^f9zt7c5`):
    ///
    /// 1. The turn advertised the probe tool to the model. A turn that did not
    ///    is a mounting or rendering failure, and every later stage is moot.
    /// 2. The transcript records at least one call to it — the model decided to
    ///    call the tool it could see. A turn with none is the zero-tool-call
    ///    class (a first assistant turn containing no tool call, the class
    ///    `^s4405wc` addresses), never a propagation failure.
    /// 3. `call(arguments:)` ran. A recorded call whose body never executed is a
    ///    dispatch failure, again never a propagation failure.
    /// 4. Only then, the propagation question itself: whether the context
    ///    arrived, and — when it did — that it carries the bound
    ///    `completionToken`, proving it is the test's own binding rather than a
    ///    stray one.
    ///
    /// - Parameters:
    ///   - session: The session to drive one turn on.
    ///   - log: The probe tool's observation log.
    ///   - pathLabel: The path name every diagnostic is prefixed with.
    /// - Returns: Whether the bound ``ToolContext`` arrived inside the tool.
    /// - Throws: Whatever `session.respond` throws, or a `#require` failure when
    ///   stage 1, 2, or 3 did not hold — no verdict was obtained, and the
    ///   message says which stage that was.
    private static func probeVerdict(
        session: LanguageModelSession,
        log: ProbeObservationLog,
        pathLabel: String
    ) async throws -> Bool {
        let turn = try await runProbeTurn(session: session, log: log)
        #expect(!turn.responseContent.isEmpty)

        try #require(
            turn.toolWasVisibleToModel,
            """
            \(pathLabel): stage 1 — the turn's instructions advertise no \
            \(propagationProbeToolName) definition, so the model never saw the tool. \
            This is a mounting failure, NOT a propagation failure. \
            Transcript: [\(turn.transcriptOutline)]
            """
        )
        try #require(
            turn.recordedCallCount > 0,
            """
            \(pathLabel): stage 2 — the tool was advertised, but the turn's transcript \
            records no \(propagationProbeToolName) call, so the model answered without \
            calling it. This is the zero-tool-call class, NOT a propagation failure, and \
            no propagation verdict was obtained. Transcript: [\(turn.transcriptOutline)]. \
            Final answer: \(quoted(turn.responseContent))
            """
        )
        let first = try #require(
            turn.observations.first,
            """
            \(pathLabel): stage 3 — the transcript records \(turn.recordedCallCount) \
            \(propagationProbeToolName) call(s), but call(arguments:) never ran. This is a \
            dispatch failure, NOT a propagation failure, and no propagation verdict was \
            obtained. Transcript: [\(turn.transcriptOutline)]
            """
        )
        #expect(
            turn.observations.allSatisfy { $0.contextWasPresent == first.contextWasPresent },
            "\(pathLabel): every probe invocation in the turn must agree on the verdict"
        )
        if first.contextWasPresent {
            #expect(
                first.observedCompletionToken == turn.boundCompletionToken,
                "\(pathLabel): an arriving context must be the test's own binding"
            )
        } else {
            #expect(first.observedCompletionToken == nil)
        }
        print(
            "[PropagationProbe] \(pathLabel) path verdict: ToolContext.current != nil inside "
                + "call(arguments:) == \(first.contextWasPresent) "
                + "(observedCompletionToken=\(first.observedCompletionToken ?? "nil"), "
                + "bound=\(turn.boundCompletionToken), "
                + "recordedCallCount=\(turn.recordedCallCount), "
                + "transcript=[\(turn.transcriptOutline)])"
        )
        return first.contextWasPresent
    }

    // MARK: - The two paths

    @Test("MLX path: whether the ToolContext bound around respond() arrives inside call(arguments:)")
    func mlxPathPropagationVerdict() async throws {
        try await GatedSuiteSerialGate.shared.withPermit {
            let container = try await makeUncontaminatedContainer()
            let log = ProbeObservationLog()
            let session = LanguageModelSession(
                model: container.model,
                tools: [ContextProbeTool(log: log)],
                instructions: Self.probeInstructions
            )

            let propagated = try await Self.probeVerdict(
                session: session, log: log, pathLabel: "MLX")
            // The observed 2026-08-04 verdict, pinned: the task local
            // propagates on the MLX path. A future toolchain that starts
            // dispatching tools on a detached task must break this loudly.
            #expect(propagated, "MLX path: the ToolContext task local must survive respond()")

            await container.model.evict()
        }
    }

    @Test(
        "system-model path: whether the ToolContext bound around respond() arrives inside call(arguments:)"
    )
    func systemModelPathPropagationVerdict() async throws {
        try await GatedSuiteSerialGate.shared.withPermit {
            let systemModel = SystemLanguageModel.default
            guard systemModel.isAvailable else {
                // A hard failure, never a skip-as-pass: an unavailable system
                // model means no system-path verdict was obtained.
                Issue.record(
                    "SystemLanguageModel.default is unavailable on this machine (\(systemModel.availability)) — no system-path verdict was obtained"
                )
                return
            }
            let log = ProbeObservationLog()
            let session = LanguageModelSession(
                model: systemModel,
                tools: [ContextProbeTool(log: log)],
                instructions: Self.probeInstructions
            )

            let propagated = try await Self.probeVerdict(
                session: session, log: log, pathLabel: "system-model")
            // The observed 2026-08-04 verdict, pinned: the task local
            // propagates on the system-model path too.
            #expect(
                propagated,
                "system-model path: the ToolContext task local must survive respond()")
        }
    }
}
