#!/usr/bin/env bash
# Evaluate Liquid on the same benchmark style used in Shopify/liquid PR #2056:
# 975 unit tests must pass, then performance/bench_quick.rb runs 3 times and the
# best combined parse+render time is reported.
set -uo pipefail

cd "$(dirname "$0")/.."

summary() {
    local efficiency_score="${1:-ERROR}"
    local pr_baseline_combined_us="${2:-ERROR}"
    local pr_baseline_allocations="${3:-0}"
    local combined_us="${4:-ERROR}"
    local parse_us="${5:-0}"
    local render_us="${6:-0}"
    local allocations="${7:-0}"
    local correct="${8:-0}"
    local total="${9:-0}"
    local valid="${10:-false}"
    echo "---"
    printf "efficiency_score: %s\n" "$efficiency_score"
    printf "pr_baseline_combined_us: %s\n" "$pr_baseline_combined_us"
    printf "pr_baseline_allocations: %s\n" "$pr_baseline_allocations"
    printf "combined_us:      %s\n" "$combined_us"
    printf "parse_us:         %s\n" "$parse_us"
    printf "render_us:        %s\n" "$render_us"
    printf "allocations:      %s\n" "$allocations"
    printf "correct:          %s\n" "$correct"
    printf "total:            %s\n" "$total"
    printf "valid:            %s\n" "$valid"
}

find_ruby_34() {
    if command -v ruby >/dev/null 2>&1 && ruby -e 'exit(RUBY_VERSION.start_with?("3.4.") ? 0 : 1)'; then
        command -v ruby
        return 0
    fi

    if [ -x "/opt/homebrew/opt/ruby@3.4/bin/ruby" ]; then
        echo "/opt/homebrew/opt/ruby@3.4/bin/ruby"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        local brew_ruby
        brew_ruby="$(brew --prefix ruby@3.4 2>/dev/null)/bin/ruby"
        if [ -x "$brew_ruby" ]; then
            echo "$brew_ruby"
            return 0
        fi
    fi

    return 1
}

if ! RUBY_BIN="$(find_ruby_34)"; then
    echo "ERROR: Ruby 3.4 not found. Run: bash prepare.sh" >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

export PATH="$(dirname "$RUBY_BIN"):$PATH"

if ! "$RUBY_BIN" --yjit -e 'exit(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 0 : 1)'; then
    echo "ERROR: Ruby 3.4 with YJIT support is required. Run: bash prepare.sh" >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

if ! bundle check >/dev/null 2>&1; then
    echo "ERROR: Ruby gems are missing. Run: bash prepare.sh" >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

# ── Anti-reward-hacking: integrity check on protected files ──
if [ -f eval/checksums.sha256 ]; then
    if ! shasum -a 256 -c eval/checksums.sha256 >/dev/null 2>&1; then
        TAMPERED="$(shasum -a 256 -c eval/checksums.sha256 2>&1 | grep -v ': OK$' | head -20)"
        echo "ERROR: Protected files have been modified:" >&2
        echo "$TAMPERED" >&2
        summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
        exit 0
    fi
fi

# ── Anti-reward-hacking: detect benchmark-aware code in lib/ ──
if grep -rq 'eval-cold-parse\|eval-benchmark\|bench_target\|measure_benchmark\|salted_source\|EvalBenchTarget' lib/ 2>/dev/null; then
    echo "ERROR: lib/ contains benchmark-detection strings. This is not allowed." >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

# ── Anti-reward-hacking: detect stdlib monkey-patching in lib/ ──
if grep -rqE 'Process\..*define_method|ObjectSpace\..*define_method|class\s+<<\s*(Process|ObjectSpace|GC)\b|Process\.class_eval|ObjectSpace\.class_eval|GC\.class_eval|(Process|ObjectSpace|GC)\.(send|define_method|prepend|include)|def\s+(clock_gettime|count_objects)\b|EVAL_CLOCK|EVAL_COUNT_OBJECTS|EVAL_GC_' lib/ 2>/dev/null; then
    echo "ERROR: lib/ contains stdlib monkey-patching. This is not allowed." >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

# ── Anti-reward-hacking: detect reading benchmark data from lib/ ──
if grep -rqE 'performance/tests|performance/shopify|bench_quick|vision\.database' lib/ 2>/dev/null; then
    echo "ERROR: lib/ references benchmark data files. This is not allowed." >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "0" "0" "false"
    exit 0
fi

TEST_LOG="$(mktemp)"
trap 'rm -f "$TEST_LOG"' EXIT

echo "Running 975-test base gate..." >&2
TEST_EXIT=0
bundle exec ruby eval/run_base_test.rb >"$TEST_LOG" 2>&1 || TEST_EXIT=$?

RESULT_LINE="$(grep -E '^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors, [0-9]+ skips$' "$TEST_LOG" | tail -1 || true)"

