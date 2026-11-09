import Foundation

@testable import FoundationModelsRouter

/// A ``MetadataSource`` over another source that holds each metadata read of
/// one repo until a metadata read of a second repo has begun.
///
/// A resolve that sizes the two repos one after the other, the held repo
/// first, never begins the second read, so the held read never ends. A test
/// wraps its resolve in a ``BoundedWait``, which fails it then. A resolve that
/// sizes the two at the same time ends.
actor OverlapGatedMetadataSource: MetadataSource {
    /// The source that answers each read.
    private let base: any MetadataSource

    /// The repo whose metadata reads are held.
    private let heldRepo: String

    /// The repo whose first metadata read releases the held reads.
    private let releasingRepo: String

    /// Whether a metadata read of ``releasingRepo`` has begun.
    private var isReleased = false

    /// The held reads, resumed when a read of ``releasingRepo`` begins.
    private var heldReads: [CheckedContinuation<Void, Never>] = []

    /// Makes a source.
    ///
    /// - Parameters:
    ///   - base: The source that answers each read.
    ///   - heldRepo: The repo whose metadata reads wait.
    ///   - releasingRepo: The repo whose first metadata read ends the wait.
    init(base: any MetadataSource, holding heldRepo: String, until releasingRepo: String) {
        self.base = base
        self.heldRepo = heldRepo
        self.releasingRepo = releasingRepo
    }

    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
        if repo == releasingRepo {
            release()
        } else if repo == heldRepo, !isReleased {
            await withCheckedContinuation { heldReads.append($0) }
        }
        return try await base.fetchRawMetadata(repo: repo, revision: revision)
    }

    func fetchFileBytes(repo: String, revision: String?, path: String, range: Range<Int>) async throws -> Data {
        try await base.fetchFileBytes(repo: repo, revision: revision, path: path, range: range)
    }

    /// Marks the releasing read as begun, and resumes each held read.
    private func release() {
        isReleased = true
        let reads = heldReads
        heldReads = []
        reads.forEach { $0.resume() }
    }
}
