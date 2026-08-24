@testable import FoundationModelsRouter

/// An ``OperationEventSink`` that drops every posted event — the sink a suite
/// binds when it observes the run plane, the mailbox, or a resumed
/// continuation rather than the outbound event chain.
///
/// This is the one discarding sink the test target declares, so the suites
/// that need it cannot drift copy from copy.
struct DiscardingOperationEventSink: OperationEventSink {
  /// Drops `event`.
  ///
  /// - Parameter event: The event this sink discards.
  func post(event: OperationEvent) async {}
}
