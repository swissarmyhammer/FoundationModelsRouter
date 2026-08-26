import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^7mxhb39: a tool declares the ``RunKind`` its own work is
/// and supplies the canceler that work needs, both through the public
/// ``DetachmentParameterProviding`` seam.
///
/// The point is honesty about authority. A capability that owns an OS process
/// group ends it with `killpg(SIGKILL)`, which is authoritative, so its
/// canceler reports ``OperationOutcome/stopped`` — the work is certainly over.
/// The engine's own canceler only requests a cooperative stop, so it reports
/// ``OperationOutcome/cancelled``. The two are never flattened, and until this
/// seam existed a tool outside this module could only get the second one.
///
/// Every fixture here reaches the run plane through the public protocol and
/// the public ``ToolContext`` capabilities alone: no tool of this suite names
/// `SessionMailbox.track`, and the tool that declares nothing keeps the
/// behaviour it already has.
@Suite("Declared run kind: a tool states its own RunKind and supplies its own canceler")
struct DeclaredRunKindTests {
  // MARK: - Interval fixtures

  /// A sleep long enough that only cancellation ever ends it.
  private static let unendingSleepNanoseconds: UInt64 = 3_600_000_000_000

  /// The ceiling on any await a test of this suite performs against the run
  /// plane — present only so a broken handshake ends the test instead of
  /// hanging the suite.
  private static let settlementDeadline: TimeInterval = 30

  // MARK: - Argument fixtures

  /// The arguments every fixture tool of this suite takes.
  @Generable
  struct DeclaredRunKindArguments {
    /// A value the tool echoes back, so one settled run is identifiable.
    let value: String
  }

  // MARK: - Tool fixtures

  /// Records every completion token whose process group a canceler killed,
  /// so a test can assert the tool's own canceler is what ran.
  private actor KillWitness {
    /// The tokens killed, in kill order.
    private(set) var killedTokens: [String] = []

    /// Records one kill.
    ///
    /// - Parameter completionToken: The killed run's completion token.
    func recordKill(completionToken: String) {
      killedTokens.append(completionToken)
    }
  }

  /// Backgrounds every call at once, declares ``RunKind/process``, and
  /// supplies the authoritative canceler its own capability owns — the
  /// shell-shaped tool this seam exists for.
  ///
  /// The canceler stands for `killpg(SIGKILL)`: it records the kill and
  /// reports ``OperationOutcome/stopped``, because a killed process group is
  /// certainly over. It signals nothing itself, exactly as the real one
  /// would not: the signal belongs to the capability, and the body's wait on
  /// the group is `gate`, which each test opens for itself.
  private struct DeclaredProcessTool: Tool, DetachmentParameterProviding {
    let name = "declared_process_tool"
    let description = "is backgrounded at once as a process run and kills its own group"

    /// Stands for the run's wait on its process group.
    let gate: RunLatch

    /// Records each kill this tool's canceler makes.
    let witness: KillWitness

    func call(arguments: DeclaredRunKindArguments) async throws -> String {
      await gate.waitUntilOpen()
      return "process: \(arguments.value)"
    }

    var detachmentRunKind: RunKind { .process }

    func detachmentCanceler(
      forCompletionToken completionToken: String
    ) -> (@Sendable () async -> OperationOutcome)? {
      let witness = witness
      return {
        await witness.recordKill(completionToken: completionToken)
        return .stopped
      }
    }
  }

  /// Sleeps until cancelled and declares nothing at all — the tool that
  /// exists today, which must keep being backgrounded as ``RunKind/swiftTask``
  /// under the engine's own cooperative canceler with no edit of its own.
  private struct UndeclaredKindTool: Tool {
    let name = "undeclared_kind_tool"
    let description = "sleeps until cancelled and declares no detachment parameters"

    func call(arguments: DeclaredRunKindArguments) async throws -> String {
      try await Task.sleep(nanoseconds: DeclaredRunKindTests.unendingSleepNanoseconds)
      return "never returned"
    }
  }

  // MARK: - Harness

  /// One test's wiring: the mailbox the run is tracked on, the engine that
  /// backgrounds it, and a ``ToolContext`` bound to that same mailbox — the
  /// public route a tool host reads and cancels the run plane through.
  private struct Harness {
    /// The session mailbox every run of this harness is tracked on.
    let mailbox: SessionMailbox

