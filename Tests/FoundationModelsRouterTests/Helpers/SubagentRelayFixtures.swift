import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// What ``SubagentJobTool`` does in the session of one call.
enum SubagentRole: Sendable {
    /// The run makes a child session, relays the questions of the child to
    /// its own session (``SubagentQuestionRelay``), and mails the child one
    /// message. Then it waits on the gates of the step, closes the child, and
    /// waits for the end of the relay.
    case relay(SubagentRelayStep)

    /// The run asks the user one question, and returns the answer.
    case ask(SubagentAskStep)
}

/// One relaying level of a test: the agent name that the relay puts in the
/// path of each question, and the gate that holds the relaying run open.
struct SubagentRelayStep: Sendable {
    /// The name of the child agent, as the relay puts it in
    /// `ElicitationRequest.agentPath`.
    let agentName: String

    /// The gate of the relaying run. The run closes the child only after the
    /// gate opens, or after a cancel of the run.
    let gate = RunLatch()

    /// When set, the relaying run closes the child only after this gate
    /// opens, also after a cancel of the run. Thus a test keeps the child
    /// open while the parent closes.
    var closeGate: RunLatch?

    /// When `true`, the relaying run does not relay by itself. It mounts a
    /// synchronous tool (`ToolContext.mount(_:op:as:)`), and the call of
    /// that tool relays. Thus the context of the relay has its own
    /// completion token, and the relaying run holds the call.
    var relaysThroughAMount = false
}

/// The question of the asking level of a test.
struct SubagentAskStep: Sendable {
    /// Whether the question is a URL-mode question. Else it is a form-mode
    /// question.
    var asksForURL = false

    /// When set, the asking run first starts a fake background run in its
    /// own session, held on this latch, so the session works while its
    /// question is open.
    var besideRun: RunLatch?
}

/// Holds the facts that ``SubagentJobTool`` and a test share: the role of
/// each session, the sessions, the child sessions with a feed that the box
/// opened before the first mail of the child, and the answers that the
/// asking runs got.
///
/// Each child takes the next role of the roles that the box got at its start,
/// in order. Every field is behind one lock, and ``changes`` reports each
/// change, so a test waits for a child or an answer with no clock.
final class SubagentRelayBox: Sendable {
    /// One child session and its feed.
    struct Child: Sendable {
        /// The child session.
        let session: any RoutedSession

        /// A feed of the child, made before its first mail.
        let feed: AsyncStream<SessionOutput>
    }

    /// The fields behind the lock.
    private struct State {
        /// The role of each session, by session id.
        var roles: [ULID: SubagentRole] = [:]

        /// The sessions, by session id.
        var sessions: [ULID: any RoutedSession] = [:]

        /// The roles of the children that come next, in order.
        var childRoles: [SubagentRole]

        /// The children, in the order they were made.
        var children: [Child] = []

        /// Each answer that an asking run got, in order.
        var answers: [ElicitationResponse] = []

        /// The context of each asking run, in order.
        var askContexts: [ToolContext] = []

        /// The target of each relaying run, in order.
        var targets: [SubagentQuestionTarget] = []

        /// The count of the relays whose ``SubagentQuestionRelay/finish()``
        /// returned.
        var finishedRelays = 0

        /// The count of the relaying runs that ended, also with an error.
        var endedRelays = 0

        /// The count of the asking runs that ended, also with an error.
        var endedAsks = 0
    }

    /// The fields, behind one lock.
    private let state: Mutex<State>

    /// Makes each child of a relaying run from the session of that run.
    private let makeChild: @Sendable (any RoutedSession) async throws -> any RoutedSession

    /// Signalled after each change of the fields.
    let changes = ChangeSignal()

    /// Makes a box.
    ///
    /// - Parameters:
    ///   - childRoles: The role of each child, in the order the children
    ///     come.
    ///   - makeChild: Makes each child from the session of the relaying run.
    ///     The default is ``subagentChild(of:)``.
    init(
        childRoles: [SubagentRole],
        makeChild: @escaping @Sendable (any RoutedSession) async throws -> any RoutedSession = {
            try SubagentRelayBox.subagentChild(of: $0)
        }
    ) {
        state = Mutex(State(childRoles: childRoles))
        self.makeChild = makeChild
    }

    /// Makes a subagent session of `parent`: a new session of the model of
    /// `parent`, with the tools and the user presence of `parent`. The
    /// parent call of the child is the current tool call
    /// (``ToolContext/current``), which is the relaying run.
    ///
    /// - Parameter parent: The session of the relaying run.
    /// - Returns: The child.
    /// - Throws: When `parent` is not a ``RoutedSessionActor``.
    static func subagentChild(of parent: any RoutedSession) throws -> any RoutedSession {
        let parent = try #require(parent as? RoutedSessionActor)
        return parent.profile.standard.makeSession(
            configuration: SessionConfiguration(
                tools: parent.originalTools, userPresence: parent.runPlane.userPresence,
                parentCall: ToolContext.current))
    }

