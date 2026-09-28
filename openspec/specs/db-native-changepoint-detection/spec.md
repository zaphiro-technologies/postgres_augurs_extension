# db-native-changepoint-detection Specification

## Purpose

Provide a stateless PostgreSQL primitive that identifies historical changepoint
indexes in a caller-provided, ordered, regularly sampled series.

## Requirements

### Requirement: The capability SHALL expose default changepoint detection as a table-valued function

The capability SHALL expose `augurs_detect_changepoints(values float8[])`
returning `TABLE (index integer)`. Each result row SHALL represent one index
returned by the default Augurs ARGPCP detector. The initial SQL API SHALL NOT
accept algorithm-selection or algorithm-specific option arguments.

#### Scenario: A valid history is detected

- **WHEN** a caller supplies a non-empty finite `float8[]` containing an
  ordered, regularly sampled history
- **THEN** the function returns zero or more rows with an `index` integer column
  using the default ARGPCP detector

#### Scenario: The detector's documented example is exposed directly

- **WHEN** a caller supplies the pinned Augurs example series with a known
  regime shift
- **THEN** the result preserves the native boundary output, including index `0`
  and the index immediately before the detected shift

### Requirement: Result indexes SHALL preserve native ordering and boundary semantics

The function SHALL preserve the order of the indexes returned by Augurs and
SHALL NOT sort, deduplicate, round, or reinterpret them. Index `0` SHALL retain
its native meaning as the beginning of the series. Any other returned index
SHALL identify the sample immediately before the detected regime change.

#### Scenario: A known level shift is located

- **WHEN** a deterministic synthetic series changes level at a known sample
  boundary
- **THEN** the result contains the detector's boundary index at or near that
  known boundary, representing the sample before the change according to native
  Augurs semantics

#### Scenario: Stable input has no fabricated boundary

- **WHEN** a deterministic stable series is supplied
- **THEN** the function returns only the native detector result and does not add
  an extension-generated changepoint or anomaly classification

### Requirement: The caller SHALL provide ordering and time interpretation

The function SHALL consume only the supplied values. It SHALL NOT accept or
inspect timestamps, query PostgreSQL or TimescaleDB relations, infer a sample
interval, resample, interpolate, detrend, deseasonalize, or otherwise modify the
series. Periodicity and chronological ordering SHALL remain caller
responsibilities.

#### Scenario: A query-built regular series is detected

- **WHEN** a caller orders and aggregates a source series in SQL and passes the
  resulting array to the function
- **THEN** detection uses that array without requiring a relation, timestamp
  argument, entity identifier, or sampling interval

#### Scenario: Indexes are mapped back to timestamps by the caller

- **WHEN** a caller joins returned indexes to a zero-based, timestamped source
  projection
- **THEN** each returned index maps to the source sample immediately before the
  detected change, and the extension does not supply or alter the timestamp

### Requirement: Invalid or unsupported histories SHALL fail clearly without partial output

The function SHALL reject an empty array, an array containing NULL, NaN, or
infinite values, and a history shorter than the minimum supported by the default
detector. It SHALL report a clear PostgreSQL input-validation or detector error
and SHALL NOT return partial rows. The function SHALL NOT silently modify
invalid values.

#### Scenario: Empty, NULL, or non-finite input is rejected

- **WHEN** the caller supplies an empty array, a NULL element, NaN, or positive
  or negative infinity
- **THEN** the function raises a clear PostgreSQL error identifying invalid
  `augurs_detect_changepoints` input

#### Scenario: A too-short history is rejected

- **WHEN** the caller supplies fewer observations than the default detector can
  process safely
- **THEN** the function raises a clear PostgreSQL error instead of invoking the
  detector or returning partial output

### Requirement: Detection SHALL be stateless and domain-neutral

Each invocation SHALL compute its result only from its own input values. The
capability SHALL NOT persist detector state or results, reuse another call's
state, schedule work, create events, invalidate or refit forecast models, or
classify the reason for a change. Online detection SHALL remain outside this
capability.

#### Scenario: Independent calls do not share state

- **WHEN** two calls provide different histories in any order
- **THEN** each result is computed independently and neither call requires a
  prior invocation or stored detector state

#### Scenario: Higher-level lifecycle logic consumes the indexes

- **WHEN** application logic uses a returned index to refit a forecast, split a
  profile window, or create an observation
- **THEN** those actions occur outside the PostgreSQL primitive and the
  primitive only returns detector indexes
