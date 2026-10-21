import FoundationModelsExtras

/// The open event streams of one ``RouterSessionDirectory``, and the one
/// place that gives an event to each of them (ROUTER-3).
///
/// The fan-out holds no lock of its own. The directory keeps it inside the
/// same lock as its live registry, so an event that the directory sends while
/// it changes the registry reaches each stream in the order of the changes:
/// `started` is the first event of a session on each stream, and the events
/// of one session stay in order.
struct SessionDirectoryEventFanout {
    /// The most events that one stream buffers. A slow reader loses the old
    /// events, not the new ones (session.md section 7, rule 1).
    static let bufferLimit = 256

    /// The continuation of each open stream, keyed by the id that ``add(_:)``
    /// gave it.
    private var continuations: [Int: AsyncStream<SessionDirectoryEvent>.Continuation] = [:]

    /// The id that the next ``add(_:)`` gives.
    private var nextStreamID = 0

    /// The number of open streams.
    var count: Int { continuations.count }

    /// Makes a new stream with the `.bufferingNewest(256)` policy.
    ///
    /// - Returns: The stream and its continuation. The caller adds the
    ///   continuation with ``add(_:)``.
    static func makeStream() -> (
        stream: AsyncStream<SessionDirectoryEvent>, continuation: AsyncStream<SessionDirectoryEvent>.Continuation
    ) {
        AsyncStream.makeStream(of: SessionDirectoryEvent.self, bufferingPolicy: .bufferingNewest(bufferLimit))
    }

    /// Adds the continuation of an open stream. It gets each event that
    /// ``send(_:)`` gives after this call.
    ///
    /// - Parameter continuation: The continuation of the stream.
    /// - Returns: The id that ``remove(_:)`` takes when the stream ends.
    mutating func add(_ continuation: AsyncStream<SessionDirectoryEvent>.Continuation) -> Int {
        let streamID = nextStreamID
        nextStreamID += 1
        continuations[streamID] = continuation
        return streamID
    }

    /// Removes the continuation of a stream that ended. An id the fan-out
    /// does not hold changes nothing.
    ///
    /// - Parameter streamID: The id that ``add(_:)`` gave.
    mutating func remove(_ streamID: Int) {
        continuations.removeValue(forKey: streamID)
    }

    /// Removes every open stream, for the directory to finish them.
    ///
    /// The caller finishes each continuation after it leaves the lock that
    /// keeps the fan-out: a finish runs the `onTermination` of its stream,
    /// and that handler takes the same lock to ``remove(_:)`` the stream.
    ///
    /// - Returns: The continuation of each stream that was open.
    mutating func removeAll() -> [AsyncStream<SessionDirectoryEvent>.Continuation] {
        let open = Array(continuations.values)
        continuations.removeAll()
        return open
    }

    /// Gives `event` to each open stream.
    ///
    /// - Parameter event: The event.
    func send(_ event: SessionDirectoryEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}
