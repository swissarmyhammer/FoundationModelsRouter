#!/usr/bin/env bash
# Times Qwen3.8-27B at 4 bits seven ways, and Flint, one process each, then
# prints the medians side by side:
#
#   mlx           MLX, plain decode
#   mlx-mtp       MLX, with the MTP drafter checkpoint
#   gguf          llama.cpp, the unsloth GGUF, plain decode
#   gguf-mtp      llama.cpp, the unsloth GGUF, with the MTP layer of its file
#   gguf-dflash   llama.cpp, the unsloth GGUF, with the DFlash 2 drafter
#   q4_0          llama.cpp, the unsloth Q4_0 GGUF, plain decode
#   q4_0-mtp      llama.cpp, the unsloth Q4_0 GGUF, with the MTP layer of its file
#   flint         MLX, Flint (40B MoE, ~2.5B active) at oQ8e, 8-bit affine
#
# The unsloth GGUF is UD-Q4_K_M, which mixes bit widths across layers. Q4_0 is
# uniform 4-bit groups with one scale each, the format closest to the MLX
# 4-bit weights, so it separates the backend from the quantization.
#
# The unsloth GGUF holds the MTP layer (`blk.64.nextn.*`), and llama.cpp
# drafts with it unless told not to, so the plain run passes
# `--no-speculation`. A drafter takes precedence over the MTP layer, so the
# DFlash run drafts with DFlash alone. The Q4_0 file holds the MTP layer too.
#
# Unsloth publishes the GGUF only, so the MLX weights, the MTP checkpoint and
# the DFlash drafter come from mlx-community and z-lab.
#
# Usage, from anywhere:
#
#   Benchmarks/compare.sh [RouterBenchmark options...]
#
# Extra options (for example `--prompt-tokens 4096 --runs 5`) go to each run.
# The JSON of each run lands in $OUT (default: a new temporary folder). A run
# that fails is reported and left out of the comparison. CONFIGS limits the run
# to some labels (for example `CONFIGS="q4_0 q4_0-mtp"`); the comparison then
# also takes every other JSON file already in $OUT, in the order above.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="${OUT:-$(mktemp -d -t router-bench)}"

swift build -c release --package-path "$here" --product RouterBenchmark || exit 1
bench="$(swift build -c release --package-path "$here" --show-bin-path)/RouterBenchmark"

mlx="mlx-community/Qwen3.8-27B-4bit"
mtp="mlx-community/Qwen3.8-27B-MTP-4bit"
gguf="unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_M.gguf"
q4_0="unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_0.gguf"
flint="mlx-community/flint-oQ8e"
dflash="z-lab/Qwen3.8-27B-DFlash2-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"

configs=(
    "mlx|--model $mlx"
    "mlx-mtp|--model $mlx --drafter $mtp"
    "gguf|--model $gguf --no-speculation"
    "gguf-mtp|--model $gguf"
    "gguf-dflash|--model $gguf --drafter $dflash"
    "q4_0|--model $q4_0 --no-speculation"
    "q4_0-mtp|--model $q4_0"
    "flint|--model $flint"
)

files=()
for config in "${configs[@]}"; do
    label="${config%%|*}"
    # shellcheck disable=SC2206  # the model options split on spaces by design
    model_args=(${config#*|})
    if [ -n "${CONFIGS:-}" ] && [[ " $CONFIGS " != *" $label "* ]]; then
        [ -f "$out/$label.json" ] && files+=("$out/$label.json")
        continue
    fi
    echo "=== $label" >&2
    if "$bench" "${model_args[@]}" --label "$label" --json "$out/$label.json" "$@"; then
        files+=("$out/$label.json")
    else
        echo "=== $label failed; left out of the comparison" >&2
    fi
done

echo
echo "=== comparison (JSON in $out)"
[ ${#files[@]} -gt 0 ] && "$bench" --compare "${files[@]}"
