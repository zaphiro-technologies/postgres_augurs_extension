# PostgreSQL Augurs Extension

A proof of concept for running [Augurs](https://github.com/grafana/augurs)
time-series operations directly inside PostgreSQL. The extension accepts ordered
`float8[]` histories and returns forecast or analysis rows; it does not query
application tables or persist results.

The current implementation is pinned to Augurs `0.10.2`. This extension
currently enables Augurs' `ets`, `mstl`, `seasons`, `outliers` and `changepoint`
capabilities.

## Why put time-series analytics in PostgreSQL?

SynchroGuard already stores and queries operational measurements in a database.
Putting selected analytics next to that data provides a small, composable
execution boundary for advanced time-series operations:

- SQL can select, aggregate, order, and filter the relevant asset history, then
  pass it directly to an analytics function without a second data-extraction
  pipeline.
- Forecasts, decompositions, detected periods, and changepoint indexes can be
  joined back to the source rows in the same query, preserving traceability from
  an analytical result to the original measurement window.
- The database remains the integration point for permissions, transactions,
  query scheduling, and downstream dashboard or service access; this extension
  does not introduce a parallel persistence system.
- Rust and Augurs provide reusable, tested numerical implementations while
  PostgreSQL exposes a familiar interface to SynchroGuard services and
  operators.

## SynchroGuard scenarios

The functions are intended as building blocks for scenarios such as:

- forecasting transformer, feeder, voltage, power, or power-quality histories
  selected by a dashboard or operational query;
- detecting likely seasonal periods before configuring a daily or weekly
  forecast;
- decomposing a measurement into trend, seasonal components, and remainder so a
  service can compare actual behavior with an expected baseline;
- identifying regime changes in loading, voltage, calibration, or feeder
  behavior with changepoint indexes; and
- fitting one model and serving repeated predictions for the same series in a
  PostgreSQL backend session.

## Augurs integration

The PostgreSQL functions are thin adapters around selected Augurs capabilities:

- forecasting and decomposition use
  [MSTL](https://docs.rs/augurs/0.10.2/augurs/mstl/index.html) with
  [ETS](https://docs.rs/augurs/0.10.2/augurs/ets/index.html) for the trend
  model;
- period discovery uses the
  [seasonality detector](https://docs.rs/augurs/0.10.2/augurs/seasons/index.html);
  and
- regime-change detection uses
  [Augurs changepoint detection](https://docs.rs/augurs/0.10.2/augurs/changepoint/index.html).

The adapter owns PostgreSQL input validation, row shape, defaults, and index
alignment. Augurs owns the numerical model semantics within the pinned release.
When those semantics do not match a required SQL contract, the difference must
be made explicit in the OpenSpec change and covered by tests and benchmarks.

## Functions

### `augurs_detect_periods`

#### Summary

```sql
augurs_detect_periods(
    values     float8[],
    min_period integer DEFAULT NULL,
    max_period integer DEFAULT NULL,
    threshold  double precision DEFAULT NULL
)
RETURNS integer[]
```

Delegates to Augurs' native `PeriodogramDetector` and returns detected periods
as numbers of samples. Omitted options preserve Augurs' native defaults.

The input must already be ordered and regularly sampled. The extension does not
query timestamps, infer the sampling interval, resample, interpolate, or round
native periodogram estimates to canonical periods. A sufficiently long synthetic
15-minute history currently produces native candidates such as `97` and `682`,
approximately one day (`96`) and one week (`672`).

#### Scenario

Use this when the seasonal periods are not known ahead of time. Pass the
returned integer array directly to `augurs_mstl_decompose` or use it to choose
periods for a forecast.

#### Example

Use positional arguments in SQL examples because `values` is a PostgreSQL
reserved keyword for named notation:

```sql
SELECT augurs_detect_periods(
    ARRAY(
        SELECT avg_value
        FROM transformer_loading_15m
        WHERE transformer_id = $1
        ORDER BY bucket
    ),
    4,
    2000,
    0.8
);
```

The function rejects empty or non-finite histories, non-positive bounds, a
minimum period greater than the maximum, and non-finite thresholds.

### `augurs_detect_changepoints`

#### Summary

```sql
augurs_detect_changepoints(
    values float8[]
)
RETURNS TABLE (
    index integer
)
```

Delegates to Augurs' native default ARGPCP detector and returns zero-based
sample indexes. Index `0` is always included as the start of the input; every
other returned index identifies the sample immediately before a detected regime
change. A returned index is a changepoint, not an anomaly score or an anomalous
observation.

The input must already be ordered and regularly sampled. The caller owns the
mapping from sample indexes to timestamps; the extension does not query
timestamps, resample, interpolate, detect anomalies, or persist detector state.
The detector is stateless and domain-neutral.

#### Example

```sql
WITH series AS (
    SELECT
        row_number() OVER (ORDER BY bucket)::integer - 1 AS index,
        bucket,
        avg_value
    FROM transformer_loading_15m
    WHERE transformer_id = $1
), changes AS (
    SELECT index
    FROM augurs_detect_changepoints(
        ARRAY(SELECT avg_value FROM series ORDER BY index)
    )
)
SELECT changes.index, series.bucket AS change_before
FROM changes
JOIN series USING (index)
WHERE changes.index > 0
ORDER BY changes.index;
```

The function rejects empty histories, histories shorter than four samples, NULL
elements, and non-finite values without returning partial output.

### `ts_mad_detect`

Augurs `0.10.2` also contains a native `MADDetector` in its outlier package.
That detector computes one global, asymmetric band for an aligned series; it
does not provide a preceding rolling window, SQL `min_samples` warm-up, or the
zero-MAD row contract below. `ts_mad_detect` therefore keeps the exact rolling
adapter semantics local while reusing the pinned Augurs outlier capability as
the evaluated algorithm reference.

#### Summary

```sql
ts_mad_detect(
    values       float8[],
    window_size  integer,
    threshold    double precision DEFAULT 3.5,
    min_samples  integer DEFAULT NULL
)
RETURNS TABLE (
    index       integer,
    median      double precision,
    mad         double precision,
    lower_bound double precision,
    upper_bound double precision,
    score       double precision,
    is_outlier  boolean,
    is_ready    boolean
)
```

Returns exactly one zero-based row for each input array position. For position
`i`, the baseline is the preceding `window_size` samples, ending at `i - 1`; the
current value is never included. The baseline median and median absolute
deviation use conventional midpoint medians for even sample counts. Bounds use
the robust scale factor `1.4826`, and `is_outlier` is true only when the score
is strictly greater than `threshold`.

`min_samples` defaults to `window_size` and must be between `1` and
`window_size`. Before that many preceding samples are available, the row has
`is_ready = false` and NULL statistical fields and outlier flag. A matching
zero-MAD value has a zero score and `is_outlier = false`; a different value has
NULL score and `is_outlier = true`, with both bounds equal to the median.

The input must be a non-empty, finite, NULL-free, already ordered history. The
function does not query timestamps, resample, interpolate, reorder, persist
state, generate events, detect seasonality or changepoints, compare peers, or
implement Grafana-specific behavior. Map `index` back to timestamps in the
calling query:

```sql
WITH series AS (
    SELECT
        row_number() OVER (ORDER BY bucket)::integer - 1 AS index,
        bucket,
        avg_value AS value
    FROM transformer_loading_15m
    WHERE transformer_id = $1
), detected AS (
    SELECT *
    FROM ts_mad_detect(
        ARRAY(SELECT value FROM series ORDER BY index),
        96
    )
)
SELECT s.bucket, s.value, d.median, d.score, d.is_outlier, d.is_ready
FROM series AS s
JOIN detected AS d USING (index)
ORDER BY s.bucket;
```

The same function can consume an MSTL `remainder` array when the caller wants to
score deviations after removing the modeled trend and seasonal components.

### `augurs_mstl_decompose`

#### Summary

```sql
augurs_mstl_decompose(
    values  float8[],
    periods integer[]
)
RETURNS TABLE (
    index     integer,
    trend     double precision,
    seasonal  double precision[],
    remainder double precision
)
```

Fits the native Augurs MSTL model and returns one row per input sample. The
result is stateless and uses the native decomposition without additional
rounding:

- `index` is zero-based and matches the input array position.
- `seasonal[1]` corresponds to `periods[1]`, `seasonal[2]` to `periods[2]`, and
  so on.
- Periods are sample counts, not time intervals.
- The caller is responsible for ordering the history and joining the result back
  to timestamps.

The native decomposition uses `f32` internally; the returned components are
converted to PostgreSQL `float8` values. The extension does not add an
`expected` column or interpret the remainder as an anomaly score.

#### Scenario

Use this to inspect the in-sample trend, each seasonal component, and the
remainder for a known set of seasonal periods. Provide at least two complete
cycles for every period.

#### Example

```sql
SELECT *
FROM augurs_mstl_decompose(
    ARRAY(
        SELECT avg_value
        FROM transformer_loading_15m
        WHERE transformer_id = $1
        ORDER BY bucket
    ),
    ARRAY[96, 672]
);
```

The function rejects empty or non-finite values, NULL array elements, empty or
too-small periods, and histories shorter than two cycles of any requested
period.

### `augurs_mstl_forecast`

#### Summary

```sql
augurs_mstl_forecast(
    values  float8[],
    periods integer[],
    horizon integer,
    level   double precision
)
RETURNS TABLE (
    step  integer,
    point double precision,
    lower double precision,
    upper double precision
)
```

Fits and predicts in one call using the native sequence:

```text
MSTLModel::new(periods, AutoETS::non_seasonal().into_trend_model())
    -> fit(values)
    -> predict(horizon, level)
```

`step` is one-based. A non-NULL `level` produces prediction bounds; `NULL`
produces point forecasts with NULL bounds. The function does not persist the
fitted model.

#### Scenario

Use this for an independent forecast request where the history is available in
the same query and the fitted model will not be reused.

#### Example

```sql
SELECT *
FROM augurs_mstl_forecast(
    ARRAY(
        SELECT value
        FROM transformer_loading_15m
        WHERE transformer_id = $1
        ORDER BY bucket
    ),
    ARRAY[96, 672],
    96,
    0.95
);
```

The function rejects empty or non-finite histories, empty or non-positive
periods, non-positive horizons, and levels outside the open interval `(0, 1)`.

### `augurs_mstl_fit`

#### Summary

```sql
augurs_mstl_fit(
    series_key text,
    values     float8[],
    periods    integer[]
)
RETURNS TABLE (
    series_key      text,
    model_version   bigint,
    reused          boolean,
    training_points integer,
    fit_ms          double precision
)
```

Fits a keyed MSTL model and stores it in a bounded, process-local cache. A fit
is reused only when the `series_key`, values, and periods all match. A new fit
for an existing key replaces that key after fitting succeeds. The cache holds up
to four fitted models and is not durable storage.

#### Scenario

Use this when a series will receive multiple predictions with different horizons
or confidence levels. Keep the fit and subsequent predictions in the same
PostgreSQL backend session so the process-local cache is available.

#### Example

```sql
SELECT *
FROM augurs_mstl_fit(
    'transformer:T1:loading:15m',
    ARRAY(
        SELECT value
        FROM transformer_loading_15m
        WHERE transformer_id = 'T1'
        ORDER BY bucket
    ),
    ARRAY[96, 672]
);
```

The first call reports `reused = false`; an identical subsequent call reports
`reused = true` and the same `model_version`.

### `augurs_mstl_predict`

#### Summary

```sql
augurs_mstl_predict(
    series_key text,
    horizon    integer,
    level      double precision
)
RETURNS TABLE (
    step  integer,
    point double precision,
    lower double precision,
    upper double precision
)
```

Predicts from the cached model identified by `series_key`. Its output and
nullable-bound behavior match `augurs_mstl_forecast`: `step` is one-based, and
NULL `level` returns point forecasts without bounds.

#### Scenario

Use this after `augurs_mstl_fit` when the same fitted model must serve repeated
forecast requests. The function errors if the keyed model is not present in the
current process.

#### Example

```sql
SELECT *
FROM augurs_mstl_predict(
    'transformer:T1:loading:15m',
    96,
    0.95
);
```

### `augurs_mstl_benchmark`

#### Summary

```sql
augurs_mstl_benchmark(
    values  float8[],
    periods integer[],
    horizon integer,
    level   double precision
)
RETURNS TABLE (
    fit_ms        double precision,
    predict_ms    double precision,
    model_ms      double precision,
    forecast_rows integer
)
```

Runs the same cold fit-and-predict sequence as `augurs_mstl_forecast`, while
exposing separate fit and predict timings, total model time, and the forecast
row count. It does not populate the keyed cache or persist a fitted model.

#### Scenario

Use this for in-query instrumentation when comparing history sizes or model
changes. The shell benchmarks add request timing and PostgreSQL container CPU
sampling around this function.

#### Example

```sql
SELECT *
FROM augurs_mstl_benchmark(
    ARRAY(
        SELECT value
        FROM transformer_loading_15m
        ORDER BY bucket
    ),
    ARRAY[96, 672],
    96,
    0.95
);
```

## Combined usage

### Detect periods, then decompose

Detection and decomposition can be composed directly in SQL. The query keeps the
source sample index so the zero-based decomposition rows can be joined back to
their timestamps:

```sql
WITH series AS (
    SELECT
        row_number() OVER (ORDER BY bucket) - 1 AS sample_index,
        bucket,
        avg_value AS value
    FROM transformer_loading_15m
    WHERE transformer_id = $1
      AND bucket >= now() - interval '90 days'
), detected AS (
    SELECT augurs_detect_periods(
        ARRAY(SELECT value FROM series ORDER BY sample_index),
        4,
        2000,
        0.8
    ) AS periods
), decomposition AS (
    SELECT *
    FROM augurs_mstl_decompose(
        ARRAY(SELECT value FROM series ORDER BY sample_index),
        (SELECT periods FROM detected)
    )
)
SELECT
    s.bucket AS time,
    s.value AS actual,
    d.trend,
    d.seasonal,
    d.remainder
FROM series AS s
JOIN decomposition AS d ON d.index = s.sample_index
ORDER BY s.bucket;
```

When needed, derive the expected value in the query as the trend plus the sum of
all seasonal components. The extension leaves that interpretation to the caller.

### Fit once, predict repeatedly

Fit and predict can be separated when a keyed model is reused. The fit and
prediction calls need to run in the same backend process:

```sql
SELECT *
FROM augurs_mstl_fit(
    'transformer:T1:loading:15m',
    ARRAY(
        SELECT value
        FROM transformer_loading_15m
        WHERE transformer_id = 'T1'
        ORDER BY bucket
    ),
    ARRAY[96, 672]
);

SELECT *
FROM augurs_mstl_predict('transformer:T1:loading:15m', 96, 0.95);
```

## Development workflow with OpenSpec

This repository uses the spec-driven
[OpenSpec](https://github.com/Fission-AI/OpenSpec) workflow so that an analytics
API is agreed before it becomes PostgreSQL surface area. The repository rules
and required evidence live in [`openspec/config.yaml`](openspec/config.yaml).

For a behavior or API change:

1. Create a named change under `openspec/changes/<change-name>/`.
2. Write `proposal.md` to explain the problem, scope, compatibility impact,
   expected tests, benchmark impact, documentation, and security checks.
3. Define or update delta specs for the externally visible contract. Keep the
   proposal and design focused on requirements and technical decisions; put
   sequencing and completion checks in `tasks.md`.
4. Use `design.md` to record the adapter boundary, data-handling risks, test
   strategy, and reproducible benchmark method.
5. Validate the change before implementation:

   ```bash
   openspec validate --changes --strict
   ```

6. Implement the tasks incrementally. For this project, the normal evidence is
   `cargo fmt --check`, `cargo test --locked`, Clippy, the Dockerized SQL smoke
   test, affected benchmarks, and deterministic secret/dependency/workflow
   checks as applicable.
7. Update the README and benchmark report when the SQL contract or measured
   behavior changes. Re-run validation and review the generated PostgreSQL
   signature before marking the change complete.
8. Archive a completed change only after its tasks and required evidence are
   complete. Archived changes provide the history for subsequent proposals; they
   are not a substitute for current implementation or benchmark checks.

## Future evolution

The current extension is intentionally small. Possible next steps include:

- **More Augurs capabilities.** Evaluate Augurs outlier detection, clustering,
  dynamic time warping, Prophet-compatible forecasting, and additional
  diagnostics where the pinned release and PostgreSQL row/array model provide a
  useful contract. Each addition should include a clear mapping from native
  semantics to SQL semantics, validation, and a cost benchmark.
- **Automatic model lifecycle management.** Introduce versioned model metadata,
  fit/retrain policies, freshness and drift checks, invalidation, retention,
  rollback, and resource limits. The lifecycle should be policy-driven and
  observable; a process-local cache such as `augurs_mstl_fit` is not durable
  lifecycle management.

## Quick start

The reproducible development environment uses PostgreSQL 17, Rust 1.88,
`cargo-pgrx` 0.16.1, and Augurs 0.10.2.

Build the image and run the complete SQL smoke test:

```bash
bash scripts/poc.sh
```

The script builds `postgres-augurs-extension:poc`, starts an isolated PostgreSQL
container, installs the extension, and executes `sql/poc.sql`. The smoke test
covers forecasting, keyed fit/predict reuse, seasonality detection,
decomposition, reconstruction, nullable bounds, and invalid-input behavior. The
SQL fixtures are mounted read-only for this test and are not included in the
production image.

## CI and PostgreSQL packages

The supported build matrix currently targets PostgreSQL 17 on Debian Bookworm
with Rust 1.88.0, `cargo-pgrx` 0.16.1, and Augurs 0.10.2. The CI workflow
mirrors the Dockerized toolchain, runs formatting, tests, and Clippy, then
builds a PostgreSQL-installable package. The security workflow checks workflow
syntax, dependency changes, and repository secrets.

Build the package locally:

```bash
bash scripts/package.sh
```

This creates a versioned archive under `dist/`, for example
`postgres_augurs_extension-pg17-0.1.0-local.tar.gz`. The archive preserves the
filesystem-root layout produced by `cargo pgrx package` and contains the
PostgreSQL 17 shared library, extension control file, and generated extension
SQL file. Test the archive in a clean PostgreSQL 17 container with:

```bash
bash scripts/package-smoke.sh dist/postgres_augurs_extension-pg17-0.1.0-local.tar.gz
```

On a compatible PostgreSQL 17 installation, install the archive as root so its
`usr/lib/postgresql/17/` and `usr/share/postgresql/17/` paths are extracted at
the filesystem root:

```bash
sudo tar -xzf postgres_augurs_extension-pg17-0.1.0-local.tar.gz -C /
```

The GitHub Actions package is a short-lived CI artifact; this workflow does not
publish a GitHub Release or claim compatibility with PostgreSQL versions other
than the version used to build the package.

## Benchmarks

Run the Dockerized cold forecast benchmark with the default history sizes and
five forecast iterations per size:

```bash
bash scripts/benchmark.sh
```

For this benchmark, `batch_size` is the number of historical observations passed
to one forecast call. The default sizes are `1344`, `2016`, `2880`, and `5760`.
The minimum default size is two cycles of the longest configured period
(`2 * 672`); smaller histories are rejected by Augurs for this model.

The output reports total elapsed time, average time per forecast, and average
and peak CPU percentage sampled from the PostgreSQL container:

```text
batch_size  iterations  elapsed_s  request_avg_ms  fit_avg_ms  predict_avg_ms  model_avg_ms  cpu_avg_pct  cpu_peak_pct
```

Customize the workload with environment variables:

```bash
BATCH_SIZES='1344 2880 5760' ITERATIONS=10 bash scripts/benchmark.sh
```

Use `SKIP_BUILD=1` when the `postgres-augurs-extension:poc` image already exists
locally:

```bash
SKIP_BUILD=1 BATCH_SIZES='1344 2880' ITERATIONS=3 bash scripts/benchmark.sh
```

Run the separate benchmarks for repeated detection, decomposition, and keyed
predictions:

```bash
SKIP_BUILD=1 ITERATIONS=500 bash scripts/benchmark-seasonality.sh
SKIP_BUILD=1 ITERATIONS=5 bash scripts/benchmark-decomposition.sh
SKIP_BUILD=1 KEYED_ITERATIONS=100 bash scripts/benchmark-keyed.sh
```

The seasonality and decomposition benchmarks measure in-query function time,
request time, and sampled PostgreSQL container CPU. The keyed benchmark fits one
model per history size and measures repeated `augurs_mstl_predict` calls in the
same session. Setup, fixture creation, extension installation, and the keyed
warm-up fit are kept separate from the repeated operation being measured where
applicable.

The latest recorded results and their interpretation are in
[benchmark.md](benchmark.md).