    /// Records `session` with `role`.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - role: What the tool does in the session.
    func adopt(_ session: any RoutedSession, as role: SubagentRole) {
        change { state in
            state.roles[session.id] = role
            state.sessions[session.id] = session
        }
    }

    /// The role of the session `id`, or `nil` for a session with no role.
    ///
    /// - Parameter id: The id of a session.
    /// - Returns: The role.
    func role(of id: ULID) -> SubagentRole? {
        state.withLock { $0.roles[id] }
    }

    /// Makes the next child of `parent`, gives it the next role, and opens
    /// a feed of it before its first mail.
    ///
    /// - Parameter parentID: The id of the session of the relaying run.
    /// - Returns: The child.
    /// - Throws: When the box knows no such session, or when the child
    ///   maker throws.
    func makeNextChild(of parentID: ULID) async throws -> any RoutedSession {
        let parent = try #require(state.withLock { $0.sessions[parentID] })
        let child = try await makeChild(parent)
        let feed = await child.streamSessionEvents()
        change { state in
            let role = state.childRoles.removeFirst()
            state.roles[child.id] = role
            state.sessions[child.id] = child
            state.children.append(Child(session: child, feed: feed))
        }
        return child
    }

    /// Records the target of a relaying run.
    ///
    /// - Parameter target: The target.
    func noteTarget(_ target: SubagentQuestionTarget) {
        change { $0.targets.append(target) }
    }

    /// Records the context of an asking run.
    ///
    /// - Parameter context: The context.
    func noteAskContext(_ context: ToolContext) {
        change { $0.askContexts.append(context) }
    }

    /// Records the answer that an asking run got.
    ///
    /// - Parameter answer: The answer.
    func noteAnswer(_ answer: ElicitationResponse) {
        change { $0.answers.append(answer) }
    }

    /// Records that ``SubagentQuestionRelay/finish()`` of a relay returned.
    func noteRelayFinished() {
        change { $0.finishedRelays += 1 }
    }

    /// Records that a relaying run ended, also with an error.
    func noteRelayEnded() {
        change { $0.endedRelays += 1 }
    }

    /// Records that an asking run ended, also with an error.
    func noteAskEnded() {
        change { $0.endedAsks += 1 }
    }

    /// The session `id`, as the box recorded it.
    ///
    /// - Parameter id: The id of a session.
    /// - Returns: The session, or `nil`.
    func session(of id: ULID) -> (any RoutedSession)? {
        state.withLock { $0.sessions[id] }
    }

    /// The children so far, in order.
    var children: [Child] { state.withLock { $0.children } }

    /// The answers so far, in order.
    var answers: [ElicitationResponse] { state.withLock { $0.answers } }

    /// The contexts of the asking runs so far, in order.
    var askContexts: [ToolContext] { state.withLock { $0.askContexts } }

    /// The targets of the relaying runs so far, in order.
    var targets: [SubagentQuestionTarget] { state.withLock { $0.targets } }

    /// Waits until at least `count` children exist. The wait also ends when
    /// a relaying run ended (rule T1): that run makes no more children, and
    /// in a test that passes no relaying run ends before its children exist.
    ///
    /// - Parameter count: The count to wait for.
    /// - Returns: The children.
    /// - Throws: The error of `#require` when a relaying run ended first, or
    ///   ``ConditionNeverHeld`` when the test was cancelled first.
    func waitForChildren(_ count: Int) async throws -> [Child] {
        try await waitUntil(atLeast: count, of: { children }, counted: \.count, endingOn: { endedRelays > 0 })
    }

    /// The count of the relays whose ``SubagentQuestionRelay/finish()``
    /// returned so far.
    var finishedRelays: Int { state.withLock { $0.finishedRelays } }

    /// The count of the relaying runs that ended so far.
    private var endedRelays: Int { state.withLock { $0.endedRelays } }

    /// The count of the asking runs that ended so far.
    private var endedAsks: Int { state.withLock { $0.endedAsks } }

    /// Waits until the ``SubagentQuestionRelay/finish()`` of at least `count`
    /// relays returned. The wait also ends when `count` relaying runs ended
    /// (rule T1): a relaying run records the finish of its relay before it
    /// ends.
    ///
    /// - Parameter count: The count to wait for.
    /// - Returns: The count of the relays that finished.
    /// - Throws: The error of `#require` when the relaying runs ended first,
    ///   or ``ConditionNeverHeld`` when the test was cancelled first.
    func waitForFinishedRelays(_ count: Int) async throws -> Int {
        try await waitUntil(atLeast: count, of: { finishedRelays }, counted: { $0 }, endingOn: { endedRelays >= count })
    }

