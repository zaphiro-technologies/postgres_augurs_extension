# db-native-time-series-analytics Specification

## Purpose

Provide a thin SQL adapter over Augurs MSTL with its native ETS trend model so a caller can turn an ordered query result into a future forecast with optional prediction intervals.

## Requirements

### Requirement: The capability SHALL expose a native-shaped MSTL forecast function

The capability SHALL expose `augurs_mstl_forecast` with SQL inputs corresponding to the native Augurs operation: an ordered `float8[]` value array, integer seasonal periods, a positive forecast horizon, and an optional prediction-interval level. The function SHALL use the caller-provided values as the model input and SHALL not query application tables internally.

#### Scenario: Query-built history is forecast
- **WHEN** a caller builds an ordered array from a time-series query and invokes `augurs_mstl_forecast(values, periods, horizon, level)`
- **THEN** the function fits and forecasts that supplied series without requiring a domain-specific entity or metric argument

#### Scenario: Caller owns selection and ordering
- **WHEN** a caller selects and orders aggregate values in a CTE before constructing the array
- **THEN** the function receives only the resulting array and does not select, aggregate, regularize, or reorder rows itself

#### Scenario: Invalid SQL input
- **WHEN** the values array is empty, a seasonal period or horizon is non-positive, the input contains unsupported non-finite values, or a non-null level is outside the native supported range
- **THEN** the function fails with a clear error and does not return a partial forecast

### Requirement: The adapter SHALL preserve the native MSTL/ETS model mapping

The implementation SHALL construct the native MSTL model from the supplied seasonal periods and a non-seasonal automatic ETS trend model, fit it to the supplied values, and pass the requested horizon and optional level directly to the native prediction operation. The adapter SHALL not introduce custom transformations, anomaly rules, or domain-specific model selection in this PoC.

#### Scenario: Native model construction
- **WHEN** a caller supplies periods `[96, 672]`, horizon `96`, and level `0.95`
- **THEN** the adapter maps the periods to the native MSTL model, uses the native non-seasonal automatic ETS trend model, fits the supplied values, and requests a 96-step forecast at level 0.95

#### Scenario: Prediction intervals are omitted
- **WHEN** the caller supplies a null level
- **THEN** the adapter requests a point forecast without intervals and represents the interval columns as null rather than inventing interval values

### Requirement: The capability SHALL return the native forecast values in SQL form

For a successful request, the function SHALL return exactly one row for each future step. Each row SHALL contain a one-based `step`, the native point forecast as `point`, and nullable `lower` and `upper` values. When intervals are present, both bounds SHALL be aligned with the point forecast and lower SHALL be less than or equal to upper.

#### Scenario: Forecast result shape
- **WHEN** the requested horizon is 96 and level is 0.95
- **THEN** the function returns exactly 96 rows with non-null point values and aligned lower/upper interval values when Augurs provides them

#### Scenario: Forecast output can be consumed by SQL
- **WHEN** the caller selects the function result in a normal SQL query
- **THEN** it can address `step`, `point`, `lower`, and `upper` as ordinary result columns without accessing Rust-specific data structures

### Requirement: The PoC SHALL prove the direct query-to-forecast path

The PoC SHALL exercise the extension with a representative regular series of 30 days at 15-minute resolution, using daily and weekly periods `[96, 672]`, horizon `96`, and level `0.95`. The acceptance evidence SHALL show the extension can be installed and invoked by a query whose history is supplied through an ordered aggregate result.

#### Scenario: Representative SQL invocation
- **WHEN** a query constructs `ARRAY(SELECT value FROM history ORDER BY bucket)` from a 30-day, 15-minute aggregate and passes it to `augurs_mstl_forecast`
- **THEN** the query completes and returns a 96-step forecast with point values and prediction bounds

#### Scenario: Extension-only smoke test
- **WHEN** the function is invoked in an isolated PostgreSQL database with only the extension and test input data available
- **THEN** it succeeds without requiring persistence tables, scheduled jobs, or application-domain schemas