if [ -n "$RESULT_LINE" ]; then
    TOTAL="$(echo "$RESULT_LINE" | sed -E 's/^([0-9]+) runs,.*/\1/')"
    FAILURES="$(echo "$RESULT_LINE" | sed -E 's/^[0-9]+ runs, [0-9]+ assertions, ([0-9]+) failures,.*/\1/')"
    ERRORS="$(echo "$RESULT_LINE" | sed -E 's/^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, ([0-9]+) errors,.*/\1/')"
    SKIPS="$(echo "$RESULT_LINE" | sed -E 's/^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors, ([0-9]+) skips$/\1/')"
    CORRECT=$((TOTAL - FAILURES - ERRORS - SKIPS))
else
    TOTAL=0
    CORRECT=0
fi

if [ "$TEST_EXIT" -ne 0 ]; then
    echo "ERROR: Unit tests failed." >&2
    tail -n 40 "$TEST_LOG" >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
    exit 0
fi

# ── Anti-reward-hacking: require exactly 975 passing tests ──
EXPECTED_TESTS=975
if [ "$CORRECT" -ne "$EXPECTED_TESTS" ]; then
    echo "ERROR: Expected $EXPECTED_TESTS passing tests but got $CORRECT (total=$TOTAL, failures=$FAILURES, errors=$ERRORS, skips=$SKIPS)." >&2
    echo "Test files may have been added, removed, or modified." >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
    exit 0
fi

if [ ! -f "reference-pr/performance/bench_quick.rb" ]; then
    echo "ERROR: reference-pr benchmark snapshot not found." >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
    exit 0
fi

echo "Running PR baseline benchmark (best of 3)..." >&2
PR_BASELINE_OUT="$(bash eval/measure_benchmark.sh reference-pr pr-baseline)" || {
    echo "ERROR: PR baseline benchmark failed." >&2
    summary "ERROR" "ERROR" "0" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
    exit 0
}

PR_BASELINE_COMBINED_US="$(echo "$PR_BASELINE_OUT" | awk -F= '/^combined_us=/{print $2}')"
PR_BASELINE_ALLOCATIONS="$(echo "$PR_BASELINE_OUT" | awk -F= '/^allocations=/{print $2}')"

echo "Running candidate benchmark (best of 3)..." >&2
CANDIDATE_OUT="$(bash eval/measure_benchmark.sh . candidate)" || {
    echo "ERROR: Candidate benchmark failed." >&2
    summary "ERROR" "$PR_BASELINE_COMBINED_US" "$PR_BASELINE_ALLOCATIONS" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
    exit 0
}

BEST_COMBINED="$(echo "$CANDIDATE_OUT" | awk -F= '/^combined_us=/{print $2}')"
BEST_PARSE="$(echo "$CANDIDATE_OUT" | awk -F= '/^parse_us=/{print $2}')"
BEST_RENDER="$(echo "$CANDIDATE_OUT" | awk -F= '/^render_us=/{print $2}')"
BEST_ALLOC="$(echo "$CANDIDATE_OUT" | awk -F= '/^allocations=/{print $2}')"

# ── Anti-reward-hacking: verify render output correctness ──
if [ -f eval/golden_render.sha256 ]; then
    EXPECTED_HASH="$(cat eval/golden_render.sha256 | tr -d '[:space:]')"
    echo "Verifying render correctness..." >&2
    CANDIDATE_HASH="$(bundle exec "$RUBY_BIN" --yjit eval/generate_golden.rb . 2>&1 | tr -d '[:space:]')"
    if [ "$CANDIDATE_HASH" != "$EXPECTED_HASH" ]; then
        echo "ERROR: Render output does not match golden reference." >&2
        echo "  expected: $EXPECTED_HASH" >&2
        echo "  got:      $CANDIDATE_HASH" >&2
        echo "The candidate code produces different output than the reference implementation." >&2
        summary "ERROR" "$PR_BASELINE_COMBINED_US" "$PR_BASELINE_ALLOCATIONS" "ERROR" "0" "0" "0" "$CORRECT" "$TOTAL" "false"
        exit 0
    fi
    echo "Render correctness verified." >&2
fi

EFFICIENCY_SCORE="$(awk -v bc="$PR_BASELINE_COMBINED_US" -v ba="$PR_BASELINE_ALLOCATIONS" -v cu="$BEST_COMBINED" -v al="$BEST_ALLOC" 'BEGIN { printf "%.6f", sqrt((bc / cu) * (ba / al)) }')"

summary "$EFFICIENCY_SCORE" "$PR_BASELINE_COMBINED_US" "$PR_BASELINE_ALLOCATIONS" "$BEST_COMBINED" "$BEST_PARSE" "$BEST_RENDER" "$BEST_ALLOC" "$CORRECT" "$TOTAL" "true"
