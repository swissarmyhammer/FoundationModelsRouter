import FoundationModelsExtras

/// A source of the download size and the disk state of one model, with no
/// download and no model load.
///
/// ``ModelStorage`` of FoundationModelsExtras conforms: give it the cache
/// folder and the token provider of the loader of the models. A test gives a
/// source that reads no network.
public protocol ModelStorageSource: Sendable {
    /// Gives the download size and the disk state of one model. The MTP
    /// drafter of `ref` is not part of the result.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The information of the model.
    /// - Throws: The error of the read.
    func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo
}

extension ModelStorage: ModelStorageSource {}

extension ModelStorageSource {
    /// Gives the storage of a model and its MTP drafter together, for a slot
    /// model (``SlotModel/ref``) or a choice of a slot
    /// (``ProfileDefinition/choices(for:)``).
    ///
    /// The files of a model do not include its drafter, thus this reads the
    /// drafter as a reference of its own. The two reads run at the same time.
    /// Neither read downloads a model or loads a model.
    ///
    /// - Parameter ref: The model, with its drafter if it has one.
    /// - Returns: The storage of the model and its drafter.
    /// - Throws: The error of the read of the model or of the drafter.
    public func storageSummary(of ref: ModelRef) async throws -> ModelStorageSummary {
        async let model = storageInfo(of: ref)
        async let drafter = drafterInfo(of: ref)
        return try await ModelStorageSummary(model: model, drafter: drafter)
    }

    /// Gives the storage of the drafter of a model.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The information of the drafter, or `nil` for a model with
    ///   no drafter.
    /// - Throws: The error of the read of the drafter.
    private func drafterInfo(of ref: ModelRef) async throws -> ModelStorageInfo? {
        guard let drafter = ref.drafter else { return nil }
        return try await storageInfo(of: drafter)
    }
}

/// The storage of a model and its MTP drafter together, as one row of a
/// settings pane shows it: the download size, the bytes on the disk, the
/// combined disk state, and the GGUF file of the model.
///
/// ``ModelStorageSource/storageSummary(of:)`` gives one.
public struct ModelStorageSummary: Sendable, Equatable {
    /// The information of the model.
    public let model: ModelStorageInfo

    /// The information of the MTP drafter, or `nil` for a model with no
    /// drafter.
    public let drafter: ModelStorageInfo?

    /// The download size of the model and its drafter, in bytes, or `nil`
    /// when the size of one of them is not known.
    public let totalBytes: Int64?

    /// The bytes of the model and its drafter that the cache holds.
    public let presentBytes: Int64

    /// The bytes that the blobs of the model and its drafter use on the disk.
    public let diskBytes: Int64

    /// The disk state of the model and its drafter together:
    ///
    /// - ``ModelDiskState/complete`` when the model and the drafter are
    ///   complete.
    /// - ``ModelDiskState/missing`` when the model and the drafter are
    ///   missing.
    /// - Else ``ModelDiskState/partial(presentBytes:totalBytes:)`` with
    ///   ``presentBytes`` and ``totalBytes``.
    ///
    /// A model with no drafter has the state of the model.
    public let state: ModelDiskState

    /// Makes the storage of a model and its drafter from the information of
    /// each.
    ///
    /// - Parameters:
    ///   - model: The information of the model.
    ///   - drafter: The information of the drafter, or `nil` for a model with
    ///     no drafter.
    public init(model: ModelStorageInfo, drafter: ModelStorageInfo?) {
        self.model = model
        self.drafter = drafter
        let parts = [model] + (drafter.map { [$0] } ?? [])
        let totals = parts.compactMap(\.totalBytes)
        let total = totals.count == parts.count ? totals.reduce(0, +) : nil
        let present = parts.reduce(Int64(0)) { $0 + $1.presentBytes }
        totalBytes = total
        presentBytes = present
        diskBytes = parts.reduce(Int64(0)) { $0 + $1.diskBytes }
        state = Self.combinedState(of: parts, presentBytes: present, totalBytes: total)
    }

    /// The model, with its drafter when the read was given one.
    public var ref: ModelRef { model.ref }

    /// The GGUF file that llama.cpp loads for the model, from the files of
    /// the model, or `nil` for a model that is not GGUF. For a split set it
    /// is the first shard; the image projector is never the file. The files
    /// of a GGUF model hold one model, because the storage read selects them
    /// with ``GGUFFileSet``; files with no `.gguf` model give `nil`.
    public var ggufFile: String? {
        try? GGUFFileSet.select(from: model.files, under: model.ref.path).model
    }

    /// The disk state of the parts of a model together.
    ///
    /// - Parameters:
    ///   - parts: The information of the model and of its drafter.
    ///   - presentBytes: The bytes of the parts on the disk.
    ///   - totalBytes: The download size of the parts, or `nil`.
    /// - Returns: The state of the one part when there is one; else complete
    ///   when each part is complete, missing when each part is missing, and
    ///   partial in each other case.
    private static func combinedState(
        of parts: [ModelStorageInfo], presentBytes: Int64, totalBytes: Int64?
    ) -> ModelDiskState {
        if parts.count == 1, let only = parts.first { return only.state }
        if parts.allSatisfy({ $0.state == .complete }) { return .complete }
        if parts.allSatisfy({ $0.state == .missing }) { return .missing }
        return .partial(presentBytes: presentBytes, totalBytes: totalBytes)
    }
}
