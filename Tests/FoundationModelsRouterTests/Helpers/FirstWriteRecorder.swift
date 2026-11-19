import Foundation

@testable import FoundationModelsRouter

/// A recorder that changes the first session write that it gets, and gives
/// each other append to an inner recorder unchanged.
///
/// The first write is the appends to the first folder that the recorder
/// sees. A ``Mode/held`` recorder opens ``entered`` at the first append of
/// that write, and then waits until ``release`` opens before it gives that
/// append and the next ones to the inner recorder. A ``Mode/dropped``
/// recorder keeps none of the appends of the first write, so that write
/// fails (``RoutedModel/recordSession(from:configuration:)`` reads back no
/// transcript). The tests of the import names
/// (``RouterSessionDirectory/importSession(_:transcript:)``) use it to put
/// two imports in a fixed order, with no wait on a clock.
actor FirstWriteRecorder: TranscriptRecorder {
    /// What the recorder does with the first write.
    enum Mode: Sendable {
        /// The first write waits until ``release`` opens.
        case held

        /// The first write keeps no event.
        case dropped
    }

    /// The recorder that keeps each event that this recorder gives on.
    private let inner: any TranscriptRecorder

    /// What the recorder does with the first write.
    private let mode: Mode

    /// The folder of the first write, or `nil` before the first append.
    private var firstFolder: URL?

    /// Opens at the first append of the first write.
    nonisolated let entered = RunLatch()

    /// The first write of a ``Mode/held`` recorder waits until this opens.
    nonisolated let release = RunLatch()

    /// Makes a recorder over `inner`.
    ///
    /// - Parameters:
    ///   - inner: The recorder that keeps each event that this recorder
    ///     gives on.
    ///   - mode: What the recorder does with the first write.
    init(inner: any TranscriptRecorder, mode: Mode) {
        self.inner = inner
        self.mode = mode
    }

    /// Gives the event to the inner recorder, after the gate of the first
    /// write, or drops it.
    ///
    /// - Parameters:
    ///   - partial: The event to record.
    ///   - directory: The session folder of the event.
    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        if firstFolder == nil {
            firstFolder = directory
        }
        guard directory == firstFolder else {
            await inner.append(partial, to: directory)
            return
        }
        switch mode {
        case .dropped:
            return
        case .held:
            await entered.open()
            await release.waitUntilOpen()
            await inner.append(partial, to: directory)
        }
    }
}
