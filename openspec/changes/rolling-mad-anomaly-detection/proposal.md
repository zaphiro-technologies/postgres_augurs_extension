## Why

The extension can currently expose forecasts, decomposition, seasonality, and
changepoint indexes, but it has no primitive for identifying individual
observations that depart from a recent robust baseline. Augurs already ships an
outlier/MAD facility, so this change should first build on the pinned library
capability and add only the rolling-window adapter semantics that it does not
provide.

## What Changes

- Add a stateless table-valued `ts_mad_detect` function over an ordered
  PostgreSQL `float8[]`.
- Enable and evaluate Augurs' existing `outlier` capability as the algorithm
  foundation, reusing it where its behavior matches the SQL contract.
- Evaluate each sample against the preceding `window_size` values only;
  return one aligned row per input sample with median, MAD, bounds, score,
  outlier, and readiness fields.
- Support PostgreSQL defaults of threshold `3.5` and `min_samples =
  window_size`, with explicit warm-up rows and deterministic zero-MAD handling.
- Reject empty, NULL, non-finite, or invalidly configured inputs without
  interpolation, resampling, timestamp interpretation, event creation, or
  persistence.
- Add focused Rust tests, Dockerized SQL contract assertions, representative
  rolling-MAD benchmarks, and README usage/compatibility guidance.

## Capabilities

### New Capabilities

- `db-native-rolling-mad-anomaly-detection`: Detect point anomalies using a
  trailing robust median/MAD baseline supplied by the SQL caller.

### Modified Capabilities

<!-- Existing changepoint and time-series analytics contracts remain unchanged;
     this detector is intentionally a separate capability. -->

## Impact

- Adds a new pgrx/PostgreSQL API and generated extension SQL function.
- Adds the pinned Augurs outlier feature and any required transitive
  dependencies, with a thin rolling adapter where Augurs' current global
  detector does not provide the required window semantics.
- Extends the existing Rust unit-test, `sql/poc.sql`, Docker smoke-test, and
  benchmark/documentation workflows.
- The SQL-to-Rust array boundary is the relevant trust boundary. The function
  performs no authentication, authorization, persistence, relation lookup, or
  secret handling; security checks cover input validation, secret scanning,
  workflow/dependency checks, and resource-cost evidence.
