/// ``RoutedSessionActor``'s side of the phase reports of its model calls
/// (tasks ^ake8sax and ^1psqdm9, `generation-queue.md`, section 5.6).
///
/// The per-session ``SessionLanguageModel`` of the backend reports the start
/// and the end of each pass to ``RoutedSessionActor/generationPassObserver``,
/// and each submission reports its wait for the worker and its start there.
/// The session turns each reported ``GenerationCallPhase`` into its own state:
/// the stall watch of the model call in flight counts only the time inside a
/// pass of the running submission, and the consumer sees the wait and the
/// start of each submission as ``SessionEvent/submissionQueued`` and
/// ``SessionEvent/submissionStarted``.
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

    /// Starts to read the phase reports of the model call `callID`: each
    /// report wakes a task that applies the reported phases on this actor.
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

    /// Stops reading the phase reports of the model call `callID`, and applies
    /// the phases the reader did not apply yet. The call ended, so its
    /// submission and each of its passes have reported already, and the
    /// events reach the turn before the turn ends.
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
    /// (``GenerationCallPhase/sessionEvent``).
    func drainGenerationPassPhases() {
        for phase in generationPassObserver.takePhases() {
            generationStallWatch?.apply(phase)
            if let event = phase.sessionEvent {
                deliverLive(event)
            }
        }
    }
}
