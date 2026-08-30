import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``ToolContext/mount(_:op:as:)`` — the one public entry point an
/// outside package mounts a tool on a running session through.
///
/// Every test drives the returned tool directly, with no conditional cast, and
/// reads the mounted run's events back from the sink the mounting context posts
/// to.
@Suite("ToolContext.mount: mount a tool on the running context")
struct ToolContextMountTests {
    private typealias Fixtures = MountFixtures

    /// The tool stamp of the enclosing run every test mounts under.
    private static let hostTool = "host_tool"

    /// The op stamp of the enclosing run every test mounts under.
    private static let hostOp = "host run"

    /// The completion token of the enclosing run every test mounts under.
    private static let hostToken = "host-run-token"

    /// One test's wiring: the enclosing run's context, and the mailbox and sink
    /// standing behind it.
    private struct Host {
        /// The context every mount is made on.
        let context: ToolContext

        /// The run plane the mounted runs are tracked in.
        let mailbox: SessionMailbox

        /// The upstream the mounted runs' events land in.
        let sink: Fixtures.RecordingSink
    }

    /// Builds the enclosing run's wiring, stamped with ``hostTool``, ``hostOp``
    /// and ``hostToken``.
    ///
    /// - Returns: A fresh context over a fresh mailbox and a fresh sink.
    private static func makeHost() -> Host {
        let mailbox = SessionMailbox()
        let sink = Fixtures.RecordingSink()
        let context = ToolContext(
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: sink,
            tool: hostTool,
            op: hostOp,
            completionToken: hostToken,
            isCancelled: { false }
        )
        return Host(context: context, mailbox: mailbox, sink: sink)
    }

    // MARK: - The three decorators

    @Test(
        "mounting a String-output tool as background hands the call back as a completion token on the context's own run plane"
    )
    func mountsStringOutputToolInTheBackground() async throws {
        let gate = RunLatch()
        let host = Self.makeHost()

        let mounted = host.context.mount(
            Fixtures.GatedTool(gate: gate), op: "run gate", as: ToolMount(mode: .background)
        )

        #expect(mounted is BackgroundToolRunner<MountArguments>)
        let rendered = try await mounted.call(arguments: MountArguments(value: "mounted"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        // The run is tracked on the mounting context's own plane, under the op
        // the mount call declared.
        #expect(await host.mailbox.backgroundRuns().map(\.op) == ["run gate"])

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: host.mailbox
        )
        #expect(terminal.detail == "gated: mounted")
    }

    @Test("mounting a String-output tool under the stock configuration runs it to completion in band")
    func mountsStringOutputToolRunToCompletion() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.FastTool())

        #expect(mounted is RunToCompletionRunner<MountArguments>)
        let rendered = try await mounted.call(arguments: MountArguments(value: "in-band"))
        #expect(rendered == "fast: in-band")
        // No token was handed out: the call stayed in band.
        #expect(await host.mailbox.backgroundRuns().isEmpty)
    }

    @Test("mounting a non-String-output tool binds it and passes its own output back unchanged")
    func mountsNonStringOutputToolInTheBindingDecorator() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(Fixtures.NonStringOutputTool())

        #expect(mounted is ContextBindingTool<MountArguments, NonStringToolOutput>)
        let output = try await mounted.call(arguments: MountArguments(value: "silent"))
        #expect(output.text == "ignored")
        // A silent run posts nothing at all.
        #expect(await host.sink.events.isEmpty)
    }

    // MARK: - The mount a tool declares for itself

    @Test("a tool's own declared mount wins over the configuration the mount call passes")
    func declaredMountWinsOverTheConfigurationArgument() async throws {
        let host = Self.makeHost()

        // The tool declares background with no timeout of its own, and the call
        // asks for the stock synchronous mount instead. The gate never opens:
        // this test reads the mount the layer chose, and never calls through it.
        let mounted = host.context.mount(
            Fixtures.DeclaredBackgroundToolRunner(gate: RunLatch()), as: .synchronous
        )

        // Both facts contradict the configuration, so only the declaration
        // explains them — the layer, and the clock with it.
        let runner = try #require(mounted as? BackgroundToolRunner<MountArguments>)
        #expect(runner.timeout == nil)
    }

    // MARK: - The event route

    @Test("a mounted tool's events reach the sink under the mounting context's own correlation")
    func mountedToolEventsCarryTheContextCorrelation() async throws {
        let host = Self.makeHost()

        let mounted = host.context.mount(AmbientNonStringOutputTool())
        let output = try await mounted.call(arguments: AmbientToolArguments(value: "inner"))

        let events = await host.sink.events
        #expect(events.map(\.detail) == ["inner"])
        // The mounting context re-stamps everything it forwards, so the outbox
        // sees the enclosing operation and never the inner run.
        #expect(events.map(\.tool) == [Self.hostTool])
        #expect(events.map(\.op) == [Self.hostOp])
        #expect(events.map(\.correlationID) == [Self.hostToken])
        // The inner run keeps a completion token of its own all the same: the
        // fixture returns the one its bound context carried.
        #expect(output.text != Self.hostToken)
        #expect(ULID(output.text) != nil)
    }

    // MARK: - The return type

    @Test("the mounted tool keeps the wrapped tool's Arguments and Output, so a caller needs no cast")
    func theReturnTypeCarriesArgumentsAndOutput() async throws {
        let host = Self.makeHost()

        // The annotations are the assertion: each mount is named at the wrapped
        // tool's own `Arguments` and `Output`, with no conditional cast between.
        let inBand: any Tool<MountArguments, String> = host.context.mount(Fixtures.FastTool())
        let backgrounded: any Tool<MountArguments, String> = host.context.mount(
            Fixtures.FastTool(), as: ToolMount(mode: .background)
        )
        let bound: any Tool<AmbientToolArguments, NonStringToolOutput> = host.context.mount(
            AmbientNonStringOutputTool()
        )

        let rendered = try await inBand.call(arguments: MountArguments(value: "typed"))
        #expect(rendered == "fast: typed")

        let pending = try await backgrounded.call(arguments: MountArguments(value: "typed"))
        #expect(try Fixtures.decodeEnvelope(pending).pending)

        let output = try await bound.call(arguments: AmbientToolArguments(value: "typed"))
        #expect(!output.text.isEmpty)
    }
}
