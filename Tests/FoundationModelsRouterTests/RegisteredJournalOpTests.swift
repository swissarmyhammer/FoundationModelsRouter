import Foundation
import FoundationModels
import Testing

// Deliberately NOT `@testable`. Task ^8y20bwd is about a registration site
// OUTSIDE this module, so this suite is held to the module's public surface:
// a route that needed `ToolContext.mailbox`, `SessionMailbox.track` or
// `TrackResult` would not compile here at all.
import FoundationModelsRouter

/// Exercises task ^8y20bwd: a registration site gives a mounted tool a journal
/// `op` that differs from the tool's own `name`.
///
/// A capability verb cannot supply that string itself — it does not know its
/// own noun, because `register(noun:tool:)` at the registration site holds it.
/// So the op rides in from the mount, and these tests read it back off the two
/// places it surfaces.
///
/// **The plane.** The pair reaches the RUN PLANE — ``BackgroundRun/op`` and
/// ``ToolInvocationRecord/op`` — and it does NOT reach the event journal of an
/// enclosing snippet, because ``ToolContext/post(_:)`` re-stamps each event it
/// forwards with the outer run's identity. The last test of this suite pins
/// that, so the plane question is not left to a reader.
@Suite("Registered journal op: a registration site gives a tool the op its events carry")
struct RegisteredJournalOpTests {
  // MARK: - Interval fixtures

  /// The ceiling on any await this suite performs against the run plane —
  /// present only so a broken handshake ends the test instead of hanging the
  /// suite.
  private static let settlementDeadline: TimeInterval = 30

  /// The mount every tool of this suite is registered under: background, so
  /// a call is handed back as a token at once and no test waits on a wall
  /// clock.
  private static let backgroundMount = ToolMount(mode: .background)

  // MARK: - Identity fixtures

  /// The verb tool's own `name` — the session-visible tool identity, which is
  /// the whole string a verb can supply for itself.
  private static let verbToolName = "execute"

  /// The canonical `"verb noun"` op the registration site supplies, which the
  /// verb cannot know: `eventplan.md` of FoundationModelsMultitool states this
  /// pair for `tools.shell.execute`.
  private static let registeredOp = "execute shell"

  /// The tool identity of the enclosing `runCode`-shaped run.
  private static let enclosingToolName = "run_code"

  /// The op of the enclosing `runCode`-shaped run — the string an inner call's
  /// events are re-stamped with.
  private static let enclosingOp = "run code"

  // MARK: - Argument fixtures

  /// The arguments every fixture tool of this suite takes.
  @Generable
  struct RegisteredOpArguments {
    /// A value the tool echoes back, so one settled run is identifiable.
    let value: String
  }

  // MARK: - Sink fixtures

  /// Records every posted event and every posted ``ToolInvocationRecord``, in
  /// order, so a test can read both planes of one run.
  private actor RecordingSink: OperationEventSink {
    /// The events posted, in post order.
    private(set) var events: [OperationEvent] = []

    /// The invocation records posted, in post order.
    private(set) var invocations: [ToolInvocationRecord] = []

    /// Records one event.
    ///
    /// - Parameter event: The event to record.
    func post(event: OperationEvent) {
      events.append(event)
    }

    /// Records one invocation record — the witness the engine dispatches to
    /// through the ``OperationEventSink`` existential.
    ///
    /// - Parameter record: The record to record.
    func post(invocation record: ToolInvocationRecord) {
      append(invocation: record)
    }

    /// Records one invocation record a forwarding sink hands on.
    ///
    /// Named apart from ``post(invocation:)`` deliberately. A source-level
    /// call spelled `upstream.post(invocation:)` on this CONCRETE actor
    /// resolves to ``OperationEventSink``'s own no-op default rather than to
    /// this actor's isolated method, so a forwarding sink written that way
    /// drops every record in silence. Dispatch through the existential picks
    /// the witness correctly, which is why every other test of this suite
    /// reads its records back.
    ///
    /// - Parameter record: The record to record.
    func append(invocation record: ToolInvocationRecord) {
      invocations.append(record)
    }
  }

  /// The sink a `runCode`-shaped registration site hands its inner mounts:
  /// each event goes upstream through the ENCLOSING run's
  /// ``ToolContext/post(_:)``, which re-stamps it, and each invocation record
  /// goes on untouched, because a record is delivery-only and carries its own
  /// identity.
  private struct EnclosingRunSink: OperationEventSink {
    /// The enclosing run's context, whose `post(_:)` re-stamps each event.
    let enclosing: ToolContext

