import FoundationModelsHooks

@testable import FoundationModelsRouter

/// A test fixture that holds a session of a router with a hook dispatcher.
///
/// A hook test reads its post events only after the dispatcher delivered
/// them, because a post event arrives on a task of the dispatcher. The
/// suites of the hook tests use ``closeAndDrain()`` for this step.
protocol HookedSessionFixture {
    /// The session under test.
    var session: any RoutedSession { get }

    /// The dispatcher of the router of ``session``.
    var dispatcher: HookDispatcher { get }
}

extension HookedSessionFixture {
    /// Closes the session, and waits until the dispatcher delivered each
    /// post event.
    func closeAndDrain() async {
        await session.close()
        await dispatcher.drain()
    }
}