    /// Waits until at least `count` asking runs got an answer. The wait also
    /// ends when `count` asking runs ended (rule T1): an asking run records
    /// its answer before it ends.
    ///
    /// - Parameter count: The count to wait for.
    /// - Returns: The answers.
    /// - Throws: The error of `#require` when the asking runs ended first, or
    ///   ``ConditionNeverHeld`` when the test was cancelled first.
    func waitForAnswers(_ count: Int) async throws -> [ElicitationResponse] {
        try await waitUntil(atLeast: count, of: { answers }, counted: \.count, endingOn: { endedAsks >= count })
    }

    /// The one wait of the box for a count: waits until the count of a field
    /// is at least `count`, or until the failure event came (rule T1), and
    /// then reads the field again.
    ///
    /// - Parameters:
    ///   - count: The count to wait for.
    ///   - read: Reads the field.
    ///   - counted: Gives the count of a value of the field.
    ///   - failureEvent: Tells whether the event came that ends the wait
    ///     also when the count never comes.
    /// - Returns: The field, read after the wait.
    /// - Throws: The error of `#require` when the failure event came first,
    ///   or ``ConditionNeverHeld`` when the test was cancelled first.
    private func waitUntil<Value>(
        atLeast count: Int, of read: () -> Value, counted: (Value) -> Int, endingOn failureEvent: () -> Bool
    ) async throws -> Value {
        try await changes.wait(until: { counted(read()) >= count }, endingOn: failureEvent)
        return read()
    }

    /// Changes the fields under the lock, and then signals ``changes``.
    ///
    /// - Parameter change: The change.
    private func change(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
        changes.signal()
    }
}

/// The one background tool of the relay tests. Its run does what the role
/// of its session says (``SubagentRelayBox/role(of:)``): it relays the
/// questions of a child, or it asks the user one question. A session with no
/// role does nothing.
struct SubagentJobTool: Tool, BackgroundTool {
    let name = Self.toolName
    let description = "test-only background tool that relays the questions of a child, or asks one"

    /// The name of the tool, which is also the source of each relayed
    /// question.
    static let toolName = "subagent_job"

    /// The message that a relaying run mails to its child.
    static let childPrompt = "do the sub task"

    /// The output of a run whose session has no role, or whose run has no
    /// target or no session in the box. A test never reads it.
    static let idleOutput = "nothing to do"

    /// The output of a relaying run.
    static let relayedOutput = "relayed"

    /// The box of the test.
    let box: SubagentRelayBox

    var mount: ToolMount? {
        ToolMount(mode: .background, timeout: nil)
    }

    /// No wait: each call answers with its pending envelope at once.
    var inlineSettleGrace: TimeInterval { 0 }

    func call(arguments: BackgroundFixtureArguments) async throws -> String {
        guard let context = ToolContext.current, let role = box.role(of: context.sessionID) else {
            return Self.idleOutput
        }
        switch role {
        case .relay(let step) where step.relaysThroughAMount:
            return try await context.mount(MountedRelay(job: self, step: step)).call(arguments: arguments)
        case .relay(let step):
            return try await relay(step, in: context)
        case .ask(let step):
            return try await ask(step, in: context)
        }
    }

    /// Makes a child, relays its questions, mails it one message, waits on
    /// the gate of `step` or for a cancel, and then on the close gate of
    /// `step` when it has one. Then it closes the child, waits for the end
    /// of the relay, and records that end in the box. The box also records
    /// the end of the run, also when the run throws.
    ///
    /// - Parameters:
    ///   - step: The relaying level.
    ///   - context: The context of the run.
    /// - Returns: ``relayedOutput``, or ``idleOutput`` when the run has no
    ///   target.
    /// - Throws: What the child maker or the mail throws.
    private func relay(_ step: SubagentRelayStep, in context: ToolContext) async throws -> String {
        defer { box.noteRelayEnded() }
        guard let target = SubagentQuestionTarget.current else { return Self.idleOutput }
        box.noteTarget(target)
        let child = try await box.makeNextChild(of: context.sessionID)
        let relay = await SubagentQuestionRelay.start(child: child, agentName: step.agentName, target: target)
        _ = try child.send(Self.childPrompt)
        await Self.waitUntilOpenOrCancelled(step.gate)
        await step.closeGate?.waitUntilOpen()
        await child.close()
        await relay?.finish()
        box.noteRelayFinished()
        return Self.relayedOutput
    }

    /// The synchronous tool that a relaying run mounts when its step
    /// ``SubagentRelayStep/relaysThroughAMount``. Its call relays in its own
    /// context, and the relaying run holds that call.
    private struct MountedRelay: Tool {
        let name = "subagent_mounted_relay"
        let description = "test-only synchronous tool that relays the questions of a child"

