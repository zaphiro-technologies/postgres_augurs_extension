## 1. Core rolling MAD implementation

- [ ] 1.1 Verify the pinned Augurs 0.10.2 `outlier` feature and `MADDetector` API against the rolling contract; verify the feature/build check records which public operations can be reused and why any trailing-window adapter fallback is required.
- [ ] 1.2 Add validation and configuration resolution for `ts_mad_detect`, including NULL/non-finite values, empty input, positive window and threshold checks, and `min_samples` default/range checks; verify focused Rust tests cover every rejected condition and the resolved default.
- [ ] 1.3 Implement the correctness-first trailing median/MAD helper using only the preceding window, conventional even-sample medians, scale factor `1.4826`, strict `score > threshold` detection, and finite-result checks; verify Rust tests cover known medians/MADs, current-value exclusion, spike detection, and level-shift adaptation.
- [ ] 1.4 Implement explicit warm-up and zero-MAD row construction with one zero-based row per input; verify Rust tests cover NULL warm-up fields, matching zero-MAD score `0`, differing zero-MAD NULL score with `is_outlier = true`, and no NaN/infinite output.
- [ ] 1.5 Expose the pgrx table-valued `ts_mad_detect` function with PostgreSQL defaults `threshold = 3.5` and `min_samples = NULL`; verify the generated extension SQL exposes the specified columns, types, defaults, and row order.

## 2. PostgreSQL contract and integration validation

- [ ] 2.1 Extend `sql/poc.sql` with deterministic stable, isolated-spike, sustained-level-shift, timestamp-index mapping, and MSTL-remainder-shaped calls; verify `bash scripts/poc.sh` proves one-row-per-input alignment, trailing-window semantics, warm-up, bounds, and expected outlier flags.
- [ ] 2.2 Add SQL assertions for explicit `min_samples`, default threshold behavior, even-window values, and both zero-MAD cases; verify the smoke test fails on any contract mismatch.
- [ ] 2.3 Add SQL error assertions for NULL/empty/non-finite arrays and invalid window, threshold, and minimum-sample configurations; verify each raises an `invalid ts_mad_detect input` error without partial result rows.
- [ ] 2.4 Run the complete PostgreSQL 17 Docker smoke test alongside existing forecast, seasonality, changepoint, and decomposition checks; verify `bash scripts/poc.sh` exits successfully and existing function behavior remains green.

## 3. Performance benchmark

- [ ] 3.1 Add a deterministic rolling-MAD benchmark SQL workload and Dockerized shell harness following the existing benchmark scripts; verify every measured run consumes all returned rows and reports in-query detector time, request time, and sampled PostgreSQL container CPU.
- [ ] 3.2 Run the benchmark at 2,880, 8,640, and 43,200 observations with recorded iteration counts and the documented PostgreSQL/Rust/Augurs environment; verify the output contains complete measurements for all three requested sizes.
- [ ] 3.3 Record the benchmark command, fixture/setup exclusions, results, and interpretation in `benchmark.md`; verify the report distinguishes detector cost from SQL/client/setup overhead and states whether a sliding data structure is justified.

## 4. Documentation

- [ ] 4.1 Document `ts_mad_detect` in `README.md` with its SQL signature, positional-call example, sample-count and trailing-window semantics, warm-up/default behavior, zero-MAD behavior, and index-to-timestamp mapping; verify the example matches the generated extension SQL.
- [ ] 4.2 Document direct measurement and MSTL-remainder use while stating that the function does not handle timestamps, persistence, event generation, seasonality, changepoints, or Grafana-specific behavior; verify the compatibility boundary is explicit and existing API sections remain unchanged.

## 5. Quality and security validation

- [ ] 5.1 Run `cargo fmt --check`, the focused Rust tests, the complete applicable test suite, and Clippy; verify formatting, unit coverage, and lint results are clean before implementation tasks are marked complete.
- [ ] 5.2 Run the repository's applicable workflow-lint and dependency-review checks plus deterministic secret scanning on changed files; verify the SQL input boundary has no new secret handling, unsafe relation access, or unreviewed dependency/resource policy.