    /// The host-side context that reads and cancels the run plane.
    let context: ToolContext

    /// The sink every run's events funnel into, so a test can count terminals.
    let sink: MountFixtures.RecordingSink

    /// The background-mounted engine under test: every call is handed
    /// back as a token at once, so no test waits on a wall clock.
    let background: BackgroundTool<DeclaredRunKindArguments>
  }

  /// The tool identity the harness's host-side context is stamped with.
  private static let hostToolName = "run_plane_host"

  /// The op string the harness's host-side context is stamped with.
  private static let hostOp = "read runs"

  /// Wraps `tool` in a ``BackgroundTool`` over a fresh mailbox, beside a
  /// host-side context bound to that same mailbox.
  ///
  /// - Parameter tool: The tool to wrap.
  /// - Returns: The harness.
  private static func makeHarness(
    backgroundMounting tool: any Tool<DeclaredRunKindArguments, String>
  ) -> Harness {
    let mailbox = SessionMailbox()
    let sessionID = ULID.generate()
    let sink = MountFixtures.RecordingSink()
    let background = BackgroundTool(
      wrapping: tool,
      sessionID: sessionID,
      mailbox: mailbox,
      sink: sink,
      timeout: DetachConfiguration.defaultTimeoutSeconds
    )
    let context = ToolContext(
      sessionID: sessionID,
      mailbox: mailbox,
      sink: DiscardingOperationEventSink(),
      tool: hostToolName,
      op: hostOp,
      completionToken: SessionMailbox.makeCompletionToken(),
      isCancelled: { false }
    )
    return Harness(mailbox: mailbox, context: context, sink: sink, background: background)
  }

  /// Backgrounds one call of `harness`'s engine and returns the background run.
  ///
  /// - Parameter harness: The harness whose engine to call.
  /// - Returns: The one run the call backgrounded, as ``ToolContext/backgroundRuns()``
  ///   reports it.
  private static func backgroundOneRun(through harness: Harness) async throws -> BackgroundRun {
    let rendered = try await harness.background.call(
      arguments: DeclaredRunKindArguments(value: "long job")
    )
    // The call really detached: the model was handed a pending envelope
    // rather than a result.
    #expect(PendingRunEnvelope.isRendered(text: rendered))
    let runs = await harness.context.backgroundRuns()
    #expect(runs.count == 1)
    return try #require(runs.first)
  }

  // MARK: - A declared process run

  @Test(
    "a tool that declares .process is backgrounded under that kind, and ToolContext.backgroundRuns() lists it there"
  )
  func aDeclaredProcessRunIsListedAsProcess() async throws {
    let gate = RunLatch()
    let harness = Self.makeHarness(
      backgroundMounting: DeclaredProcessTool(gate: gate, witness: KillWitness())
    )

    let run = try await Self.backgroundOneRun(through: harness)

    #expect(run.kind == .process)

    // Let the run's body end, so the test leaves no detached work behind.
    await gate.open()
    _ = await harness.context.wait(
      completionToken: run.completionToken, seconds: Self.settlementDeadline
    )
  }

  @Test(
    "cancelling a run whose tool supplied its own canceler reports that canceler's authoritative .stopped"
  )
  func cancellingADeclaredProcessRunReportsStopped() async throws {
    let gate = RunLatch()
    let witness = KillWitness()
    let harness = Self.makeHarness(
      backgroundMounting: DeclaredProcessTool(gate: gate, witness: witness)
    )

    let run = try await Self.backgroundOneRun(through: harness)

    // `.stopped` is certainty and `.cancelled` is a request. The engine's
    // own canceler could only ever report the second one, so this outcome
    // proves the tool's canceler is the one that ran.
    #expect(
      await harness.context.cancel(completionToken: run.completionToken)
        == .reported(.stopped)
    )
    #expect(await witness.killedTokens == [run.completionToken])

