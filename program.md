# Liquid ThemeRunner Performance

Optimize Shopify Liquid's parser and renderer to maximize `efficiency_score` on the same ThemeRunner benchmark used in PR #2056, while preserving correctness on the 975-test base suite.

## Setup

1. **Read the in-scope files**:
   - `lib/**/*.rb` — the Liquid implementation you modify.
   - `performance/bench_quick.rb` — the fixed benchmark harness. Do not modify.
   - `performance/theme_runner.rb` — loads the real Shopify-like templates and data used by the benchmark. Do not modify.
   - `test/{integration,unit}/**/*_test.rb` — the 975-test correctness gate. Do not modify.
   - `eval/eval.sh` — runs the correctness + performance eval. Do not modify.
   - `prepare.sh` — installs Ruby dependencies. Do not modify.
2. **Run prepare**: `bash prepare.sh` to ensure Ruby 3.4 + YJIT is available and install the required gems.
3. **Verify setup**:
   - `ruby --version` should report Ruby 3.4 after `prepare.sh` updates your `PATH` for the current shell.
   - `bundle check` should succeed.
4. **Initialize results.tsv**: Create `results.tsv` with just the header row.
5. **Run baseline**: `bash eval/eval.sh > run.log 2>&1`

## The benchmark

This task uses the exact benchmark family cited in Shopify/liquid PR #2056: ThemeRunner over real Shopify-like theme templates and production-style data. The eval first runs the 975-test base suite, then runs a fixed eval-owned benchmark three times with `--yjit` and keeps the best combined parse+render time.

The benchmark reports one score plus four raw numbers:

- `efficiency_score` — composite score that rewards lower `combined_us` and lower `allocations` together. Higher is better. The PR-head baseline is recomputed on this machine for every eval and normalized to `1.0`.
- `combined_us` — parse + render time in microseconds for the best run. Lower is better.
- `parse_us` — parse-only time in microseconds for the best run.
- `render_us` — render-only time in microseconds for the best run.
- `allocations` — object allocations for one parse+render cycle from that same best run.

Reference points:

- PR #2056 reports **3,534us combined**, **2,353us parse**, **1,146us render**, **24,530 allocations** on the author's machine with Ruby 3.4 + YJIT.
- The task carries a `reference-pr/` snapshot of Shopify/liquid PR #2056 head.
- On every eval, the scorer reruns that `reference-pr/` benchmark on the current machine to establish a fresh PR baseline before benchmarking the candidate.
- This makes `efficiency_score` machine-local: the PR baseline for that machine is always `1.0`.
- The parse side of the benchmark uses salted template variants on every timed iteration so whole-document parse caches cannot turn repeated compiles into cache hits.

Only compare scores produced on the same environment.

## Experimentation

**What you CAN modify:**

- Any Ruby implementation file under `lib/`
- You may add new Ruby files under `lib/` if they simplify or speed up the implementation

**What you CANNOT modify:**

- `eval/`
- `prepare.sh`
- `performance/`
- `test/`
- `reference-pr/`
- `.ruby-version`, `Gemfile`, `liquid.gemspec`, `Rakefile`
- No whole-document memoization keyed by full template source, template name, or file path. The task is about making Liquid itself faster, not skipping repeated compiles via benchmark-specific caches.
- No benchmark-detection code: `lib/` must not reference eval internals (salt patterns, benchmark harness names, etc.).

**The goal: maximize `efficiency_score`.** Correctness is a hard gate: if any of the 975 tests fail, the run is invalid.

`efficiency_score` is defined as the geometric mean of the latency-improvement ratio and the allocation-improvement ratio:

```text
sqrt(
  (pr_baseline_combined_us_for_this_machine / combined_us) *
  (pr_baseline_allocations_for_this_machine / allocations)
)
```

where `pr_baseline_combined_us_for_this_machine` and `pr_baseline_allocations_for_this_machine` are freshly measured from `reference-pr/` during the same eval run.

This means:

- `1.0` = matches the PR-head starting point for this task
- `> 1.0` = better than baseline
- a run only scores highly if it improves time and allocations together
- very lopsided gains are damped compared with a raw product score
- parse-result caches that make repeated identical compiles trivial are explicitly out of scope

**Simplicity criterion**: all else being equal, simpler changes are better.

**Hive scoring note**: Hive sorts scores descending, which matches this task directly. Submit `efficiency_score` as the run score.

Because the PR baseline is rerun every eval, `efficiency_score` is directly comparable only across runs from the same evaluator setup.

## Output format

The eval prints a machine-local summary like:

```text
---
efficiency_score: 1.449240
pr_baseline_combined_us: 13478
pr_baseline_allocations: 25792
combined_us:      6507
parse_us:         3572
render_us:        2935
allocations:      25436
correct:          975
total:            975
valid:            true
```

## Logging results

Log each experiment to `results.tsv` (tab-separated):

```text
commit	efficiency_score	combined_us	parse_us	render_us	allocations	status	description
a1b2c3d	1.000000	13478	3596	9882	25792	keep	recomputed PR baseline on this machine
b2c3d4e	1.449240	6507	3572	2935	25436	keep	date filter cache with mixed-case dynamic-keyword safety
c3d4e5f	ERROR	ERROR	0	0	0	crash	broken tokenizer edge case
```

1. git commit hash (short, 7 chars)
2. `efficiency_score` or `ERROR`
3. `combined_us` or `ERROR`
4. `parse_us`
5. `render_us`
6. `allocations`
7. `status`: `keep`, `discard`, or `crash`
8. short description of the change

## The experiment loop

LOOP FOREVER:

1. **THINK** — inspect `results.tsv`, the hot paths in `lib/`, and the benchmark harness. Focus on real parser, tokenizer, render-loop, and allocation improvements rather than memoizing whole templates.
2. Modify files under `lib/`.
3. git commit
4. Run: `bash eval/eval.sh > run.log 2>&1`
5. Read results: `grep "^efficiency_score:\|^combined_us:\|^allocations:\|^valid:" run.log`
6. If `valid: false` or the metric is missing, inspect `tail -n 100 run.log`.
7. Record the result in `results.tsv` (do not commit `results.tsv`).
8. Keep the commit only if `efficiency_score` improved and `valid: true`. Otherwise revert it.

## Optimization Ideas

- Reduce parser allocations in `Tokenizer`, `Variable`, `VariableLookup`, and the expression parsing stack.
- Reuse scanners or cursor-like objects instead of repeatedly constructing temporary state.
- Avoid unnecessary string copies and intermediate arrays.
- Fast-path common render cases for primitive values, short filter chains, and simple conditions.
- Use the benchmark's split between parse and render time to tell whether a change helps compilation, rendering, or both.
