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
/// Branch decision executed per the observed answer: native tools get the
/// ambient context free, so `EventEmittingTool`/`connecting(_:)` and the
/// conformance-cast wiring are to be deleted (follow-up task on this board).
/// Code mode was unaffected either way — `ToolInvoker` binds the context
/// itself with no Apple code in the path.
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
        let name = "context_probe"
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
        You always respond to the user by calling the `context_probe` tool with the \
        user's exact text as its `note` argument, then report the tool's result back \
        to the user.
        """

    /// The turn prompt that forces the probe-tool call.
    private static let probePrompt = "Call the context_probe tool with the note 'ping'."

    /// The response-token bound for the probe turn — room for a
    /// tool-calling round plus a short final answer.
    private static let probeMaxTokens = 512

    /// Builds the ``ToolContext`` the test binds around `respond()` — a
    /// real mailbox and a minted completion token, so a context that arrives
    /// inside the probe is checkable as this exact binding.
    private static func makeBoundContext(completionToken: String) -> ToolContext {
        ToolContext(
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: DiscardingSink(),
            tool: "context_probe",
            op: "context_probe",
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

    /// Drives one probe turn — binds `context` around `session.respond` —
    /// and returns the path's definite verdict: whether the task-local
    /// ``ToolContext`` arrived inside the probe's `call(arguments:)`.
    ///
    /// A turn where the model never invoked the probe fails via `#require`
    /// (no verdict was obtained — never a skip-as-pass), and a present
    /// context must carry the bound `completionToken` (proving the arriving
    /// context is the test's binding, not a stray one).
    private static func probeVerdict(
        session: LanguageModelSession,
        log: ProbeObservationLog,
        pathLabel: String
    ) async throws -> Bool {
        let boundCompletionToken = SessionMailbox.makeCompletionToken()
        let context = makeBoundContext(completionToken: boundCompletionToken)

        let response = try await ToolContext.$current.withValue(context) {
            try await session.respond(
                to: probePrompt,
                options: GenerationOptions(maximumResponseTokens: probeMaxTokens)
            )
        }
        #expect(!response.content.isEmpty)

        let observations = await log.observations
        let first = try #require(
            observations.first,
            "\(pathLabel): the model never invoked context_probe — no propagation verdict was obtained"
        )
        #expect(
            observations.allSatisfy { $0.contextWasPresent == first.contextWasPresent },
            "\(pathLabel): every probe invocation in the turn must agree on the verdict"
        )
        if first.contextWasPresent {
            #expect(
                first.observedCompletionToken == boundCompletionToken,
                "\(pathLabel): an arriving context must be the test's own binding"
            )
        } else {
            #expect(first.observedCompletionToken == nil)
        }
        print(
            "[PropagationProbe] \(pathLabel) path verdict: ToolContext.current != nil inside "
                + "call(arguments:) == \(first.contextWasPresent) "
                + "(observedCompletionToken=\(first.observedCompletionToken ?? "nil"), "
                + "bound=\(boundCompletionToken))"
        )
        return first.contextWasPresent
    }

    // MARK: - The two paths

    @Test("MLX path: whether the ToolContext bound around respond() arrives inside call(arguments:)")
    func mlxPathPropagationVerdict() async throws {
        try await GatedSuiteSerialGate.shared.withPermit {
            let container = try await makeContainer()
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