    await gate.open()
    _ = await harness.context.wait(
      completionToken: run.completionToken, seconds: Self.settlementDeadline
    )
  }

  // MARK: - The natural terminal of a stopped process run

  /// Waits on `run` through the host context and returns its terminal event.
  private static func settledTerminal(
    of run: BackgroundRun, through harness: Harness
  ) async throws -> OperationEvent {
    let outcome = await harness.context.wait(
      completionToken: run.completionToken, seconds: Self.settlementDeadline
    )
    guard case .settled(let terminal) = outcome else {
      Issue.record("run \(run.completionToken) did not settle: \(outcome)")
      throw MountFixtures.FixtureError()
    }
    return terminal
  }

  /// Cancels `run` through the host context, lets its body end on `gate`,
  /// and returns the terminal event the wait collected.
  private static func stopAndSettle(
    _ run: BackgroundRun, through harness: Harness, opening gate: RunLatch
  ) async throws -> OperationEvent {
    #expect(
      await harness.context.cancel(completionToken: run.completionToken)
        == .reported(.stopped)
    )
    await gate.open()
    return try await settledTerminal(of: run, through: harness)
  }

  @Test(
    "a .process run its canceler stopped settles with that canceler's .stopped, never .succeeded, and posts exactly one terminal"
  )
  func aStoppedProcessRunSettlesWithItsCancelersOutcome() async throws {
    let gate = RunLatch()
    let harness = Self.makeHarness(
      backgroundMounting: DeclaredProcessTool(gate: gate, witness: KillWitness())
    )
    let run = try await Self.backgroundOneRun(through: harness)

    // The kill does not cancel the body: it returns normally, as a reap of
    // a killed process group does. The terminal must still say stopped.
    let terminal = try await Self.stopAndSettle(run, through: harness, opening: gate)

    #expect(terminal.outcome == .stopped)
    #expect(terminal.correlationID == run.completionToken)
    let events = await harness.sink.events
    #expect(events.filter { $0.kind == .completed }.count == 1)
    #expect(events.last?.outcome == .stopped)
  }

  @Test("wait on a .process run a cancel already stopped reports the retained .stopped terminal")
  func waitOnAStoppedProcessRunReportsStopped() async throws {
    let gate = RunLatch()
    let harness = Self.makeHarness(
      backgroundMounting: DeclaredProcessTool(gate: gate, witness: KillWitness())
    )
    let run = try await Self.backgroundOneRun(through: harness)
    _ = try await Self.stopAndSettle(run, through: harness, opening: gate)

    // The run is settled, so this wait reads the retained terminal event.
    let retained = try await Self.settledTerminal(of: run, through: harness)

    #expect(retained.outcome == .stopped)
    #expect(
      await harness.context.cancel(completionToken: run.completionToken)
        == .alreadySettled(retained)
    )
  }

  // MARK: - The behaviour that exists does not change

  @Test(
    "a tool that declares nothing is still backgrounded as .swiftTask, and cancelling it still reports the engine's cooperative .cancelled"
  )
  func aToolDeclaringNothingKeepsTheCooperativeCanceler() async throws {
    let harness = Self.makeHarness(backgroundMounting: UndeclaredKindTool())

    let run = try await Self.backgroundOneRun(through: harness)

    #expect(run.kind == .swiftTask)
    #expect(
      await harness.context.cancel(completionToken: run.completionToken)
        == .reported(.cancelled)
    )

    // The cooperative request really reaches the body: the sleep throws,
    // and the run settles as cancelled rather than running on.
    let outcome = await harness.context.wait(
      completionToken: run.completionToken, seconds: Self.settlementDeadline
    )
    guard case .settled(let terminal) = outcome else {
      Issue.record("the cancelled run did not settle: \(outcome)")
      return
    }
    #expect(terminal.outcome == .cancelled)
  }

  // MARK: - The session-end sweep

  @Test(
    "the session-end sweep reaches a declared .process run and calls the canceler its tool supplied"
  )
  func theSweepCallsTheToolsOwnCanceler() async throws {
    let gate = RunLatch()
    let witness = KillWitness()
    let harness = Self.makeHarness(
      backgroundMounting: DeclaredProcessTool(gate: gate, witness: witness)
    )

    let run = try await Self.backgroundOneRun(through: harness)

    let terminals = await harness.mailbox.sweep()

    #expect(await witness.killedTokens == [run.completionToken])
    #expect(terminals.count == 1)
    #expect(terminals.first?.correlationID == run.completionToken)
    #expect(terminals.first?.outcome == .stopped)
    #expect(await harness.context.backgroundRuns().isEmpty)

    await gate.open()
  }
}
