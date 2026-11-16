import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds the API of the Models pane of a host to the access level that the
/// host needs: the model of each slot of a profile, the choices of a slot,
/// and the storage of a model with its drafter. A host calls it before it
/// resolves a profile and before a download.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("Model choices over a plain import")
struct ModelChoicesPublicSurfaceTests {
    /// A profile with one candidate in each slot.
    static let profile = ProfileDefinition(
        name: "coder",
        description: "coding profile",
        standard: [ModelRef(repo: "org/target-4bit", drafter: "org/target-MTP-4bit")],
        flash: ["org/flash"],
        embedding: ["org/embedding"]
    )

    @Test("a host reads the drafter of the model of a slot")
    func hostReadsTheSlotModel() throws {
        let slotModel = try #require(Self.profile.slotModel(for: .standard))

        #expect(slotModel.drafter == "org/target-MTP-4bit")
    }

    @Test("a host reads the choices of a slot")
    func hostReadsTheChoices() {
        #expect(Self.profile.choices(for: .flash).first == "org/flash")
    }

    @Test("a host reads the combined disk state of a model and its drafter")
    func hostReadsTheCombinedStorage() {
        let model = ModelStorageInfo(
            ref: "org/target-4bit", revision: nil, files: [], totalBytes: nil, presentBytes: 0, diskBytes: 0,
            state: .missing)

        let summary = ModelStorageSummary(model: model, drafter: nil)

        #expect(summary.state == .missing)
    }
}
