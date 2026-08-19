#!/bin/bash
#
# Runs `swift test` with the selectors it is given, and fails when the run
# measured nothing.
#
# `swift test` answers 0 when a `--filter` matches no test at all: it prints
# `warning: No matching test cases were run` on standard error and exits clean.
# A real-model job that named a target which had been renamed away would then
# report green having measured nothing — the same one-bit failure the old
# environment-variable gate produced whenever the variable was unset. This
# script reads that warning and turns it into a failure, so a green run always
# means a run that measured something.
#
# Usage: Scripts/swift-test.sh [swift test options...]
#   Scripts/swift-test.sh --skip FoundationModelsRouterRealModel
#   Scripts/swift-test.sh --filter FoundationModelsRouterRealModel

set -euo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# `pipefail` above is what carries `swift test`'s own failure through `tee`.
swift test "$@" 2>&1 | tee "$log"

if grep -q 'No matching test cases were run' "$log"; then
    echo "swift test $* matched no test case: this run measured nothing" >&2
    exit 1
fi
