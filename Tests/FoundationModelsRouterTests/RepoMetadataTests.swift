import Foundation
import Testing

@testable import FoundationModelsRouter

@Suite("RepoMetadata")
struct RepoMetadataTests {
    /// The transport failure a stub source raises. It stands in for a machine
    /// that has lost the network.
    private struct StubFetchFailure: Error, Equatable {}

    /// A `MetadataSource` returning fixed canned bytes and counting how many
    /// times the network-shaped fetch was invoked, so cache behavior is testable
    /// without any I/O.
    private actor StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        private(set) var fetchCount = 0

        /// The error thrown in place of ``raw``, or `nil` while the fetch succeeds.
        private var failure: Error?

        init(raw: RawRepoMetadata) {
            self.raw = raw
        }

        /// Makes every later fetch throw, and count.
        ///
        /// - Parameter error: The error each later fetch throws.
        func failEveryFetch(with error: Error) {
            failure = error
        }

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            fetchCount += 1
            if let failure {
                throw failure
            }
            return raw
        }
    }

    /// A full 40-character lowercase hex commit id. It is the only revision form
    /// the Hub cannot move, so it is the only one a cache may serve unrefreshed.
    private static let commitHash = "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736"

    /// A second commit id, distinct from ``commitHash``, for cache-key tests.
    private static let otherCommitHash = "112233445566778899aabbccddeeff0011223344"

    /// A canned `config.json` with all architecture fields present.
    private static let fullConfigJSON = Data("""
        {
            "num_hidden_layers": 4,
            "num_attention_heads": 32,
            "num_key_value_heads": 8,
            "head_dim": 128,
            "hidden_size": 4096,
            "quantization": {"bits": 4, "group_size": 64}
        }
        """.utf8)

    /// A canned tree listing exercising both size paths:
    /// - Two LFS shards whose top-level `size` is the small pointer size (135)
    ///   while the real bytes live in `lfs.size` (1.0 MB + 0.5 MB) — so summing
    ///   the plain `size` instead of `lfs.size` would give a different total.
    /// - One non-LFS shard with only a plain `size` (0.25 MB), exercising the
    ///   `lfs?.size ?? size` fallback.
    /// - Non-weight files that must not be summed.
    private static let weightTreeJSON = Data("""
        [
            {"type": "file", "path": "model-00001-of-00003.safetensors", "size": 135, "lfs": {"size": 1000000}},
            {"type": "file", "path": "model-00002-of-00003.safetensors", "size": 135, "lfs": {"size": 500000}},
            {"type": "file", "path": "model-00003-of-00003.safetensors", "size": 250000},
            {"type": "file", "path": "config.json", "size": 700},
            {"type": "file", "path": "tokenizer.json", "size": 2000}
        ]
        """.utf8)

    /// Σ of the safetensors sizes above: 1.0 MB + 0.5 MB (LFS) + 0.25 MB (plain).
    private static let expectedWeightBytes: Int64 = 1_750_000

    @Test("happy path parses architecture + weight bytes into the right metadata")
    func happyPathMetadata() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let metadata = try await reader.metadata(for: "org/model")

        #expect(metadata.weightBytes == Self.expectedWeightBytes)
        #expect(metadata.numHiddenLayers == 4)
        #expect(metadata.numAttentionHeads == 32)
        #expect(metadata.numKeyValueHeads == 8)
        #expect(metadata.headDim == 128)
        // No layer_types present, so numFullAttentionLayers defaults to numHiddenLayers.
        #expect(metadata.numFullAttentionLayers == 4)
    }

    @Test("happy-path footprint matches the hand-computed estimate")
    func happyPathFootprint() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let footprint = try await reader.footprint(for: "org/model")

        // kvBytes(16) = 2(K+V) * 4 layers * 16 ctx * 8 kvHeads * 128 headDim * 2(fp16) = 262144.
        #expect(footprint.kvBytes(context: 16) == 262_144)
        #expect(footprint.footprint(context: 16) == Self.expectedWeightBytes + 262_144)
    }

    @Test("config.json missing every context-length field defaults nativeMaxContext to 8192 with a diagnostic")
    func nativeMaxContextDefaultsWhenNoFieldPresent() async throws {
        // fullConfigJSON has none of max_position_embeddings/n_positions/max_seq_len/seq_length.
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let metadata = try await reader.metadata(for: "org/model")

        #expect(metadata.nativeMaxContext == 8192)
        #expect(metadata.nativeMaxContextDiagnostic != nil)
    }

    @Test("nativeMaxContext resolves from max_position_embeddings when present")
    func nativeMaxContextFromMaxPositionEmbeddings() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_position_embeddings": 32768
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 32768)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    @Test("nativeMaxContext falls back to n_positions when max_position_embeddings is absent")
    func nativeMaxContextFromNPositions() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "n_positions": 16384
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 16384)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    @Test("nativeMaxContext falls back to max_seq_len when higher-priority fields are absent")
    func nativeMaxContextFromMaxSeqLen() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_seq_len": 8192
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 8192)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    @Test("nativeMaxContext falls back to seq_length as the last resort")
    func nativeMaxContextFromSeqLength() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "seq_length": 12000
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 12000)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    @Test("an absurdly large nativeMaxContext value is capped to the sanity ceiling")
    func nativeMaxContextCappedWhenAbsurd() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_position_embeddings": 99999999
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 1_048_576)
        #expect(metadata.nativeMaxContextDiagnostic != nil)
    }

    @Test("a tiny nativeMaxContext value is raised to the floor")
    func nativeMaxContextFlooredWhenTiny() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_position_embeddings": 128
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 4096)
        #expect(metadata.nativeMaxContextDiagnostic != nil)
    }

    @Test("a value exactly at the sanity cap passes through unchanged, with no diagnostic")
    func nativeMaxContextAtCapBoundaryPassesThrough() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_position_embeddings": 1048576
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 1_048_576)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    @Test("a value exactly at the floor passes through unchanged, with no diagnostic")
    func nativeMaxContextAtFloorBoundaryPassesThrough() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_position_embeddings": 4096
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 4096)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    @Test("a non-positive nativeMaxContext value is raised to the floor, with a diagnostic")
    func nativeMaxContextFlooredWhenNonPositive() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "head_dim": 128,
                "max_position_embeddings": -1
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 4096)
        #expect(metadata.nativeMaxContextDiagnostic != nil)
    }

    @Test("nativeMaxContext resolves from a VLM's text_config, matching the coherent-source rule")
    func nativeMaxContextFromTextConfig() throws {
        let raw = RawRepoMetadata(configJSON: Self.qwenVLConfigJSON, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.nativeMaxContext == 262_144)
        #expect(metadata.nativeMaxContextDiagnostic == nil)
    }

    /// The verbatim `config.json` fetched from
    /// `https://huggingface.co/mlx-community/Qwen3.5-2B-mxfp4/resolve/main/config.json`.
    /// A VLM config: the transformer sizing fields live only under `text_config`
    /// (`num_hidden_layers: 24`, `num_attention_heads: 8`, `num_key_value_heads: 2`,
    /// `head_dim: 256`, `hidden_size: 2048`); the top level holds none of them, and
    /// the sibling `vision_config` uses distinct field names (`depth`, `num_heads`)
    /// so it cannot collide with the text-config fields.
    private static let qwenVLConfigJSON = Data("""
        {
            "architectures": [
                "Qwen3_5ForConditionalGeneration"
            ],
            "image_token_id": 248056,
            "model_type": "qwen3_5",
            "quantization": {
                "group_size": 32,
                "bits": 4,
                "mode": "mxfp4"
            },
            "quantization_config": {
                "group_size": 32,
                "bits": 4,
                "mode": "mxfp4"
            },
            "text_config": {
                "attention_bias": false,
                "attention_dropout": 0.0,
                "attn_output_gate": true,
                "dtype": "bfloat16",
                "eos_token_id": 248044,
                "full_attention_interval": 4,
                "head_dim": 256,
                "hidden_act": "silu",
                "hidden_size": 2048,
                "initializer_range": 0.02,
                "intermediate_size": 6144,
                "layer_types": [
                    "linear_attention",
                    "linear_attention",
                    "linear_attention",
                    "full_attention",
                    "linear_attention",
                    "linear_attention",
                    "linear_attention",
                    "full_attention",
                    "linear_attention",
                    "linear_attention",
                    "linear_attention",
                    "full_attention",
                    "linear_attention",
                    "linear_attention",
                    "linear_attention",
                    "full_attention",
                    "linear_attention",
                    "linear_attention",
                    "linear_attention",
                    "full_attention",
                    "linear_attention",
                    "linear_attention",
                    "linear_attention",
                    "full_attention"
                ],
                "linear_conv_kernel_dim": 4,
                "linear_key_head_dim": 128,
                "linear_num_key_heads": 16,
                "linear_num_value_heads": 16,
                "linear_value_head_dim": 128,
                "max_position_embeddings": 262144,
                "mlp_only_layers": [],
                "model_type": "qwen3_5_text",
                "mtp_num_hidden_layers": 1,
                "mtp_use_dedicated_embeddings": false,
                "num_attention_heads": 8,
                "num_hidden_layers": 24,
                "num_key_value_heads": 2,
                "rms_norm_eps": 1e-06,
                "tie_word_embeddings": true,
                "use_cache": true,
                "vocab_size": 248320,
                "mamba_ssm_dtype": "float32",
                "rope_parameters": {
                    "mrope_interleaved": true,
                    "mrope_section": [
                        11,
                        11,
                        10
                    ],
                    "rope_type": "default",
                    "rope_theta": 10000000,
                    "partial_rotary_factor": 0.25
                }
            },
            "tie_word_embeddings": true,
            "transformers_version": "4.57.0.dev0",
            "video_token_id": 248057,
            "vision_config": {
                "deepstack_visual_indexes": [],
                "depth": 24,
                "hidden_act": "gelu_pytorch_tanh",
                "hidden_size": 1024,
                "in_channels": 3,
                "initializer_range": 0.02,
                "intermediate_size": 4096,
                "model_type": "qwen3_5",
                "num_heads": 16,
                "num_position_embeddings": 2304,
                "out_hidden_size": 2048,
                "patch_size": 16,
                "spatial_merge_size": 2,
                "temporal_patch_size": 2
            },
            "vision_end_token_id": 248054,
            "vision_start_token_id": 248053
        }
        """.utf8)

    @Test("VLM config with sizing fields only under text_config resolves via the text_config fallback")
    func qwenVLTextConfigFallback() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.qwenVLConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let metadata = try await reader.metadata(for: "mlx-community/Qwen3.5-2B-mxfp4")

        #expect(metadata.numHiddenLayers == 24)
        #expect(metadata.numAttentionHeads == 8)
        #expect(metadata.numKeyValueHeads == 2)
        #expect(metadata.headDim == 256)
        #expect(metadata.hiddenSize == 2048)
    }

    @Test("hybrid linear/full-attention layer_types counts only full_attention layers for the KV cache")
    func hybridAttentionLayerCounting() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.qwenVLConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let metadata = try await reader.metadata(for: "mlx-community/Qwen3.5-2B-mxfp4")
        let footprint = try await reader.footprint(for: "mlx-community/Qwen3.5-2B-mxfp4")

        // layer_types has 24 entries, 6 of which are "full_attention" (every 4th, per
        // full_attention_interval: 4); the other 18 are "linear_attention", a
        // fixed-size recurrent state that does not grow with context.
        #expect(metadata.numFullAttentionLayers == 6)

        // kvBytes(16) = 2(K+V) * 6 layers * 16 ctx * 2 kvHeads * 256 headDim * 2(fp16)
        // = 196608 — not the 786432 a naive num_hidden_layers (24) count would give.
        #expect(footprint.kvBytes(context: 16) == 196_608)
    }

    @Test("a config with complete sizing fields at both levels resolves entirely from the top level")
    func topLevelSizingFieldsWinOverTextConfig() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "num_attention_heads": 32,
                "num_key_value_heads": 8,
                "head_dim": 128,
                "hidden_size": 4096,
                "text_config": {
                    "num_hidden_layers": 24,
                    "num_attention_heads": 8,
                    "num_key_value_heads": 2,
                    "head_dim": 256,
                    "hidden_size": 2048
                }
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        #expect(metadata.numHiddenLayers == 4)
        #expect(metadata.numAttentionHeads == 32)
        #expect(metadata.numKeyValueHeads == 8)
        #expect(metadata.headDim == 128)
        #expect(metadata.hiddenSize == 4096)
    }

    @Test("a top level with only one required field falls through entirely to a complete text_config")
    func partialTopLevelFallsThroughToTextConfig() throws {
        let config = Data("""
            {
                "num_hidden_layers": 4,
                "text_config": {
                    "num_hidden_layers": 24,
                    "num_attention_heads": 8,
                    "num_key_value_heads": 2,
                    "head_dim": 256,
                    "hidden_size": 2048
                }
            }
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        let metadata = try RepoMetadata(raw: raw)

        // The top level has num_hidden_layers but not num_attention_heads, so it is
        // not a coherent source; every field must come from text_config instead —
        // including num_hidden_layers, not the top level's stray value of 4.
        #expect(metadata.numHiddenLayers == 24)
        #expect(metadata.numAttentionHeads == 8)
        #expect(metadata.numKeyValueHeads == 2)
        #expect(metadata.headDim == 256)
        #expect(metadata.hiddenSize == 2048)
    }

    @Test("GQA fallback: absent num_key_value_heads uses num_attention_heads")
    func gqaFallback() async throws {
        let config = Data("""
            {"num_hidden_layers": 2, "num_attention_heads": 8, "head_dim": 16}
            """.utf8)
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let footprint = try await reader.footprint(for: "org/model")

        #expect(footprint.kvHeads == 8)
    }

    @Test("head_dim fallback: absent head_dim uses hidden_size / num_attention_heads")
    func headDimFallback() async throws {
        let config = Data("""
            {"num_hidden_layers": 2, "num_attention_heads": 8, "hidden_size": 512}
            """.utf8)
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let footprint = try await reader.footprint(for: "org/model")

        // hidden_size 512 / 8 heads = 64 head_dim.
        #expect(footprint.headDim == 64)
    }

    @Test("missing config.json surfaces metadataUnavailable, not a crash")
    func missingConfigUnavailable() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: nil, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: "org/model")
        }
    }

    @Test("no *.safetensors in the tree surfaces metadataUnavailable")
    func noSafetensorsUnavailable() async throws {
        let tree = Data("""
            [
                {"type": "file", "path": "config.json", "size": 700},
                {"type": "file", "path": "tokenizer.json", "size": 2000}
            ]
            """.utf8)
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: tree)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: RepoMetadataError.self) {
            _ = try await reader.metadata(for: "org/model")
        }
    }

    @Test("config.json that is not valid JSON surfaces metadataUnavailable mentioning the parse failure")
    func malformedConfigJSONUnavailable() throws {
        let raw = RawRepoMetadata(configJSON: Data("not json".utf8), treeJSON: Self.weightTreeJSON)

        #expect(throws: RepoMetadataError.metadataUnavailable("config.json could not be parsed")) {
            _ = try RepoMetadata(raw: raw)
        }
    }

    @Test("config.json missing num_hidden_layers or num_attention_heads surfaces metadataUnavailable")
    func missingArchitectureFieldsUnavailable() throws {
        let config = Data("""
            {"head_dim": 128, "hidden_size": 4096}
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        #expect(
            throws: RepoMetadataError.metadataUnavailable(
                "config.json is missing num_hidden_layers or num_attention_heads"
            )
        ) {
            _ = try RepoMetadata(raw: raw)
        }
    }

    @Test("config.json with neither head_dim nor hidden_size surfaces metadataUnavailable")
    func missingHeadSizingFieldsUnavailable() throws {
        let config = Data("""
            {"num_hidden_layers": 4, "num_attention_heads": 32}
            """.utf8)
        let raw = RawRepoMetadata(configJSON: config, treeJSON: Self.weightTreeJSON)

        #expect(
            throws: RepoMetadataError.metadataUnavailable(
                "config.json has neither head_dim nor hidden_size to size a head"
            )
        ) {
            _ = try RepoMetadata(raw: raw)
        }
    }

    @Test("RepoMetadata Codable round-trips every architecture field")
    func codableRoundTrip() throws {
        let metadata = RepoMetadata(
            weightBytes: Self.expectedWeightBytes,
            numHiddenLayers: 24,
            numAttentionHeads: 32,
            numKeyValueHeads: 8,
            headDim: 128,
            hiddenSize: 4096,
            numFullAttentionLayers: 6
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RepoMetadata.self, from: data)

        #expect(decoded == metadata)
        #expect(decoded.numFullAttentionLayers == 6)
    }

    @Test("RepoMetadata Codable round-trip preserves a non-default nativeMaxContext")
    func codableRoundTripPreservesNonDefaultNativeMaxContext() throws {
        let metadata = RepoMetadata(
            weightBytes: Self.expectedWeightBytes,
            numHiddenLayers: 24,
            numAttentionHeads: 32,
            numKeyValueHeads: 8,
            headDim: 128,
            hiddenSize: 4096,
            numFullAttentionLayers: 6,
            nativeMaxContext: 32768,
            nativeMaxContextDiagnostic: "some diagnostic"
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RepoMetadata.self, from: data)

        #expect(decoded == metadata)
        #expect(decoded.nativeMaxContext == 32768)
        #expect(decoded.nativeMaxContextDiagnostic == "some diagnostic")
    }

    @Test("a reference pinned to a commit hash never refetches after the first fetch")
    func commitPinnedReferenceFetchesOnce() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let ref = ModelRef(repo: "org/model", revision: Self.commitHash)
        let first = try await reader.metadata(for: ref)
        let second = try await reader.metadata(for: ref)

        #expect(first == second)
        #expect(await source.fetchCount == 1)
    }

    @Test("distinct (repo, revision) keys are cached independently")
    func cacheKeySeparation() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await reader.metadata(for: ModelRef(repo: "org/model", revision: Self.commitHash))
        _ = try await reader.metadata(for: ModelRef(repo: "org/model", revision: Self.otherCommitHash))

        #expect(await source.fetchCount == 2)
    }

    @Test(
        "a reference with a nil, branch, or tag revision fetches on each call",
        // A `nil` revision tracks the default branch; `main` is a branch; `v1.0`
        // is a tag; `0f1e2d3c` is an abbreviation, not a full commit id; and the
        // last is a full commit id in uppercase, which is not the hex form a
        // commit id takes. Every one of them can point at new content later.
        arguments: [
            nil,
            "main",
            "v1.0",
            "0f1e2d3c",
            "0F1E2D3C4B5A69788796A5B4C3D2E1F009182736",
        ] as [String?]
    )
    func movingRevisionFetchesOnEachCall(revision: String?) async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = ModelRef(repo: "org/model", revision: revision)

        let first = try await reader.metadata(for: ref)
        let second = try await reader.metadata(for: ref)

        #expect(first == second)
        #expect(await source.fetchCount == 2)
    }

    /// A cache entry from before the branch it is keyed by moved. It is written
    /// in the current schema, so it decodes and only the read order can reject
    /// it, and its `weightBytes` differs from ``expectedWeightBytes``, so a
    /// stale read and a fresh read are told apart.
    private static let movedPastCacheJSON = Data("""
        {
            "weightBytes": 999999,
            "numHiddenLayers": 4,
            "numAttentionHeads": 32,
            "numKeyValueHeads": 8,
            "headDim": 128,
            "hiddenSize": 4096,
            "numFullAttentionLayers": 4,
            "nativeMaxContext": 8192
        }
        """.utf8)

    @Test("a read at a moving revision replaces a cache entry the revision moved past")
    func movingRevisionUpdatesTheCache() async throws {
        let (reader, dir, _) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = ModelRef(repo: "org/model", revision: "main")
        let cache = RepoMetadataCache(cacheDir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.movedPastCacheJSON.write(to: cache.fileURL(repo: ref.repo, revision: ref.revision))

        let metadata = try await reader.metadata(for: ref)

        #expect(metadata.weightBytes == Self.expectedWeightBytes)
        #expect(try cache.load(repo: ref.repo, revision: ref.revision) == metadata)
    }

    @Test("a failed fetch at a moving revision returns the cached entry")
    func movingRevisionFetchFailureFallsBackToCache() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = ModelRef(repo: "org/model", revision: "main")
        // The machine resolves once while it has the network, then loses it.
        let online = try await reader.metadata(for: ref)
        await source.failEveryFetch(with: StubFetchFailure())

        let offline = try await reader.metadata(for: ref)

        #expect(offline == online)
        #expect(await source.fetchCount == 2)
    }

    @Test("a failed fetch at a moving revision with nothing cached throws the fetch error")
    func movingRevisionFetchFailureWithoutCacheThrows() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        await source.failEveryFetch(with: StubFetchFailure())

        await #expect(throws: StubFetchFailure.self) {
            _ = try await reader.metadata(for: ModelRef(repo: "org/model", revision: "main"))
        }
    }

    /// A cache entry written in the pre-fix schema, before `numFullAttentionLayers`
    /// existed on `RepoMetadata` — missing the key entirely, rather than encoding
    /// it as `null`, matching what a real on-disk entry from an older build looks
    /// like.
    private static let staleSchemaCacheJSON = Data("""
        {
            "weightBytes": 1750000,
            "numHiddenLayers": 4,
            "numAttentionHeads": 32,
            "numKeyValueHeads": 8,
            "headDim": 128,
            "hiddenSize": 4096
        }
        """.utf8)

    @Test("RepoMetadataCache.load given a cache entry missing numFullAttentionLayers returns nil rather than throwing")
    func loadTreatsStaleSchemaEntryAsCacheMiss() throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RepoMetadataCache(cacheDir: dir)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.staleSchemaCacheJSON.write(to: cache.fileURL(repo: "org/model", revision: "abc123"))

        #expect(try cache.load(repo: "org/model", revision: "abc123") == nil)
    }

    @Test("RepoMetadataReader.metadata(for:) re-fetches and re-caches when the cached entry has the stale pre-fix schema")
    func metadataReFetchesOnStaleSchemaCacheEntry() async throws {
        let (reader, dir, source) = Self.makeReader(
            raw: RawRepoMetadata(configJSON: Self.fullConfigJSON, treeJSON: Self.weightTreeJSON)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        // A commit hash, so the reader reads the cache first and the stale entry
        // is what it finds there.
        let ref = ModelRef(repo: "org/model", revision: Self.commitHash)
        let cache = RepoMetadataCache(cacheDir: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.staleSchemaCacheJSON.write(to: cache.fileURL(repo: ref.repo, revision: ref.revision))

        let metadata = try await reader.metadata(for: ref)

        // Re-fetched from source rather than throwing "metadata unavailable".
        #expect(metadata.weightBytes == Self.expectedWeightBytes)
        #expect(metadata.numFullAttentionLayers == 4)
        #expect(await source.fetchCount == 1)

        // Re-cached successfully in the current schema: a second read hits the
        // cache without invoking the source again.
        let second = try await reader.metadata(for: ref)
        #expect(second == metadata)
        #expect(await source.fetchCount == 1)
    }

    /// Builds a reader over a fresh temp cache dir, returning the dir for cleanup
    /// and the stub source for fetch-count assertions.
    private static func makeReader(
        raw: RawRepoMetadata
    ) -> (reader: RepoMetadataReader, dir: URL, source: StubMetadataSource) {
        let dir = makeTempDir()
        let source = StubMetadataSource(raw: raw)
        return (RepoMetadataReader(source: source, cacheDir: dir), dir, source)
    }

    /// Creates a unique temporary directory for cache tests.
    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
