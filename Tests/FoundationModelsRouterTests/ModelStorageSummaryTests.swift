import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Tests for ``ModelStorageSummary``: the storage of a model and its MTP
/// drafter together. A fake ``ModelStorageSource`` gives the information of
/// each model, and one test reads a local folder through ``ModelStorage``.
/// No test reads the network or loads a model.
@Suite("Model storage summary")
struct ModelStorageSummaryTests {
    /// The target model of the tests.
    static let modelRef: ModelRef = "org/target-4bit"

    /// The MTP drafter of the target model.
    static let drafterRef: ModelRef = "org/target-MTP-4bit"

    /// The target model with its drafter.
    static let pairRef = ModelRef(repo: "org/target-4bit", drafter: "org/target-MTP-4bit")

    /// The download size of the target model, in bytes.
    static let modelBytes: Int64 = 1_000

    /// The download size of the drafter, in bytes.
    static let drafterBytes: Int64 = 30

    /// The bytes of a partial download that are on the disk.
    static let partialBytes: Int64 = 400

    /// The error of the fake storage for a model that it does not know.
    struct UnknownModel: Error, Equatable {
        /// The text of the model.
        let ref: String
    }

    /// A storage that gives fixed information for each model, with no read
    /// of the disk or the network.
    struct FakeStorage: ModelStorageSource {
        /// The information of each model, by the text of its reference.
        let infos: [String: ModelStorageInfo]

        /// Gives the information of `ref`.
        ///
        /// - Parameter ref: The model.
        /// - Returns: The fixed information of the model.
        /// - Throws: ``UnknownModel`` for a model with no information.
        func storageInfo(of ref: ModelRef) async throws -> ModelStorageInfo {
            guard let info = infos[ref.stringValue] else { throw UnknownModel(ref: ref.stringValue) }
            return info
        }
    }

    /// Makes the information of one model.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - state: The disk state.
    ///   - totalBytes: The download size, or `nil` when it is not known.
    ///   - files: The files of the model.
    /// - Returns: The information. The bytes on the disk follow from the state.
    static func info(
        _ ref: ModelRef, _ state: ModelDiskState, totalBytes: Int64?, files: [String] = []
    ) -> ModelStorageInfo {
        let present: Int64 =
            switch state {
            case .complete: totalBytes ?? 0
            case .partial(let presentBytes, _): presentBytes
            case .missing: 0
            }
        return ModelStorageInfo(
            ref: ref, revision: nil, files: files, totalBytes: totalBytes, presentBytes: present,
            diskBytes: present, state: state)
    }

    /// The information of the target model in a state.
    static func model(_ state: ModelDiskState) -> ModelStorageInfo {
        info(modelRef, state, totalBytes: modelBytes)
    }

    /// The information of the drafter in a state.
    static func drafter(_ state: ModelDiskState) -> ModelStorageInfo {
        info(drafterRef, state, totalBytes: drafterBytes)
    }

    /// A partial state of the target model.
    static let modelPartial = ModelDiskState.partial(presentBytes: partialBytes, totalBytes: modelBytes)

    // MARK: - The combined state

    @Test("A model with no drafter has the state of the model")
    func noDrafterKeepsTheModelState() {
        let summary = ModelStorageSummary(model: Self.model(Self.modelPartial), drafter: nil)

        #expect(summary.state == Self.modelPartial)
    }

    @Test("The state is complete when the model and the drafter are complete")
    func bothCompleteIsComplete() {
        let summary = ModelStorageSummary(model: Self.model(.complete), drafter: Self.drafter(.complete))

        #expect(summary.state == .complete)
    }

    @Test("The state is missing when the model and the drafter are missing")
    func bothMissingIsMissing() {
        let summary = ModelStorageSummary(model: Self.model(.missing), drafter: Self.drafter(.missing))

        #expect(summary.state == .missing)
    }

    @Test("The state is partial when the model is complete and the drafter is missing")
    func completeAndMissingIsPartial() {
        let summary = ModelStorageSummary(model: Self.model(.complete), drafter: Self.drafter(.missing))

        #expect(summary.state == .partial(presentBytes: Self.modelBytes, totalBytes: Self.modelBytes + Self.drafterBytes))
    }

    @Test("The state is partial when the model is missing and the drafter is complete")
    func missingAndCompleteIsPartial() {
        let summary = ModelStorageSummary(model: Self.model(.missing), drafter: Self.drafter(.complete))

        #expect(summary.state == .partial(presentBytes: Self.drafterBytes, totalBytes: Self.modelBytes + Self.drafterBytes))
    }

