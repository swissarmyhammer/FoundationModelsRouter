import Foundation
import FoundationModelsLlamaCpp

/// The memory of the context of a GGUF model beside its weights, read from
/// its GGUF header before any download: the KV cache that grows with the
/// context, and the fixed recurrent state of a hybrid model.
///
/// The figures follow `LlamaLanguageModel.footprintBytes(gguf:projector:drafter:options:)`
/// of FoundationModelsLlamaCpp for the options the live loader gives a GGUF
/// model, the default options:
///
/// - The KV cache is fp16 and unified: `n_ctx` cells, padded to 256 as
///   llama.cpp pads them, for all sequences. Thus it does not grow with the
///   count of the live sequences. ``bytes(context:)`` at a context equals
///   `GGUFHeader.keyValueBytes(contextSize:cacheType:)` with `.float16`.
/// - The recurrent state of a hybrid model is held for each live sequence,
///   `LlamaLanguageModel.Options.defaultMaxLiveSequences` of them, with no
///   rollback snapshot.
///
/// The compute buffers that llama.cpp adds are not modeled, as the overhead
/// of an MLX model is not modeled (see ``Footprint``).
struct GGUFCacheSizing: Sendable, Equatable, Codable {
    /// The cells of the KV cache are a multiple of this count
    /// (`GGML_PAD(n_ctx, 256)` in llama.cpp).
    static let contextPadding = 256

    /// The architecture that the fork converters give a DFlash drafter
    /// (for example jcuypers/Qwen3.6-35B-A3B-DFlash-GGUF). Mainline llama.cpp
    /// (b12229) loads a DFlash drafter only with the architecture
    /// ``dflashArchitecture``, so a model with such a drafter falls back to
    /// decoding with no drafter (`drafterNotLoaded`): its output is correct,
    /// with no speedup.
    static let forkDFlashArchitecture = "dflash-draft"

    /// The architecture that mainline llama.cpp (b12229) loads as a DFlash
    /// drafter, when the file also has the key `dflash.target_layers`. An
    /// older converter writes this architecture with no such key (for example
    /// lym00/Qwen3-4B-DFlash-GGUF-Test), and a model with that drafter falls
    /// back to decoding with no drafter, as with ``forkDFlashArchitecture``.
    static let dflashArchitecture = "dflash"

    /// Why llama.cpp does not load a GGUF model as a DFlash drafter.
    enum UnloadableDFlashDrafter: Sendable, Equatable {
        /// The architecture is ``GGUFCacheSizing/forkDFlashArchitecture``.
        case forkArchitecture

        /// The architecture is ``GGUFCacheSizing/dflashArchitecture``, and the
        /// file has no `dflash.target_layers` key.
        case noTargetLayers

        /// The words that state the cause after "a GGUF drafter has" in the
        /// warning of the router.
        var cause: String {
            switch self {
            case .forkArchitecture:
                "the architecture \(GGUFCacheSizing.forkDFlashArchitecture) of the fork converters"
            case .noTargetLayers:
                """
                the architecture \(GGUFCacheSizing.dflashArchitecture) with no dflash.target_layers key, \
                as an older converter writes it
                """
            }
        }
    }

    /// The architecture of the model (`general.architecture`).
    let architecture: String

    /// Whether the GGUF header has the key `dflash.target_layers`: the layers
    /// of the target model whose features a DFlash drafter reads.
    let hasDFlashTargetLayers: Bool

    /// Why llama.cpp does not load the model as a DFlash drafter, or `nil`
    /// when nothing in the header stops that load: the model is not a DFlash
    /// drafter, or it is one that llama.cpp loads.
    var unloadableDFlashDrafter: UnloadableDFlashDrafter? {
        if architecture == Self.forkDFlashArchitecture {
            return .forkArchitecture
        }
        if architecture == Self.dflashArchitecture && !hasDFlashTargetLayers {
            return .noTargetLayers
        }
        return nil
    }

    /// The bytes of the fp16 K and V caches of one cell: one token of the
    /// context.
    let keyValueBytesPerCell: Int64

    /// The bytes of the recurrent state of a hybrid model for every live
    /// sequence, or 0 for a model with no recurrent block.
    let recurrentStateBytes: Int64

    /// Reads the cache sizing of a model from its GGUF header.
    ///
    /// - Parameter header: The parsed header of the model, or of the first
    ///   shard of its split set.
    init(header: GGUFHeader) {
        architecture = header.architecture
        hasDFlashTargetLayers = header.dflashTargetLayers != nil
        keyValueBytesPerCell = Int64(header.keyValueBytesPerToken(cacheType: .float16))
        recurrentStateBytes = Int64(
            header.recurrentStateBytes(sequenceCount: LlamaLanguageModel.Options.defaultMaxLiveSequences))
    }

    /// The bytes of the context of the model at a context size: the KV cache
    /// of the padded cells, and the recurrent state.
    ///
    /// - Parameter context: The context size, in tokens.
    /// - Returns: The bytes.
    func bytes(context: Int) -> Int64 {
        let cells = (context + Self.contextPadding - 1) / Self.contextPadding * Self.contextPadding
        return Int64(cells) * keyValueBytesPerCell + recurrentStateBytes
    }
}
