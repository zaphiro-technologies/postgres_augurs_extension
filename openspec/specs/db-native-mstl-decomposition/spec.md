# db-native-mstl-decomposition Specification

## Purpose

Provide a stateless SQL boundary for decomposing an ordered, regularly sampled
series into its trend, requested seasonal components, and unexplained remainder.

## Requirements

### Requirement: The capability SHALL expose table-valued MSTL decomposition

The capability SHALL expose
`augurs_mstl_decompose(values float8[], periods integer[])` and return one row
for every input value. Each row SHALL contain a zero-based `index` integer, a
`trend` float8, a `seasonal` float8 array, and a `remainder` float8.

#### Scenario: A single seasonal period is decomposed

- **WHEN** a caller supplies an ordered regular `float8[]` and one valid period
- **THEN** the function returns one row per input value with one seasonal
  component in each row

#### Scenario: Multiple seasonal periods are decomposed

- **WHEN** a caller supplies an ordered regular `float8[]` and multiple valid
  periods
- **THEN** the function returns one row per input value and the seasonal array
  contains one component for each supplied period

### Requirement: Decomposition output SHALL preserve sample ordering and period ordering

The function SHALL assign `index = 0` to the first input value and increase the
index by one for each subsequent input value. The returned rows SHALL be in
input order. For every row, `seasonal[n]` SHALL correspond to the period at
position `n` in the supplied `periods` array, using PostgreSQL's one-based array
indexing for the returned seasonal array.

#### Scenario: Output can be joined back to timestamps

- **WHEN** a caller builds an ordered values array from a timestamped query and
  joins the result on the zero-based sample index
- **THEN** each decomposition row corresponds to the original timestamp and
  value at that position

#### Scenario: Native seasonal order is retained

- **WHEN** the caller supplies periods `[96, 672]`
- **THEN** `seasonal[1]` is the period-96 component and `seasonal[2]` is the
  period-672 component for every row

### Requirement: Decomposition SHALL expose native MSTL components without reinterpretation

The function SHALL delegate decomposition to the native Augurs MSTL algorithm
and SHALL expose its trend, seasonal components, and remainder as float8 values.
It SHALL not add timestamps, confidence scores, anomaly scores, or an `expected`
column. The input SHALL be reconstructable from the returned trend, all seasonal
components, and remainder within the normal floating-point precision of the
native decomposition.

#### Scenario: Components reconstruct the input

- **WHEN** a valid series is decomposed
- **THEN** each input value is approximately equal to its returned trend plus
  the sum of its returned seasonal components plus its returned remainder

#### Scenario: No derived forecast field is returned

- **WHEN** a caller requests a decomposition
- **THEN** the result contains only index, trend, seasonal, and remainder
  columns

### Requirement: The caller SHALL provide regularization and time interpretation

The function SHALL interpret `values` as already ordered and regularly sampled.
It SHALL not accept or inspect timestamps, query relations, infer a sampling
interval, resample, interpolate, remove samples, or modify supplied periods.
Periods SHALL be expressed as numbers of samples.

#### Scenario: Query-built values are decomposed

- **WHEN** a caller aggregates and orders a TimescaleDB series in SQL and passes
  the resulting array to the function
- **THEN** decomposition uses only the supplied values and periods

#### Scenario: Fifteen-minute periods remain sample counts

- **WHEN** the caller supplies a 15-minute series with periods `[96, 672]`
- **THEN** the function treats them as one-day and one-week sample periods
  without receiving or inferring a time interval

### Requirement: Invalid input SHALL fail with a clear PostgreSQL error

The function SHALL reject empty values, empty periods, periods less than two,
periods for which the history contains fewer than two complete cycles, NULL or
non-finite values, NULL periods, and any decomposition failure reported by the
native algorithm. It SHALL not return a partial decomposition for invalid input.

#### Scenario: Invalid values or periods are rejected

- **WHEN** the caller supplies an empty array, a NULL or non-finite value, an
  empty periods array, a NULL period, or a period less than two
- **THEN** the function fails with an input-validation error

#### Scenario: Insufficient history is rejected

- **WHEN** the caller supplies fewer than two cycles for any requested period
- **THEN** the function fails with a clear decomposition error rather than
  returning partial rows

### Requirement: Decomposition SHALL be stateless

Each invocation SHALL compute its result from the supplied values and periods
only. The capability SHALL not persist models or decomposition results, require
a series key, schedule work, or reuse state from another invocation.

#### Scenario: Independent calls do not share decomposition state

- **WHEN** two calls provide different values or periods
- **THEN** each result is computed from its own arguments without requiring a
  prior fit or stored state

#### Scenario: Detected periods are directly usable

- **WHEN** a caller passes the `integer[]` result of `augurs_detect_periods` as
  the `periods` argument
- **THEN** the decomposition function accepts that array directly, subject only
  to its normal input and history validation
