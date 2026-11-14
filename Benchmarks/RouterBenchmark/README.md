# RouterBenchmark

Times the generation of the `standard` model of a router profile: the prefill,
the time to the first token, and the decode rate. It lives in the nested
`Benchmarks/` package, so CI never builds or runs it.

```sh
# From the repository root. Always build for release: a debug build times the debug build.
swift run -c release --package-path Benchmarks RouterBenchmark --model mlx-community/Qwen2.5-14B-Instruct-4bit

# A GGUF model, a bigger prompt, and the samples as JSON.
swift run -c release --package-path Benchmarks RouterBenchmark \
  --model Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf --prompt-tokens 4096 --json /tmp/bench.json
```

`--model` takes any `ModelRef` string: a Hub repo, a `repo/file.gguf`, or a
local folder (`~/…`, `./…`, `/…`). The model fills the `standard` slot. The
router requires a different `flash` model, so `--flash` names a small one that
the benchmark never times. The first run of a model downloads it.

| Option | Default | Meaning |
| --- | --- | --- |
| `--model` | `mlx-community/Qwen2.5-3B-Instruct-4bit` | The model to time. |
| `--flash` | `mlx-community/SmolLM-135M-Instruct-4bit` | The `flash` slot model, which must differ from `--model`. Not timed. |
| `--prompt-tokens` | 1024 | The tokens of the cold prompt, counted by the model's tokenizer. |
| `--max-tokens` | 256 | The token ceiling of each answer. |
| `--runs` | 3 | The measured runs. |
| `--warmup` | 1 | The runs before them, which the report leaves out. |
| `--drafter` | none | Decode speculatively with this drafter: an MTP checkpoint for an MLX model, a DFlash or draft GGUF for a GGUF model. |
| `--no-speculation` | off | Turn speculative decoding off for a GGUF model, also when its file holds MTP layers. |
| `--json` | none | Also write every sample to this file. |
| `--show-text` | off | Echo each answer to standard error as it streams, its reasoning and its text each under a label: check that a new model answers coherently before timing it. |
| `--label` | the model ref | The name of the run in the JSON file and in `--compare`. |

`RouterBenchmark --compare a.json b.json …` loads no model. It prints the
medians of earlier runs side by side, with each decode rate compared with the
first file's.

## Comparing models

`Benchmarks/compare.sh` times Qwen3.8-27B at 4 bits with MLX, MLX + MTP,
llama.cpp (the unsloth GGUF), llama.cpp + the MTP layer of that file,
llama.cpp + DFlash 2, and llama.cpp with the Q4_0 file, with and without its
MTP layer, then Flint (a 40B mixture of experts with ~2.5B active) at oQ8e on
MLX. Each setup runs in its own process, and then the script compares
them. Extra options go to every run, and `CONFIGS` runs only some labels while
the comparison still takes the JSON already in `$OUT`:

```sh
Benchmarks/compare.sh --prompt-tokens 4096 --runs 5
OUT=/tmp/bench CONFIGS="flint" Benchmarks/compare.sh
```

| Label | Model | Drafter |
| --- | --- | --- |
| `mlx` | `mlx-community/Qwen3.8-27B-4bit` | none |
| `mlx-mtp` | `mlx-community/Qwen3.8-27B-4bit` | `mlx-community/Qwen3.8-27B-MTP-4bit` |
| `gguf` | `unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf`, `--no-speculation` | none |
| `gguf-mtp` | `unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf` | the MTP layer in the file |
| `gguf-dflash` | `unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf` | `z-lab/Qwen3.8-27B-DFlash2-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf` |
| `q4_0` | `unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_0.gguf`, `--no-speculation` | none |
| `q4_0-mtp` | `unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_0.gguf` | the MTP layer in the file |
| `flint` | `mlx-community/flint-oQ8e` | none |

The unsloth GGUF holds an MTP layer, and llama.cpp drafts with it by default,
so the plain runs turn speculation off. UD-Q4_K_M mixes bit widths across
layers; Q4_0 is uniform 4-bit groups with one scale each, the format closest to
the MLX weights, so the `q4_0` runs separate the backend from the quantization. Unsloth publishes only the GGUF of this model, so the MLX weights, the MTP
checkpoint and the DFlash drafter come from other repos. The `accepted` column
shows the share of drafted tokens that the target kept, or `off: <reason>` when
the backend fell back to plain decode.

## What a run measures

Each run opens a new session and sends two messages:

- **cold**: a prompt of `--prompt-tokens` tokens that starts with a unique
  nonce, so no prompt cache holds any of it.
- **warm**: a short follow-up on the same session. The session's prompt cache
  holds the earlier turn, so this measures how much of the prefix it reuses.

The columns come from the session's own `SessionEvent.generationCall`
measurement of each call:

| Column | Meaning |
| --- | --- |
| `calls` | The generation calls of the answer. A thinking model whose reasoning reaches the token ceiling continues in a second call, which reuses the cache of the first. |
| `in` | The tokens fed to the first call: the whole rendered context, chat template included. |
| `cached` | The part of `in` that the prompt cache reused (the prefix). `-` when the backend reports no count. |
| `prefill` | `in` − `cached`: the tokens the call actually prefilled. |
| `out` | The tokens generated, by every call. |
| `ttft s` | From the start of the first call to its first output token (reasoning included). This is the prefill time. |
| `client s` | From the send to the first streamed fragment, as a caller sees it. Adds the session's queueing to `ttft`. |
| `prefill t/s` | `prefill` / `ttft`. |
| `decode t/s` | `out` / the decode time, over every call of the answer. |
| `accepted` | The share of drafted tokens that the model kept. `-` with no drafting. |

The output ends with the median of each phase across the measured runs. Progress
goes to standard error and the report goes to standard output, so
`… > report.txt` captures only the report.