    @Test("The state is partial when the model is partial and the drafter is complete")
    func partialAndCompleteIsPartial() {
        let summary = ModelStorageSummary(model: Self.model(Self.modelPartial), drafter: Self.drafter(.complete))

        #expect(
            summary.state
                == .partial(
                    presentBytes: Self.partialBytes + Self.drafterBytes,
                    totalBytes: Self.modelBytes + Self.drafterBytes))
    }

    // MARK: - The bytes

    @Test("The download size is the sum of the model and the drafter")
    func totalBytesIsTheSum() {
        let summary = ModelStorageSummary(model: Self.model(.missing), drafter: Self.drafter(.missing))

        #expect(summary.totalBytes == Self.modelBytes + Self.drafterBytes)
    }

    @Test("The download size is unknown when the size of the drafter is unknown")
    func totalBytesIsNilWhenTheDrafterSizeIsUnknown() {
        let drafter = Self.info(Self.drafterRef, .missing, totalBytes: nil)

        let summary = ModelStorageSummary(model: Self.model(.complete), drafter: drafter)

        #expect(summary.totalBytes == nil)
    }

    @Test("The download size is unknown when the size of the model is unknown")
    func totalBytesIsNilWhenTheModelSizeIsUnknown() {
        let model = Self.info(Self.modelRef, .missing, totalBytes: nil)

        let summary = ModelStorageSummary(model: model, drafter: Self.drafter(.complete))

        #expect(summary.totalBytes == nil)
    }

    @Test("The bytes on the disk are the sum of the model and the drafter")
    func presentBytesIsTheSum() {
        let summary = ModelStorageSummary(model: Self.model(Self.modelPartial), drafter: Self.drafter(.complete))

        #expect(summary.presentBytes == Self.partialBytes + Self.drafterBytes)
    }

    @Test("The bytes that the blobs use are the sum of the model and the drafter")
    func diskBytesIsTheSum() {
        let summary = ModelStorageSummary(model: Self.model(Self.modelPartial), drafter: Self.drafter(.complete))

        #expect(summary.diskBytes == Self.partialBytes + Self.drafterBytes)
    }

    // MARK: - The GGUF file

    @Test("The GGUF file is the model file of the files, and not the projector")
    func ggufFileIsTheModelFile() {
        let files = ["Q4_K_M/model-Q4_K_M.gguf", "mmproj-F16.gguf"]
        let model = Self.info("org/model-GGUF/Q4_K_M", .missing, totalBytes: Self.modelBytes, files: files)

        #expect(ModelStorageSummary(model: model, drafter: nil).ggufFile == "Q4_K_M/model-Q4_K_M.gguf")
    }

    @Test("A model with no GGUF file has no GGUF file")
    func ggufFileOfAnMLXModel() {
        let files = ["config.json", "model.safetensors", "tokenizer.json"]
        let model = Self.info(Self.modelRef, .missing, totalBytes: Self.modelBytes, files: files)

        #expect(ModelStorageSummary(model: model, drafter: nil).ggufFile == nil)
    }

    // MARK: - The read through a storage source

    @Test("A summary reads the drafter as a reference of its own")
    func summaryReadsTheDrafter() async throws {
        let storage = FakeStorage(infos: [
            Self.modelRef.stringValue: Self.model(.complete),
            Self.drafterRef.stringValue: Self.drafter(.complete),
        ])

        let summary = try await storage.storageSummary(of: Self.pairRef)

        #expect(summary.drafter?.ref == Self.drafterRef)
    }

    @Test("A summary of a model with no drafter reads no drafter")
    func summaryOfAModelWithNoDrafter() async throws {
        let storage = FakeStorage(infos: [Self.modelRef.stringValue: Self.model(.complete)])

        let summary = try await storage.storageSummary(of: Self.modelRef)

        #expect(summary.drafter == nil)
    }

    @Test("A summary throws the error of the read of the drafter")
    func summaryThrowsTheDrafterError() async {
        let storage = FakeStorage(infos: [Self.modelRef.stringValue: Self.model(.complete)])

        await #expect(throws: UnknownModel(ref: Self.drafterRef.stringValue)) {
            try await storage.storageSummary(of: Self.pairRef)
        }
    }

    @Test("ModelStorage gives the summary of a local model and its local drafter")
    func modelStorageReadsALocalPair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStorageSummaryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let modelFolder = root.appendingPathComponent("model", isDirectory: true)
        let drafterFolder = root.appendingPathComponent("drafter", isDirectory: true)
        try Self.writeFile(of: Self.modelBytes, in: modelFolder)
        try Self.writeFile(of: Self.drafterBytes, in: drafterFolder)
        let ref = ModelRef(repo: modelFolder.path, drafter: ModelRef(repo: drafterFolder.path))

        let summary = try await ModelStorage(cacheDirectory: root).storageSummary(of: ref)

        #expect(summary.totalBytes == Self.modelBytes + Self.drafterBytes)
    }

    /// Writes one file of `byteCount` bytes in a new folder.
    ///
    /// - Parameters:
    ///   - byteCount: The size of the file.
    ///   - folder: The folder to make.
    /// - Throws: The error of the write.
    static func writeFile(of byteCount: Int64, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: Int(byteCount)).write(to: folder.appendingPathComponent("model.safetensors"))
    }
}