    /// The session's own sink, which both planes end at.
    let upstream: RecordingSink

    /// Forwards `event` through the enclosing run's context.
    ///
    /// - Parameter event: The inner run's event.
    func post(event: OperationEvent) async {
      await enclosing.post(event)
    }

    /// Forwards `record` upstream unchanged.
    ///
    /// - Parameter record: The inner run's invocation record.
    func post(invocation record: ToolInvocationRecord) async {
      await upstream.append(invocation: record)
    }
  }

  // MARK: - Tool fixtures

  /// Blocks until its gate opens, so a call of it is still running while a test
  /// reads the run plane. Its `name` is the bare verb, which is exactly what a
  /// capability verb can state about itself.
  private struct GatedVerbTool: Tool {
    let name = RegisteredJournalOpTests.verbToolName
    let description = "blocks until its gate opens"

    /// The gate this tool's body waits on.
    let gate: RunLatch

    func call(arguments: RegisteredOpArguments) async throws -> String {
      await gate.waitUntilOpen()
      return "executed: \(arguments.value)"
    }
  }

  // MARK: - Harness

  /// Builds the host-side context a registration site captures and reads the
  /// run plane through — the public route, stamped as the enclosing run.
  ///
  /// - Parameters:
  ///   - mailbox: The session mailbox every run of the test is tracked on.
  ///   - sink: The session's own sink.
  /// - Returns: The enclosing run's context.
  private static func makeEnclosingContext(
    mailbox: SessionMailbox, sink: RecordingSink
  ) -> ToolContext {
    ToolContext(
      sessionID: ULID.generate(),
      mailbox: mailbox,
      sink: sink,
      tool: enclosingToolName,
      op: enclosingOp,
      completionToken: SessionMailbox.makeCompletionToken(),
      isCancelled: { false }
    )
  }

  /// Calls `mounted` one time and returns the one run that call backgrounded.
  ///
  /// - Parameters:
  ///   - mounted: The tool as its registration site mounted it.
  ///   - host: The context whose run plane the background run lands on.
  /// - Returns: The one run the call backgrounded.
  private static func backgroundOneRun(
    _ mounted: any Tool, on host: ToolContext
  ) async throws -> BackgroundRun {
    let background = try #require(mounted as? BackgroundToolRunner<RegisteredOpArguments>)
    let rendered = try await background.call(
      arguments: RegisteredOpArguments(value: "long job")
    )
    // The call really went to the background: the model was handed a pending envelope rather
    // than a result.
    #expect(PendingRunEnvelope.isRendered(text: rendered))
    let runs = await host.backgroundRuns()
    #expect(runs.count == 1)
    return try #require(runs.first)
  }

  /// Lets a background run's body end, so a test leaves no background work behind.
  ///
  /// - Parameters:
  ///   - run: The run to settle.
  ///   - gate: The gate its body waits on.
  ///   - host: The context that collects the terminal event.
  private static func settle(
    _ run: BackgroundRun, gate: RunLatch, on host: ToolContext
  ) async {
    await gate.open()
    _ = await host.wait(
      completionToken: run.completionToken, seconds: settlementDeadline
    )
  }

  // MARK: - The op a registration site gives

  @Test("a registration site's op reaches BackgroundRun.op, while the tool name stays the tool's own")
  func aRegisteredOpReachesTheRunPlane() async throws {
    let gate = RunLatch()
    let sink = RecordingSink()
    let host = Self.makeEnclosingContext(mailbox: SessionMailbox(), sink: sink)

    let mounted = ToolMounting.makeWrapped(
      tool: GatedVerbTool(gate: gate),
      inheriting: host,
      sink: sink,
      op: Self.registeredOp,
      configuration: Self.backgroundMount
    )
    let run = try await Self.backgroundOneRun(mounted, on: host)

    // The two fields really differ, which is the whole point: no route into
    // this module could make them differ before.
    #expect(run.op == Self.registeredOp)
    #expect(run.tool == Self.verbToolName)

    await Self.settle(run, gate: gate, on: host)
  }