        /// The tool that mounts this tool.
        let job: SubagentJobTool

        /// The relaying level.
        let step: SubagentRelayStep

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            let context = try #require(ToolContext.current)
            return try await job.relay(step, in: context)
        }
    }

    /// Asks the user one question, records the answer in the box, and
    /// returns it. The box also records the end of the run, also when the
    /// run throws.
    ///
    /// - Parameters:
    ///   - step: The question.
    ///   - context: The context of the run.
    /// - Returns: The action of the answer.
    /// - Throws: What `ToolContext.elicit(_:)` throws.
    private func ask(_ step: SubagentAskStep, in context: ToolContext) async throws -> String {
        defer { box.noteAskEnded() }
        if let besideRun = step.besideRun, let session = box.session(of: context.sessionID) as? RoutedSessionActor {
            _ = await trackFakeRun(on: session.runPlane, latch: besideRun)
        }
        box.noteAskContext(context)
        let request =
            step.asksForURL
            ? ElicitationRequest(
                message: "Open the page", elicitationId: ULID.generate(), url: SessionWorkEventTests.approvalURL)
            : MountFixtures.proceedRequest()
        let answer = try await context.elicit(request)
        box.noteAnswer(answer)
        return "answered: \(answer.action.rawValue)"
    }

    /// Waits until `gate` opens, or until the calling task is cancelled. A
    /// cancel opens the gate, so the wait ends.
    ///
    /// - Parameter gate: The gate.
    private static func waitUntilOpenOrCancelled(_ gate: RunLatch) async {
        await withTaskCancellationHandler {
            await gate.waitUntilOpen()
        } onCancel: {
            Task { await gate.open() }
        }
    }
}

/// A root session with one ``SubagentJobTool``, and the box of the test.
struct SubagentRelayFixture: Sendable {
    /// The root session and its backend.
    let base: BackgroundingSessionFixture

    /// The box that the tool and the test share.
    let box: SubagentRelayBox

    /// The root session.
    var session: any RoutedSession { base.session }

    /// The prompt that starts the relaying run of the root.
    static let rootPrompt = "run the job"

    /// Makes a root session whose tool relays to `childRoles`.
    ///
    /// - Parameters:
    ///   - rootStep: The relaying level of the root session.
    ///   - childRoles: The role of each child, in the order the children
    ///     come.
    ///   - container: The container that vends the backends.
    ///   - userPresence: The user presence of the root session.
    ///   - makeChild: Makes each child from the session of the relaying
    ///     run. `nil` uses ``SubagentRelayBox/subagentChild(of:)``.
    ///   - recordingsDir: The durable transcripts root of the router, or
    ///     `nil` (the default) for a router that records only in memory.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    static func make(
        root rootStep: SubagentRelayStep,
        children childRoles: [SubagentRole],
        container: BackgroundingLLMContainer = BackgroundingLLMContainer(),
        userPresence: UserPresence = .interactive,
        makeChild: (@Sendable (any RoutedSession) async throws -> any RoutedSession)? = nil,
        recordingsDir: URL? = nil
    ) async throws -> Self {
        let box =
            makeChild.map { SubagentRelayBox(childRoles: childRoles, makeChild: $0) }
            ?? SubagentRelayBox(childRoles: childRoles)
        let base = try await BackgroundingSessionFixture.make(
            prefix: "SubagentQuestionRelayTests", tools: [SubagentJobTool(box: box)], container: container,
            userPresence: userPresence, recordingsDir: recordingsDir)
        box.adopt(base.session, as: .relay(rootStep))
        return Self(base: base, box: box)
    }

    /// The root session as its one concrete type.
    ///
    /// - Returns: The session actor.
    /// - Throws: When the session is not a ``RoutedSessionActor``.
    func sessionActor() throws -> RoutedSessionActor {
        try base.sessionActor()
    }

    /// Sends ``rootPrompt`` to the root, whose answer starts the relaying
    /// run.
    ///
    /// - Throws: What the respond throws.
    func start() async throws {
        _ = try await session.respond(to: Self.rootPrompt)
    }

    /// Ends the fixture: opens `gates`, closes the root session, and removes
    /// the directory. The close of the root closes each child through the
    /// relaying runs.
    ///
    /// - Parameter gates: The gates to open first.
    func end(opening gates: [RunLatch] = []) async {
        await base.end(opening: gates)
    }

    /// Runs `body`, and then ends the fixture (``end(opening:)``). The end
    /// comes also when `body` throws, so a failed test leaves no session open
    /// (rule T1).
    ///
    /// - Parameters:
    ///   - gates: The gates to open before the close.
    ///   - body: The body of the test.
    /// - Throws: What `body` throws, after the end.
    func runThenEnd(opening gates: [RunLatch] = [], _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await end(opening: gates)
            throw error
        }
        await end(opening: gates)
    }
}
