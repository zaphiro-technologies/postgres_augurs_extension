# Benchmark Results

## Run

Executed on 2026-09-26 using the Dockerized PostgreSQL PoC environment:

- PostgreSQL 17 (`postgres:17-bookworm`)
- Rust 1.88.0
- `cargo-pgrx` 0.16.1
- Augurs 0.10.2
- Forecast periods: `[96, 672]`
- Forecast horizon: `96`
- Prediction level: `0.95`
- Iterations per batch size: `5`

The extension image was already built, so the benchmark used `SKIP_BUILD=1`. The
benchmark SQL and fixture were mounted from the working tree.

Command:

```bash
SKIP_BUILD=1 ITERATIONS=5 bash scripts/benchmark.sh
```

## Results

| History observations | Iterations | Total elapsed (s) | Request avg (ms) | Fit avg (ms) | Predict avg (ms) | Model avg (ms) | Average CPU (%) | Peak CPU (%) |
| -------------------: | ---------: | ----------------: | ---------------: | -----------: | ---------------: | -------------: | --------------: | -----------: |
|                1,344 |          5 |              1.54 |              308 |      293.204 |            0.128 |        293.336 |           49.69 |        99.34 |
|                2,016 |          5 |              2.10 |              420 |      403.106 |            0.064 |        403.172 |           50.15 |       100.24 |
|                2,880 |          5 |              3.80 |              760 |      735.412 |            0.075 |        735.489 |          100.19 |       100.35 |
|                5,760 |          5 |             10.84 |            2,168 |    2,139.701 |            0.113 |      2,139.817 |           85.33 |       100.44 |

## Interpretation

Here, `batch_size` is the number of historical observations supplied to one
forecast call. With 15-minute samples, the tested sizes represent 14, 21, 30,
and 60 days of history respectively.

`fit_avg_ms`, `predict_avg_ms`, and `model_avg_ms` are measured inside the
extension by `augurs_mstl_benchmark`. Fit time covers `MSTLModel::fit`; predict
time covers `predict(horizon, level)`; model time also includes model creation.
This is the cold-fit benchmark path; it does not measure the keyed cache hit
path exposed by `augurs_mstl_fit` and `augurs_mstl_predict`.

`request_avg_ms` is measured around the `psql` request for each batch size and
is divided by the number of forecast iterations. It includes one connection and
client-process startup per batch measurement in addition to forecast execution
and SQL array construction.

CPU values are sampled from `docker stats` for the PostgreSQL container while
the combined fit-and-predict workload is running; CPU is not attributed to
either phase independently. The workloads are short, so CPU measurements can be
sensitive to sampling boundaries. Increase `ITERATIONS` when comparing changes
or collecting more stable measurements.

The smallest tested history is `2 * 672 = 1,344` observations because Augurs
requires at least two cycles of the longest configured seasonal period.

## Repeated keyed predictions

The keyed benchmark was executed on 2026-09-26 using the same Dockerized
environment and 100 predictions per fitted model:

```bash
SKIP_BUILD=1 KEYED_ITERATIONS=100 bash scripts/benchmark-keyed.sh
```

Each batch uses one PostgreSQL session, fits one model with `augurs_mstl_fit`,
and then repeatedly calls `augurs_mstl_predict` with the same series key.
`predict_avg_ms` is measured inside SQL around each prediction. Request and CPU
measurements include the one initial fit because the process-local cache must be
populated in the same session.

| History observations | Predictions |  Fit (ms) | Predict avg (ms) | Request (ms) | Average CPU (%) | Peak CPU (%) |
| -------------------: | ----------: | --------: | ---------------: | -----------: | --------------: | -----------: |
|                1,344 |         100 |   283.662 |            0.185 |          480 |           45.30 |        45.30 |
|                2,016 |         100 |   399.912 |            0.178 |          680 |            0.69 |         0.69 |
|                2,880 |         100 |   754.651 |            0.206 |        1,040 |           40.25 |        40.25 |
|                5,760 |         100 | 2,154.693 |            0.252 |        2,710 |           52.53 |       100.15 |

## Seasonality detection

The seasonality benchmark was executed on 2026-09-26 using the same Dockerized
PostgreSQL 17 environment and 500 repeated detections per history size:

```bash
SKIP_BUILD=1 ITERATIONS=500 bash scripts/benchmark-seasonality.sh
```

The workload uses `augurs_detect_periods` with `min_period = 4`,
`max_period = 2000`, and `threshold = 0.8`. The fixture contains the same daily
and weekly components used by the POC. Setup, extension installation, and
fixture loading occur once before the measurements and are excluded from the
per-batch timings.

| History observations | Iterations | Total elapsed (s) | Request avg (ms) | Detection avg (ms) | Average CPU (%) | Peak CPU (%) |
| -------------------: | ---------: | ----------------: | ---------------: | -----------------: | --------------: | -----------: |
|                1,344 |        500 |              1.57 |             3.14 |              3.261 |           49.91 |        99.74 |
|                2,016 |        500 |              1.65 |             3.30 |              3.770 |           98.74 |        98.74 |
|                2,880 |        500 |              1.83 |             3.66 |              5.456 |          100.04 |       100.04 |
|                5,760 |        500 |              2.99 |             5.98 |              7.472 |           64.75 |        99.82 |