  @Test("a registration site's op reaches the ToolInvocationRecord of the run")
  func aRegisteredOpReachesTheInvocationRecord() async throws {
    let gate = RunLatch()
    let sink = RecordingSink()
    let host = Self.makeEnclosingContext(mailbox: SessionMailbox(), sink: sink)

    let mounted = ToolMounting.makeWrapped(
      tool: GatedVerbTool(gate: gate),
      inheriting: host,
      sink: sink,
      op: Self.registeredOp,
      configuration: Self.backgroundMount
    )
    let run = try await Self.backgroundOneRun(mounted, on: host)

    // The run is still running, so the open record stands alone; it is
    // self-attributed by the background run's own completion token.
    let records = await sink.invocations
    #expect(records.map(\.op) == [Self.registeredOp])
    #expect(records.map(\.tool) == [Self.verbToolName])
    #expect(records.map(\.correlationID) == [run.completionToken])

    await Self.settle(run, gate: gate, on: host)
  }

  @Test(
    "a registration site's op reaches a non-String-output tool through the binding-only decorator"
  )
  func aRegisteredOpReachesTheBindingOnlyDecorator() async throws {
    let tool = AmbientNonStringOutputTool()
    let sink = RecordingSink()
    let host = Self.makeEnclosingContext(mailbox: SessionMailbox(), sink: sink)

    let mounted = ToolMounting.makeWrapped(
      tool: tool,
      inheriting: host,
      sink: sink,
      op: Self.registeredOp,
      configuration: Self.backgroundMount
    )
    let binding = try #require(
      mounted as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
    let output = try await binding.call(arguments: AmbientToolArguments(value: "bound"))

    // This route never backgrounds a call — there is no `String` wire form for
    // a pending envelope to replace — so the declared op arrives on the ambient
    // context the decorator binds, which re-stamps the tool's own post with it.
    #expect(await host.backgroundRuns().isEmpty)
    let events = await sink.events
    #expect(events.map(\.op) == [Self.registeredOp])
    #expect(events.map(\.tool) == [tool.name])
    #expect(events.map(\.correlationID) == [output.text])

    // A call here always runs in-band, so its open and close records both
    // stand by the time it returns, and both carry the declared op.
    let records = await sink.invocations
    #expect(records.map(\.op) == [Self.registeredOp, Self.registeredOp])
  }

  // MARK: - The behaviour that exists does not change

  @Test("a tool whose registration site names no op still reports op equal to its tool name")
  func aMountThatNamesNoOpKeepsTheOneStringStamp() async throws {
    let gate = RunLatch()
    let sink = RecordingSink()
    let host = Self.makeEnclosingContext(mailbox: SessionMailbox(), sink: sink)

    // The call this suite exists to leave alone: no `op` argument at all, which
    // is every mount that stands today.
    let mounted = ToolMounting.makeWrapped(
      tool: GatedVerbTool(gate: gate),
      inheriting: host,
      sink: sink,
      configuration: Self.backgroundMount
    )
    let run = try await Self.backgroundOneRun(mounted, on: host)

    #expect(run.op == Self.verbToolName)
    #expect(run.tool == Self.verbToolName)
    #expect(await sink.invocations.map(\.op) == [Self.verbToolName])

    await Self.settle(run, gate: gate, on: host)
  }

  // MARK: - The plane the pair appears on

  @Test(
    "an inner call inside a snippet carries its own op on the run plane, and the enclosing run's op in the event journal"
  )
  func anInnerCallReportsTheEnclosingOpInItsEventJournal() async throws {
    let gate = RunLatch()
    let sink = RecordingSink()
    let host = Self.makeEnclosingContext(mailbox: SessionMailbox(), sink: sink)

    let mounted = ToolMounting.makeWrapped(
      tool: GatedVerbTool(gate: gate),
      inheriting: host,
      sink: EnclosingRunSink(enclosing: host, upstream: sink),
      op: Self.registeredOp,
      configuration: Self.backgroundMount
    )
    let run = try await Self.backgroundOneRun(mounted, on: host)

    // The run plane carries the pair the registration site gave.
    let records = await sink.invocations
    #expect(run.op == Self.registeredOp)
    #expect(records.map(\.op) == [Self.registeredOp])

    // The event journal of the enclosing snippet does not. The inner run posted
    // nothing of its own, so the one event here is the engine's synthesized
    // pending-envelope progress — and it arrives re-stamped with the OUTER
    // run's tool, op and correlation.
    let events = await sink.events
    #expect(events.map(\.op) == [Self.enclosingOp])
    #expect(events.map(\.tool) == [Self.enclosingToolName])
    #expect(events.map(\.correlationID) == [host.completionToken])

    await Self.settle(run, gate: gate, on: host)
  }
}
