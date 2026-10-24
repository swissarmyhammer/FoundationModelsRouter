/// ``RoutedSessionActor``'s side of the phase reports of its model calls
/// (tasks ^ake8sax and ^1psqdm9).
///
/// The per-session ``SessionLanguageModel`` of the backend reports the start,
/// the first output and the end of each pass to
/// ``RoutedSessionActor/generationPassObserver``, and each submission reports
/// its start there. The session turns each reported ``GenerationCallPhase``
/// into its own state: the stall watch of the model call in flight counts
/// only the time from the first output of a pass to its end, and the ledger
/// of the generation calls times each call. The start of each submission
/// reaches the consumer as ``SessionEvent/submissionStarted(_:)`` through
/// `submissionDidStart()`, which applies the reported phases first.
extension RoutedSessionActor {
    /// Installs this session's pass observer on `backend`, when `backend`
    /// reports its passes. ``adopt(_:)`` calls it for the first backend and
    /// for each replacement of ``backend``, so every backend of this session
    /// reports to the same observer.
    ///
    /// - Parameter backend: The backend this session runs through from now on.
    nonisolated func observeGenerationPasses(of backend: any LanguageModelSessionBackend) {
        (backend as? any GenerationPassReporting)?.reportPasses(to: generationPassObserver)
    }

    /// Starts to read the phase reports of the model call `callID`: each
    /// report wakes a task that applies the reported phases on this actor.
    ///
    /// The task is a helper task (``helperTasks``), so the drain of
    /// ``close()`` waits until it ended.
    ///
    /// - Parameter callID: The id of the model call, the id of its stall watch.
    /// - Returns: The task that reads the reports. Give it to
    ///   ``closeGenerationPassReports(callID:reader:)`` when the call ends.
    func openGenerationPassReports(callID: UInt64) -> Task<Void, Never> {
        let wakes = generationPassObserver.openWakes(callID: callID)
        return helperTasks.start {
            for await _ in wakes {
                await self.drainGenerationPassPhases()
            }
        }
    }

    /// Stops reading the phase reports of the model call `callID`, and applies
    /// the phases the reader did not apply yet. The call ended, so its
    /// submission and each of its passes have reported already, and the
    /// events reach the answer before the submission ends.
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
    /// reports: to the stall watch of the model call in flight, and to the
    /// ledger of the generation calls of the attempt (the times of each
    /// call, ``GenerationCallLedger/apply(_:)``).
    func drainGenerationPassPhases() {
        for phase in generationPassObserver.takePhases() {
            generationStallWatch?.apply(phase)
            generationCallLedger?.apply(phase)
        }
    }
}
