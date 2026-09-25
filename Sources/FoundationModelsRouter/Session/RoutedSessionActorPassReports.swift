/// ``RoutedSessionActor``'s side of the pass reports (task ^ake8sax,
/// `generation-queue.md`, section 2).
///
/// The per-session ``QueuedLanguageModel`` of the backend reports each pass to
/// ``RoutedSessionActor/generationPassObserver``. The session turns each
/// reported ``GenerationPassPhase`` into its own state: the stall watch of the
/// model call in flight counts only the time a pass holds its queue place, and
/// a pass that waits for its place is told to the consumer as
/// ``SessionEvent/passQueued`` and ``SessionEvent/passStarted``.
extension RoutedSessionActor {
    /// Installs this session's pass observer on `backend`, when `backend`
    /// reports its passes. The initializer and each replacement of
    /// ``backend`` call it, so every backend of this session reports to the
    /// same observer.
    ///
    /// - Parameter backend: The backend this session runs through from now on.
    nonisolated func observeGenerationPasses(of backend: any LanguageModelSessionBackend) {
        (backend as? any GenerationPassReporting)?.reportPasses(to: generationPassObserver)
    }

    /// Starts to read the pass reports of the model call `callID`: each report
    /// wakes a task that applies the reported phases on this actor.
    ///
    /// - Parameter callID: The id of the model call, the id of its stall watch.
    /// - Returns: The task that reads the reports. Give it to
    ///   ``closeGenerationPassReports(callID:reader:)`` when the call ends.
    func openGenerationPassReports(callID: UInt64) -> Task<Void, Never> {
        let wakes = generationPassObserver.openWakes(callID: callID)
        return Task {
            for await _ in wakes {
                self.drainGenerationPassPhases()
            }
        }
    }

    /// Stops reading the pass reports of the model call `callID`, and applies
    /// the phases the reader did not apply yet. The call ended, so each of its
    /// passes has reported already, and the events reach the turn before the
    /// turn ends.
    ///
    /// - Parameters:
    ///   - callID: The id of the model call that ended.
    ///   - reader: The task ``openGenerationPassReports(callID:)`` gave.
    func closeGenerationPassReports(callID: UInt64, reader: Task<Void, Never>) {
        reader.cancel()
        generationPassObserver.closeWakes(callID: callID)
        drainGenerationPassPhases()
    }

    /// Applies each reported phase not yet applied, in the order of the
    /// reports: to the stall watch of the model call in flight, and as an
    /// event to the consumer when the phase has one
    /// (``GenerationPassPhase/sessionEvent``).
    func drainGenerationPassPhases() {
        for phase in generationPassObserver.takePhases() {
            generationStallWatch?.apply(phase)
            if let event = phase.sessionEvent {
                deliverLive(event)
            }
        }
    }
}
