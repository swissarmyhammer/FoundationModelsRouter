import Foundation
import FoundationModelsExtras

/// The model of one slot of an authored profile, as a settings pane shows it
/// before the profile resolves: the reference, its MTP drafter, and the GGUF
/// file that the reference names.
///
/// ``ProfileDefinition/slotModel(for:)`` gives one. It reads only the text of
/// the reference: it makes no download, no network request and no model load.
/// ``ModelStorageSource/storageSummary(of:)`` gives the download size and the
/// disk state of ``ref`` and its drafter together.
public struct SlotModel: Sendable, Hashable {
    /// The slot.
    public let slot: ModelSlot

    /// The model of the slot. Its drafter is part of the reference.
    public let ref: ModelRef

    /// Makes the model of a slot.
    ///
    /// - Parameters:
    ///   - slot: The slot.
    ///   - ref: The model of the slot.
    public init(slot: ModelSlot, ref: ModelRef) {
        self.slot = slot
        self.ref = ref
    }

    /// The MTP drafter of the model, or `nil` when the model decodes with no
    /// drafter. The drafter is a model of its own: it has its own files and
    /// its own download.
    public var drafter: ModelRef? { ref.drafter }

    /// The GGUF file that the reference names, or `nil` when the reference
    /// names no `.gguf` file.
    ///
    /// For a reference to the Hub, it is the path of the file in the
    /// repository, for example `h2o-lightning-4b-Q4_K_M.gguf`. For a local
    /// reference to a `.gguf` file, it is the name of the file. A reference
    /// that names a quantization folder, such as `org/model-GGUF/Q4_K_M`, or
    /// an MLX or Core ML repository, names no file: the file of a
    /// quantization folder comes from the file list of the repository, which
    /// ``ModelStorageSummary/ggufFile`` gives.
    ///
    /// The extension is compared as ``GGUFFileSet/fileExtension`` spells it,
    /// because the loaders of Extras compare it so.
    public var ggufFile: String? {
        guard let location = ref.isLocal ? ref.repo : ref.path,
            (location as NSString).pathExtension == GGUFFileSet.fileExtension
        else { return nil }
        return ref.isLocal ? (location as NSString).lastPathComponent : location
    }
}

extension ProfileDefinition {
    /// The model of a slot before the profile resolves: the first candidate
    /// of the slot, or `nil` when the slot names no candidate.
    ///
    /// The resolve can choose a later candidate when the first does not fit
    /// the memory budget of the machine. ``RoutedModel/chosen`` of the
    /// resolved profile gives the model that the resolve chose.
    ///
    /// A change of a slot applies at the next resolve, and not at the next
    /// session. ``Router/resolve(profile:reporting:)`` reads the candidates
    /// one time, and the ``LanguageModelProfile`` that it gives keeps the
    /// models that it chose: ``RoutedModel/chosen`` does not change, and the
    /// router keeps no profile of its own. Each session that a handle of
    /// that profile makes, a new session included, holds that profile and
    /// runs on its models. Thus a host that resolves its profile one time,
    /// when it starts, applies a change of `profile.<slot>` at its next
    /// launch.
    ///
    /// - Parameter slot: The slot.
    /// - Returns: The model of the slot, or `nil` for a slot with no
    ///   candidate.
    public func slotModel(for slot: ModelSlot) -> SlotModel? {
        candidatesBySlot[slot]?.first.map { SlotModel(slot: slot, ref: $0) }
    }

    /// The models that a slot can take, for a settings pane: the candidates
    /// of the slot in this profile, then the builtin choices of the slot
    /// (``ModelChoices/builtin(for:)``), with one choice for each model.
    ///
    /// The model of a reference is its repository or local location, its
    /// path (the GGUF file or folder) and its revision. The drafter is not
    /// part of it. When two references name the same model, the list keeps
    /// one choice, at the position of the first reference. When that
    /// reference has no drafter, the choice takes the drafter of the first
    /// later reference that has one: a profile that names the builtin
    /// default in its text form thus gets the builtin MTP drafter. A
    /// reference with a drafter of its own keeps that drafter.
    ///
    /// The list makes no download and no network request. A change of the
    /// slot applies at the next resolve, as ``slotModel(for:)`` states.
    ///
    /// - Parameter slot: The slot.
    /// - Returns: The choices, in order: the candidates of the profile first.
    public func choices(for slot: ModelSlot) -> [ModelRef] {
        let entries = (candidatesBySlot[slot] ?? []) + ModelChoices.builtin(for: slot)
        let drafters = Dictionary(
            entries.compactMap { entry in entry.drafter.map { (entry.withoutDrafter, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<ModelRef> = []
        return entries.filter { seen.insert($0.withoutDrafter).inserted }.map { entry in
            ModelRef(
                repo: entry.repo,
                path: entry.path,
                revision: entry.revision,
                drafter: entry.drafter ?? drafters[entry.withoutDrafter]
            )
        }
    }
}

extension ModelRef {
    /// The model of the reference with no drafter: the repository or local
    /// location, the path and the revision. Two references with the same
    /// value name the same model.
    fileprivate var withoutDrafter: ModelRef {
        ModelRef(repo: repo, path: path, revision: revision)
    }
}
