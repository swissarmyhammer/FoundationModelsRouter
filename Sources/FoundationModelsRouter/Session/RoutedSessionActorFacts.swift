import Foundation

/// The mutable facts of a session (ROUTER-1): its agent, tags, title, who
/// started it, how it started, and when it was archived. The session holds
/// them in ``RoutedSessionActor/factsState`` and keeps `facts.json` equal to
/// them.
extension RoutedSessionActor {
    /// See ``RoutedSession/facts``.
    nonisolated var facts: SessionFacts {
        factsState.withLock { $0 }
    }

    /// Changes the facts of this session: applies `change` to a copy of the
    /// facts, rewrites `facts.json` atomically with the result, and only then
    /// swaps the held value. The lock is held across the write, so two
    /// changes never interleave and the file and ``facts`` never disagree. A
    /// session that records nothing durably (``SessionSidecarOrigin/recordsFacts``)
    /// swaps the value and writes no file. `session.json` is never touched.
    ///
    /// - Parameter change: The change to apply to the facts.
    /// - Returns: The new facts.
    /// - Throws: The encode or file-system error of the rewrite. The held
    ///   facts do not change when the rewrite throws.
    @discardableResult
    nonisolated func updateFacts(_ change: (inout SessionFacts) -> Void) throws -> SessionFacts {
        try factsState.withLock { current in
            var next = current
            change(&next)
            if sidecarOrigin.recordsFacts {
                try next.write(to: recordingDirectory)
            }
            current = next
            return next
        }
    }
}
