#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET_ROOT="${1:?usage: bash eval/measure_benchmark.sh <target_root> [label]}"
LABEL="${2:-benchmark}"

if [ ! -f "$TARGET_ROOT/performance/bench_quick.rb" ]; then
    echo "ERROR: benchmark not found at $TARGET_ROOT/performance/bench_quick.rb" >&2
    exit 1
fi

BEST_COMBINED=999999999
BEST_PARSE=0
BEST_RENDER=0
BEST_ALLOC=0

for i in 1 2 3; do
    OUT="$(bundle exec ruby --yjit eval/bench_target.rb "$TARGET_ROOT" 2>&1)"
    PARSE_US="$(echo "$OUT" | awk -F= '/^parse_us=/{print $2}' | tail -1)"
    RENDER_US="$(echo "$OUT" | awk -F= '/^render_us=/{print $2}' | tail -1)"
    COMBINED_US="$(echo "$OUT" | awk -F= '/^combined_us=/{print $2}' | tail -1)"
    ALLOCATIONS="$(echo "$OUT" | awk -F= '/^allocations=/{print $2}' | tail -1)"

    if [ -z "$PARSE_US" ] || [ -z "$RENDER_US" ] || [ -z "$COMBINED_US" ] || [ -z "$ALLOCATIONS" ]; then
        echo "ERROR: Benchmark output for $LABEL was not parseable." >&2
        echo "$OUT" >&2
        exit 1
    fi

    echo "  $LABEL run $i: combined=${COMBINED_US}us parse=${PARSE_US}us render=${RENDER_US}us allocations=${ALLOCATIONS}" >&2

    if [ "$COMBINED_US" -lt "$BEST_COMBINED" ]; then
        BEST_COMBINED="$COMBINED_US"
        BEST_PARSE="$PARSE_US"
        BEST_RENDER="$RENDER_US"
        BEST_ALLOC="$ALLOCATIONS"
    fi
done

printf "combined_us=%s\n" "$BEST_COMBINED"
printf "parse_us=%s\n" "$BEST_PARSE"
printf "render_us=%s\n" "$BEST_RENDER"
printf "allocations=%s\n" "$BEST_ALLOC"
