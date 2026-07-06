import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises ``LiveModelLoader``'s Foundation `Progress` → ``DownloadProgress``
/// adapter in isolation — no network, no GPU.
///
/// The concrete Hub downloader the integration wiring injects reports a
/// byte-weighted parent `Progress` with per-file children. Foundation only
/// aggregates such a parent through `fractionCompleted`; its `completedUnitCount`
/// stays `0` until every child finishes and then jumps to the total. So the
/// adapter must derive the incremental byte count from `fractionCompleted`, or a
/// multi-GB download would read `0` all the way and then leap to 100%.
@Suite("LiveModelLoader progress adapter")
struct LiveModelLoaderTests {
    /// A thread-safe sink for the ``DownloadProgress`` values the adapter emits,
    /// so the `@Sendable` handler closure can record synchronously.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DownloadProgress] = []

        func record(_ dp: DownloadProgress) {
            lock.lock()
            values.append(dp)
            lock.unlock()
        }

        var last: DownloadProgress? {
            lock.lock()
            defer { lock.unlock() }
            return values.last
        }
    }

    /// Builds a byte-weighted parent `Progress` with two children whose unit
    /// weights are byte sizes — the exact shape the Hub snapshot downloader
    /// produces — and returns the parent plus its children.
    private func byteWeightedProgress() -> (parent: Progress, small: Progress, large: Progress) {
        let parent = Progress(totalUnitCount: 8 << 30)
        let small = Progress(totalUnitCount: 3 << 30, parent: parent, pendingUnitCount: 3 << 30)
        let large = Progress(totalUnitCount: 5 << 30, parent: parent, pendingUnitCount: 5 << 30)
        return (parent, small, large)
    }

    @Test("handler surfaces byte-accurate incremental progress, not a single 0 → 100 jump")
    func handlerMapsIncrementalBytes() throws {
        let sink = Sink()
        // `LiveModelLoader.handler(reporting:)` is `private` — it's just
        // `@Sendable`-closure plumbing over `mapProgress(_:)` for `loadLLM`'s
        // progress forwarding. `mapProgress(_:)` holds the actual byte-mapping
        // logic under test here, and stays at the default (module-internal)
        // access level for exactly this: `@testable import` gives this test
        // direct access to it, no network, no GPU.
        let handler: (Progress) -> Void = { sink.record(LiveModelLoader.mapProgress($0)) }
        let (parent, small, large) = byteWeightedProgress()
        let total: Int64 = 8 << 30
        let threeGB: Int64 = 3 << 30
        let fiveGB: Int64 = 5 << 30

        // Nothing downloaded yet: total known, zero bytes in.
        handler(parent)
        var dp = try #require(sink.last)
        #expect(dp.bytesTotal == total)
        #expect(dp.bytesDownloaded == 0)

        // 3 GB of the 8 GB in: a real, mid-download percentage — NOT still 0.
        small.completedUnitCount = small.totalUnitCount
        handler(parent)
        dp = try #require(sink.last)
        #expect(dp.bytesTotal == total)
        #expect(dp.bytesDownloaded == threeGB)

        // 5.5 GB in (the large file half done): still incremental, not stuck at 3 GB.
        large.completedUnitCount = large.totalUnitCount / 2
        handler(parent)
        dp = try #require(sink.last)
        #expect(dp.bytesDownloaded == threeGB + fiveGB / 2)

        // Everything downloaded: the count reaches the full total.
        large.completedUnitCount = large.totalUnitCount
        handler(parent)
        dp = try #require(sink.last)
        #expect(dp.bytesTotal == total)
        #expect(dp.bytesDownloaded == total)
    }
}
