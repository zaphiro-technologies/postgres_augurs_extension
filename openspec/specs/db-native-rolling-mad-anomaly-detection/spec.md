## Purpose

Provide a stateless PostgreSQL primitive that evaluates each ordered numeric
observation against a trailing, robust median/MAD baseline without timestamp,
domain, persistence, or event-generation concerns.

## Requirements

### Requirement: The capability SHALL expose an aligned rolling MAD table function

The capability SHALL expose
`ts_mad_detect(values float8[], window_size integer, threshold double precision DEFAULT 3.5, min_samples integer DEFAULT NULL)`
returning one row for every input position with `index integer`, nullable
`median`, `mad`, `lower_bound`, `upper_bound`, and `score` columns plus boolean
`is_outlier` and `is_ready` columns. The index SHALL be zero-based and preserve
the input order.

#### Scenario: A valid history returns aligned rows

- **WHEN** a caller supplies an ordered finite array and valid configuration
- **THEN** the function returns exactly one result row per input value, with
  indexes from zero through the final input position

#### Scenario: The result can be joined back to source timestamps

- **WHEN** a caller joins the result on its zero-based index to an independently
  ordered source projection
- **THEN** each detector row maps to the corresponding source observation
  without the function accepting or interpreting timestamps

### Requirement: Baselines SHALL use only preceding observations

For input position `i`, the baseline SHALL contain values from positions
`max(0, i - window_size)` through `i - 1`, excluding the current value. The
baseline median SHALL be the conventional median of that window, using the
midpoint of the two middle values for an even-sized window. MAD SHALL be the
median of the absolute deviations from that baseline median. The robust scale
factor SHALL be `1.4826`, and an observation SHALL be anomalous when its robust
score is strictly greater than `threshold`.

#### Scenario: The current sample cannot move its own baseline

- **WHEN** a value is evaluated at position `i`
- **THEN** changing only that value cannot change the median, MAD, or bounds
  reported for position `i`

#### Scenario: A known spike is detected against a stable history

- **WHEN** the preceding window contains stable values and the current value is
  an obvious spike
- **THEN** the current row reports bounds derived from the preceding values and
  `is_outlier = true`

#### Scenario: A level shift adapts over time

- **WHEN** a series changes to a sustained new level
- **THEN** early new-level observations may be outliers and later observations
  can become non-outliers as the trailing baseline fills with the new level

### Requirement: Configuration and warm-up behavior SHALL be explicit

`threshold` SHALL default to `3.5` and SHALL be strictly positive and finite.
When `min_samples` is omitted it SHALL equal `window_size`; otherwise it SHALL
be strictly positive and no greater than `window_size`. A row SHALL be ready
only when at least `min_samples` preceding observations are available. Before
readiness, all numeric detection fields and `is_outlier` SHALL be NULL while
`is_ready` SHALL be false. Ready rows SHALL set `is_ready` true.

#### Scenario: Default warm-up uses the full window

- **WHEN** the caller omits `min_samples` and supplies `window_size = 96`
- **THEN** positions before 96 preceding observations are not ready and position
  96 is the first eligible detection row

#### Scenario: A shorter explicit minimum enables earlier detection

- **WHEN** the caller supplies `window_size = 96` and `min_samples = 24`
- **THEN** position 24 is the first eligible detection row and its baseline
  still uses the available preceding values within the 96-sample trailing window

### Requirement: Bounds, scores, and zero-MAD cases SHALL be deterministic

For a ready row with non-zero MAD, bounds SHALL be
`median +/- threshold * 1.4826 * MAD`, and score SHALL be
`abs(value - median) / (1.4826 * MAD)`. `is_outlier` SHALL be true exactly when
the value is below the lower bound or above the upper bound. When MAD is zero
and the current value equals the median, the function SHALL return equal median
bounds, score `0`, and `is_outlier = false`. When MAD is zero and the current
value differs from the median, it SHALL return equal median bounds, a NULL
score, and `is_outlier = true`. The function SHALL never return NaN or infinite
numeric results.

#### Scenario: A constant window receives the matching value

- **WHEN** a ready row has MAD zero and the current value equals the baseline
  median
- **THEN** lower and upper bounds equal the median, score is zero, and the row
  is not an outlier

#### Scenario: A constant window receives a different value

- **WHEN** a ready row has MAD zero and the current value differs from the
  baseline median
- **THEN** lower and upper bounds equal the median, score is NULL, and the row
  is an outlier

### Requirement: Invalid inputs SHALL fail clearly without partial output

The function SHALL reject a NULL or empty values array, NULL elements, NaN or
infinite values, non-positive `window_size`, non-positive `threshold`, and
non-positive or greater-than-window `min_samples`. It SHALL raise a clear
PostgreSQL error and SHALL not interpolate, remove, resample, reorder, or
partially return results for invalid input.

#### Scenario: Invalid numeric history is rejected

- **WHEN** the caller supplies an empty array, NULL element, NaN, or infinity
- **THEN** the function raises an input-validation error identifying
  `ts_mad_detect`

#### Scenario: Invalid configuration is rejected

- **WHEN** the caller supplies a non-positive window, threshold, or minimum, or
  a minimum greater than the window
- **THEN** the function raises an input-validation error before detection output
  is returned

### Requirement: The detector SHALL remain stateless and domain-neutral

Each invocation SHALL depend only on its supplied values and configuration. It
SHALL not query application relations, inspect timestamps, persist windows or
results, create SynchroGuard events, perform persistence logic, classify
changepoints, decompose seasonality, or compare peer series. The API SHALL be
suitable for both historical SQL evaluation and caller-managed online-style
processing by passing the relevant history array.

#### Scenario: Independent calls do not share state

- **WHEN** two calls are made with different arrays or configurations in either
  order
- **THEN** each result is computed only from its own inputs and no prior call is
  required

#### Scenario: MSTL residuals are accepted without special handling

- **WHEN** a caller passes an ordered array of MSTL remainder values
- **THEN** the detector applies the same rolling MAD contract without knowing
  that the values are residuals
