import Synchronization

/// Awaits work that cannot itself be cancelled, without making the caller wait
/// for it.
///
/// A model load runs inside an unstructured task the MLX model cache owns, so
/// it takes no cancellation from the resolve that started it, and awaiting its
/// value does not throw when the awaiting task is cancelled. A `Ctrl-C` during a
/// download therefore had no effect at all: the user watched the transfer run to
/// its end. ``value(_:)`` is the bridge — the caller stops waiting the moment it
/// is cancelled, and the work runs on.
///
/// Leaving the work running is deliberate, not a leak. The Hugging Face client
/// writes each blob into an `<etag>.incomplete` part file and resumes it with a
/// `Range` header, and the model cache coalesces a later load of the same model
/// onto the one already in flight. So a resolve the user cancels leaves the part
/// files behind and a later resolve continues that same transfer instead of
/// starting it again.
package enum CancellableWait {
    /// Runs `work` and awaits it, giving up the wait when the calling task is
    /// cancelled.
    ///
    /// - Parameter work: The work to run. It is never cancelled, and it runs to
    ///   completion whether or not the caller waits for it.
    /// - Returns: Whatever `work` returns.
    /// - Throws: `CancellationError` when the calling task is cancelled before
    ///   `work` returns, or whatever `work` throws.
    package static func value<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()

        let outcome = Mutex<Result<T, any Error>?>(nil)
        let completion = AsyncSemaphore(value: 0)
        // Deliberately unstructured, and deliberately never cancelled: the doc
        // comment above states why the work must outlive an abandoned wait.
        Task {
            let result: Result<T, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
            completion.signal()
        }

        try await completion.waitUnlessCancelled()
        guard let result = outcome.withLock({ $0 }) else {
            preconditionFailure("the completion signal is sent after the outcome is written")
        }
        return try result.get()
    }
}