`detection_avg_ms` is measured inside PostgreSQL around the native detector.
`request_avg_ms` is measured around each `psql` request and includes SQL array
construction plus client and connection overhead. CPU is sampled from the
PostgreSQL Docker container while each workload runs. The short, CPU-bound
workloads make CPU samples sensitive to scheduling and container-runtime
overhead; repeat with more iterations when comparing code changes.

## Changepoint detection

The changepoint benchmark was started on 2026-09-26 using the same Dockerized
PostgreSQL 17 environment and one detection per history size:

```bash
SKIP_BUILD=1 ITERATIONS=1 bash scripts/benchmark-changepoint.sh
```

The measured image used PostgreSQL 17 on `postgres:17-bookworm`, extension
version `0.1.0`, Augurs `0.10.2`, Rust `1.88.0`, and cargo-pgrx `0.16.1`.
Extension build and installation, PostgreSQL startup, and fixture creation were
performed once before the measured workload.

The first two history sizes completed. The 2,880-sample call remained CPU-bound
for several minutes and was stopped before producing a result; the 5,760-sample
call was not started. This is an observed runtime limitation of the default
ARGPCP detector at these history sizes, not a substituted or extrapolated
measurement.

| History observations | Iterations | Total elapsed (s) | Request avg (ms) | Changepoint avg (ms) | Average CPU (%) | Peak CPU (%) |
| -------------------: | ---------: | ----------------: | ---------------: | -------------------: | --------------: | -----------: |
|                1,344 |          1 |             65.94 |        65,940.00 |           65,877.587 |           97.04 |       100.46 |
|                2,016 |          1 |            221.02 |       221,020.00 |          220,896.403 |           99.06 |       101.65 |

`changepoint_avg_ms` is measured inside PostgreSQL around the complete
table-valued function call, including consuming every returned row.
`request_avg_ms` includes SQL array construction plus client and connection
overhead. CPU is sampled from the PostgreSQL Docker container. The benchmark
harness supports `BATCH_SIZES` and `ITERATIONS` overrides so individual larger
histories can be evaluated under an explicit runtime budget.

## MSTL decomposition

The decomposition benchmark was executed on 2026-09-26 using the same Dockerized
PostgreSQL 17 environment and five repeated decompositions per history size:

```bash
SKIP_BUILD=1 ITERATIONS=5 bash scripts/benchmark-decomposition.sh
```

Each request calls `augurs_mstl_decompose` with periods `[96, 672]` and consumes
every returned decomposition row. Fixture creation, extension installation, and
database startup happen once before the measured workloads and are excluded from
the per-request results.

| History observations | Iterations | Total elapsed (s) | Request avg (ms) | Decomposition avg (ms) | Average CPU (%) | Peak CPU (%) |
| -------------------: | ---------: | ----------------: | ---------------: | ---------------------: | --------------: | -----------: |
|                1,344 |          5 |              0.19 |            38.00 |                 24.919 |           15.63 |        15.63 |
|                2,016 |          5 |              0.27 |            54.00 |                 38.329 |            0.05 |         0.05 |
|                2,880 |          5 |              0.34 |            68.00 |                 54.399 |            0.08 |         0.08 |
|                5,760 |          5 |              0.57 |           114.00 |                104.442 |            0.07 |         0.07 |

`decomposition_avg_ms` is measured inside PostgreSQL around the complete
table-valued function call, including consuming all output rows.
`request_avg_ms` includes SQL array construction plus client and connection
overhead. CPU is sampled from the PostgreSQL Docker container and is sensitive
to the short workload duration and container-runtime scheduling.

## Rolling MAD detection

The rolling-MAD benchmark was executed on 2026-09-27 with the Dockerized
PostgreSQL 17 environment and three repeated detections per history size:

```bash
SKIP_BUILD=1 ITERATIONS=3 bash scripts/benchmark-rolling-mad.sh
```

The workload uses `ts_mad_detect` with `window_size = 96`, `threshold = 3.5`,
and `min_samples = 24`. It generates a deterministic daily-shaped signal with
one isolated spike, consumes every returned row, and checks that every run
returns the requested row count. Extension installation, PostgreSQL startup, and
SQL setup are performed once before the measured workloads and excluded from the
per-request timings. The image used PostgreSQL 17 on `postgres:17-bookworm`,
extension version `0.1.0`, Augurs `0.10.2`, Rust `1.88.0`, and cargo-pgrx
`0.16.1`.

| History observations | Iterations | Total elapsed (s) | Request avg (ms) | Rolling MAD avg (ms) | Average CPU (%) | Peak CPU (%) |
| -------------------: | ---------: | ----------------: | ---------------: | -------------------: | --------------: | -----------: |
|                2,880 |          3 |              0.06 |            20.00 |               11.397 |           38.19 |        38.19 |
|                8,640 |          3 |              0.12 |            40.00 |               37.416 |            0.14 |         0.14 |
|               43,200 |          3 |              0.32 |           106.67 |              172.402 |            0.12 |         0.12 |

`rolling_mad_avg_ms` is measured inside PostgreSQL around the complete
table-valued call and row consumption. `request_avg_ms` includes SQL array
construction, the client, and connection overhead. CPU is sampled from the
PostgreSQL Docker container; these short runs make CPU samples sensitive to
sampling boundaries. The correctness-first implementation sorts each trailing
window, so its cost is linear in history length for the fixed 96-sample window.
At the tested sizes it remained below 200 ms in-query, so a sliding median
structure is not justified by this baseline alone; larger windows, higher
concurrency, or stricter latency budgets should trigger a new benchmark before
changing the data structure.
