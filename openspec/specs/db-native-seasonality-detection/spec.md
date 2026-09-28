# db-native-seasonality-detection Specification

## Purpose

Provide a SQL boundary for detecting likely seasonal periods in an ordered,
regularly sampled series so callers can feed those periods into forecasting
functions without implementing periodogram analysis themselves.

## Requirements

### Requirement: The capability SHALL expose SQL seasonality detection

The capability SHALL expose `augurs_detect_periods` with a required `float8[]`
values argument and nullable `integer` `min_period`, `max_period`, and `float8`
`threshold` arguments that default to `NULL` when omitted. It SHALL return an
`integer[]` containing seasonal periods expressed as numbers of samples.

#### Scenario: Detect periods with native defaults

- **WHEN** a caller invokes `augurs_detect_periods(ordered_values)` without
  optional configuration arguments
- **THEN** the function detects periods using the underlying detector defaults
  and returns an integer array of sample periods

#### Scenario: Detect periods with explicit configuration

- **WHEN** a caller invokes
  `augurs_detect_periods(ordered_values, 4, 1000, 0.8)`
- **THEN** the function applies those configuration values and returns the
  detector's detected sample periods

### Requirement: Detection SHALL use the caller-provided regular series

The function SHALL treat `values` as an already ordered, regularly sampled time
series. It SHALL not query application tables, inspect timestamps, infer a
sampling interval, resample values, interpolate gaps, or apply domain-specific
transformations.

#### Scenario: Query-built series is detected

- **WHEN** a caller orders and aggregates a TimescaleDB series in SQL and passes
  the resulting array to `augurs_detect_periods`
- **THEN** detection uses only that array and does not require a relation,
  entity identifier, or timestamp argument inside the extension

#### Scenario: Caller owns regularization

- **WHEN** the caller supplies a series with missing or irregular samples
- **THEN** the function does not repair or reinterpret the series and the caller
  remains responsible for preparing valid detector input

### Requirement: The adapter SHALL delegate detection and preserve detector semantics

The implementation SHALL delegate period detection to Augurs'
`PeriodogramDetector`. Omitted `min_period`, `max_period`, and `threshold`
arguments SHALL preserve the detector's native defaults. Supplied finite
threshold values SHALL preserve the native detector's clamping behavior.

#### Scenario: Native detector is used

- **WHEN** the function receives a valid values array and optional configuration
- **THEN** it invokes the native periodogram detector rather than reimplementing
  peak or seasonality detection in the extension

#### Scenario: Threshold follows native clamping

- **WHEN** a finite threshold outside the detector's normal range is supplied
- **THEN** the value is handled according to the native detector's documented
  clamping behavior instead of being transformed by a separate extension
  algorithm

### Requirement: Invalid input SHALL fail without returning a partial result

The function SHALL reject an empty values array, non-finite values, non-positive
provided periods, a `min_period` greater than `max_period`, and non-finite
thresholds. It SHALL return a clear PostgreSQL error and no partial array.

#### Scenario: Empty or non-finite values are rejected

- **WHEN** the caller supplies an empty array or an array containing `NaN` or an
  infinity
- **THEN** the function fails with an input-validation error

#### Scenario: Invalid period bounds are rejected

- **WHEN** the caller supplies a non-positive period or a `min_period` greater
  than `max_period`
- **THEN** the function fails with an input-validation error before running
  detection

#### Scenario: Non-finite threshold is rejected

- **WHEN** the caller supplies `NaN` or infinity as `threshold`
- **THEN** the function fails with an input-validation error

### Requirement: The result SHALL be a direct SQL array of detected sample periods

For a valid request, the function SHALL return one PostgreSQL `integer[]` value.
The array SHALL preserve the order returned by the native detector and SHALL be
empty when no periods are detected. The function SHALL not attach timestamps,
confidence scores, or explanatory metadata in this PoC. The adapter SHALL not
round or canonicalize the native period estimates.

#### Scenario: Daily and weekly periods are detected

- **WHEN** the caller supplies a sufficiently long 15-minute series with daily
  and weekly seasonality and requests `min_period => 4`, `max_period => 2000`,
  and `threshold => 0.8`
- **THEN** the result contains the native approximate candidates `97` and `682`,
  corresponding approximately to one day (`96` samples) and one week (`672`
  samples), without extension-side rounding

#### Scenario: No periods are detected

- **WHEN** the native detector finds no qualifying seasonal peaks
- **THEN** the function returns an empty `integer[]` rather than `NULL` or
  fabricated periods
