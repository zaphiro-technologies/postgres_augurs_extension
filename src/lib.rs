use augurs::{
    changepoint::{DefaultArgpcpDetector, Detector as ChangepointDetector},
    ets::AutoETS,
    mstl::MSTLModel,
    prelude::*,
    seasons::{Detector, PeriodogramDetector},
};
use pgrx::prelude::*;
use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex, OnceLock,
    },
    time::Instant,
};

::pgrx::pg_module_magic!();

const MAX_CACHED_FITS: usize = 4;
const MIN_CHANGEPOINT_VALUES: usize = 4;
const MAD_SCALE: f64 = 1.4826;

type FittedMstlModel = augurs::mstl::FittedMSTLModel;

#[derive(Clone, Debug, PartialEq, Eq)]
struct FitKey {
    values: Vec<u64>,
    periods: Vec<usize>,
}

impl FitKey {
    fn new(values: &[f64], periods: &[usize]) -> Self {
        Self {
            values: values.iter().map(|value| value.to_bits()).collect(),
            periods: periods.to_vec(),
        }
    }
}

struct CachedFit {
    series_key: String,
    key: FitKey,
    fitted: Arc<FittedMstlModel>,
    model_version: i64,
}

static FIT_CACHE: OnceLock<Mutex<VecDeque<CachedFit>>> = OnceLock::new();
static NEXT_MODEL_VERSION: AtomicU64 = AtomicU64::new(1);

fn fit_cache() -> &'static Mutex<VecDeque<CachedFit>> {
    FIT_CACHE.get_or_init(|| Mutex::new(VecDeque::with_capacity(MAX_CACHED_FITS)))
}

fn validate_inputs(
    values: &[f64],
    periods: &[i32],
    horizon: i32,
    level: Option<f64>,
) -> Result<Vec<usize>, String> {
    let periods = validate_fit_inputs(values, periods)?;

    if horizon <= 0 {
        return Err("horizon must be positive".to_owned());
    }

    if let Some(level) = level {
        if !(level.is_finite() && 0.0 < level && level < 1.0) {
            return Err("level must be finite and strictly between 0 and 1".to_owned());
        }
    }

    Ok(periods)
}

fn validate_fit_inputs(values: &[f64], periods: &[i32]) -> Result<Vec<usize>, String> {
    if values.is_empty() {
        return Err("values must contain at least one observation".to_owned());
    }

    if values.iter().any(|value| !value.is_finite()) {
        return Err("values must contain only finite numbers".to_owned());
    }

    if periods.is_empty() || periods.iter().any(|period| *period <= 0) {
        return Err("periods must contain at least one positive value".to_owned());
    }

    Ok(periods.iter().map(|period| *period as usize).collect())
}

fn validate_decomposition_inputs(values: &[f64], periods: &[i32]) -> Result<Vec<usize>, String> {
    if values.is_empty() {
        return Err("values must contain at least one observation".to_owned());
    }

    if values.iter().any(|value| !value.is_finite()) {
        return Err("values must contain only finite numbers".to_owned());
    }

    if periods.is_empty() {
        return Err("periods must contain at least one value".to_owned());
    }

    let mut validated_periods = Vec::with_capacity(periods.len());
    for period in periods {
        if *period < 2 {
            return Err("periods must contain only values of at least 2".to_owned());
        }

        let period = *period as usize;
        let required_values = period
            .checked_mul(2)
            .ok_or_else(|| "period is too large".to_owned())?;
        if values.len() < required_values {
            return Err("values must contain at least two cycles for every period".to_owned());
        }
        validated_periods.push(period);
    }

    Ok(validated_periods)
}

fn validate_series_key(series_key: &str) -> Result<(), String> {
    if series_key.trim().is_empty() {
        return Err("series_key must not be empty".to_owned());
    }
    Ok(())
}

fn validate_seasonality_inputs(
    values: &[f64],
    min_period: Option<i32>,
    max_period: Option<i32>,
    threshold: Option<f64>,
) -> Result<(), String> {
    if values.is_empty() {
        return Err("values must contain at least one observation".to_owned());
    }

    if values.iter().any(|value| !value.is_finite()) {
        return Err("values must contain only finite numbers".to_owned());
    }

    if min_period.is_some_and(|period| period <= 0) {
        return Err("min_period must be positive".to_owned());
    }

    if max_period.is_some_and(|period| period <= 0) {
        return Err("max_period must be positive".to_owned());
    }

    if let (Some(min_period), Some(max_period)) = (min_period, max_period) {
        if min_period > max_period {
            return Err("min_period must not be greater than max_period".to_owned());
        }
    }

    if threshold.is_some_and(|value| !value.is_finite()) {
        return Err("threshold must be finite".to_owned());
    }

    Ok(())
}

fn validate_changepoint_inputs(values: &[Option<f64>]) -> Result<Vec<f64>, String> {
    if values.is_empty() {
        return Err("values must contain at least one observation".to_owned());
    }

    if values.len() < MIN_CHANGEPOINT_VALUES {
        return Err(format!(
            "values must contain at least {MIN_CHANGEPOINT_VALUES} observations"
        ));
    }

    values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let value =
                value.ok_or_else(|| format!("values must not contain NULL at index {index}"))?;
            if !value.is_finite() {
                return Err(format!(
                    "values must contain only finite numbers (invalid index {index})"
                ));
            }
            Ok(value)
        })
        .collect()
}

#[derive(Clone, Copy, Debug)]
struct RollingMadConfig {
    window_size: usize,
    threshold: f64,
    min_samples: usize,
}

type RollingMadRow = (
    i32,
    Option<f64>,
    Option<f64>,
    Option<f64>,
    Option<f64>,
    Option<f64>,
    Option<bool>,
    bool,
);

fn validate_rolling_mad_inputs(
    values: &[Option<f64>],
    window_size: i32,
    threshold: f64,
    min_samples: Option<i32>,
) -> Result<(Vec<f64>, RollingMadConfig), String> {
    if values.is_empty() {
        return Err("values must contain at least one observation".to_owned());
    }

    if window_size <= 0 {
        return Err("window_size must be positive".to_owned());
    }

    if !threshold.is_finite() || threshold <= 0.0 {
        return Err("threshold must be finite and positive".to_owned());
    }

    let window_size = window_size as usize;
    let min_samples = min_samples.unwrap_or(window_size as i32);
    if min_samples <= 0 {
        return Err("min_samples must be positive".to_owned());
    }
    if min_samples as usize > window_size {
        return Err("min_samples must not be greater than window_size".to_owned());
    }

    let values = values
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let value =
                value.ok_or_else(|| format!("values must not contain NULL at index {index}"))?;
            if !value.is_finite() {
                return Err(format!(
                    "values must contain only finite numbers (invalid at index {index})"
                ));
            }
            Ok(value)
        })
        .collect::<Result<Vec<_>, _>>()?;

    Ok((
        values,
        RollingMadConfig {
            window_size,
            threshold,
            min_samples: min_samples as usize,
        },
    ))
}

fn conventional_median(sorted_values: &[f64]) -> f64 {
    let middle = sorted_values.len() / 2;
    if sorted_values.len() % 2 == 1 {
        sorted_values[middle]
    } else {
        sorted_values[middle - 1] * 0.5 + sorted_values[middle] * 0.5
    }
}

fn finite_result(value: f64, description: &str) -> Result<f64, String> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(format!("rolling MAD {description} is not finite"))
    }
}

fn rolling_mad_rows(
    values: &[f64],
    config: RollingMadConfig,
) -> Result<Vec<RollingMadRow>, String> {
    let mut rows = Vec::with_capacity(values.len());

    for (index, value) in values.iter().copied().enumerate() {
        let start = index.saturating_sub(config.window_size);
        let baseline = &values[start..index];
        let is_ready = baseline.len() >= config.min_samples;

        if !is_ready {
            rows.push((index as i32, None, None, None, None, None, None, false));
            continue;
        }

        let mut sorted_baseline = baseline.to_vec();
        sorted_baseline.sort_by(f64::total_cmp);
        let median = finite_result(conventional_median(&sorted_baseline), "median")?;

        let mut deviations = sorted_baseline
            .iter()
            .map(|baseline_value| {
                finite_result((*baseline_value - median).abs(), "absolute deviation")
            })
            .collect::<Result<Vec<_>, _>>()?;
        deviations.sort_by(f64::total_cmp);
        let mad = finite_result(conventional_median(&deviations), "MAD")?;

        if mad == 0.0 {
            if value == median {
                rows.push((
                    index as i32,
                    Some(median),
                    Some(0.0),
                    Some(median),
                    Some(median),
                    Some(0.0),
                    Some(false),
                    true,
                ));
            } else {
                rows.push((
                    index as i32,
                    Some(median),
                    Some(0.0),
                    Some(median),
                    Some(median),
                    None,
                    Some(true),
                    true,
                ));
            }
            continue;
        }

        let scaled_mad = finite_result(MAD_SCALE * mad, "scaled MAD")?;
        let margin = finite_result(config.threshold * scaled_mad, "threshold margin")?;
        let lower_bound = finite_result(median - margin, "lower bound")?;
        let upper_bound = finite_result(median + margin, "upper bound")?;
        let score = finite_result((value - median).abs() / scaled_mad, "score")?;
        let is_outlier = score > config.threshold;

        rows.push((
            index as i32,
            Some(median),
            Some(mad),
            Some(lower_bound),
            Some(upper_bound),
            Some(score),
            Some(is_outlier),
            true,
        ));
    }

    Ok(rows)
}

fn detect_changepoints(values: &[f64]) -> Result<Vec<i32>, String> {
    let mut detector = DefaultArgpcpDetector::default();
    detector
        .detect_changepoints(values)
        .into_iter()
        .map(|index| {
            i32::try_from(index).map_err(|_| {
                "detected changepoint index cannot be represented as integer".to_owned()
            })
        })
        .collect()
}

fn detect_periods(
    values: &[f64],
    min_period: Option<i32>,
    max_period: Option<i32>,
    threshold: Option<f64>,
) -> Result<Vec<i32>, String> {
    validate_seasonality_inputs(values, min_period, max_period, threshold)?;

    let mut builder = PeriodogramDetector::builder();
    if let Some(min_period) = min_period {
        builder = builder.min_period(min_period as u32);
    }
    if let Some(max_period) = max_period {
        builder = builder.max_period(max_period as u32);
    }
    if let Some(threshold) = threshold {
        builder = builder.threshold(threshold);
    }

    builder
        .build()
        .detect(values)
        .into_iter()
        .map(|period| {
            i32::try_from(period)
                .map_err(|_| "detected period cannot be represented as integer".to_owned())
        })
        .collect()
}

type DecompositionRow = (i32, f64, Vec<f64>, f64);

fn decompose_rows(values: &[f64], periods: &[i32]) -> Result<Vec<DecompositionRow>, String> {
    let periods = validate_decomposition_inputs(values, periods)?;
    let fitted = MSTLModel::naive(periods)
        .fit(values)
        .map_err(|error| error.to_string())?;
    let decomposition = fitted.fit();
    let trend = decomposition.trend();
    let seasonal = decomposition.seasonal();
    let remainder = decomposition.remainder();

    if trend.len() != values.len() || remainder.len() != values.len() {
        return Err("native decomposition returned an unexpected component length".to_owned());
    }

    let mut rows = Vec::with_capacity(values.len());
    for index in 0..values.len() {
        let seasonal_values = seasonal
            .iter()
            .map(|component| {
                component.get(index).copied().map(f64::from).ok_or_else(|| {
                    "native decomposition returned an incomplete seasonal component".to_owned()
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        rows.push((
            index as i32,
            f64::from(trend[index]),
            seasonal_values,
            f64::from(remainder[index]),
        ));
    }

    Ok(rows)
}

fn fit_model(values: &[f64], periods: &[usize]) -> Result<(Arc<FittedMstlModel>, f64), String> {
    let fit_started = Instant::now();
    let trend_model = AutoETS::non_seasonal().into_trend_model();
    let model = MSTLModel::new(periods.to_vec(), trend_model);
    let fitted = Arc::new(model.fit(values).map_err(|error| error.to_string())?);
    let fit_ms = fit_started.elapsed().as_secs_f64() * 1000.0;
    Ok((fitted, fit_ms))
}

struct FitOutcome {
    model_version: i64,
    reused: bool,
    fit_ms: f64,
}

fn fit_or_reuse(series_key: &str, values: &[f64], periods: &[usize]) -> Result<FitOutcome, String> {
    let key = FitKey::new(values, periods);

    {
        let mut cache = fit_cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(index) = cache
            .iter()
            .position(|entry| entry.series_key == series_key && entry.key == key)
        {
            let entry = cache
                .remove(index)
                .expect("cache entry should exist at its position");
            let model_version = entry.model_version;
            cache.push_back(entry);
            return Ok(FitOutcome {
                model_version,
                reused: true,
                fit_ms: 0.0,
            });
        }
    }

    let (fitted, fit_ms) = fit_model(values, periods)?;

    let mut cache = fit_cache()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    // A concurrent caller may have completed the same fit while this caller
    // was fitting. Prefer the existing entry in that case.
    if let Some(index) = cache
        .iter()
        .position(|entry| entry.series_key == series_key && entry.key == key)
    {
        let entry = cache
            .remove(index)
            .expect("cache entry should exist at its position");
        let model_version = entry.model_version;
        cache.push_back(entry);
        return Ok(FitOutcome {
            model_version,
            reused: true,
            fit_ms: 0.0,
        });
    }

    // Replace an older version for this series only after the new fit has
    // completed successfully. Existing readers retain their Arc reference.
    if let Some(index) = cache
        .iter()
        .position(|entry| entry.series_key == series_key)
    {
        cache.remove(index);
    }

    if cache.len() == MAX_CACHED_FITS {
        cache.pop_front();
    }
    let model_version = NEXT_MODEL_VERSION.fetch_add(1, Ordering::Relaxed) as i64;
    cache.push_back(CachedFit {
        series_key: series_key.to_owned(),
        key,
        fitted: Arc::clone(&fitted),
        model_version,
    });
    Ok(FitOutcome {
        model_version,
        reused: false,
        fit_ms,
    })
}

fn cached_fit(series_key: &str) -> Option<Arc<FittedMstlModel>> {
    let mut cache = fit_cache()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let index = cache
        .iter()
        .position(|entry| entry.series_key == series_key)?;
    let entry = cache
        .remove(index)
        .expect("cache entry should exist at its position");
    let fitted = Arc::clone(&entry.fitted);
    cache.push_back(entry);
    Some(fitted)
}

type ForecastRow = (i32, f64, Option<f64>, Option<f64>);

fn predict_rows(
    fitted: &FittedMstlModel,
    horizon: i32,
    level: Option<f64>,
) -> Result<Vec<ForecastRow>, String> {
    let forecast = fitted
        .predict(horizon as usize, level)
        .map_err(|error| error.to_string())?;
    let intervals = forecast.intervals;
    Ok(forecast
        .point
        .into_iter()
        .enumerate()
        .map(|(index, point)| {
            let lower = intervals.as_ref().map(|intervals| intervals.lower[index]);
            let upper = intervals.as_ref().map(|intervals| intervals.upper[index]);
            ((index + 1) as i32, point, lower, upper)
        })
        .collect())
}

#[pg_extern]
fn augurs_mstl_forecast(
    values: Vec<f64>,
    periods: Vec<i32>,
    horizon: i32,
    level: Option<f64>,
) -> TableIterator<
    'static,
    (
        name!(step, i32),
        name!(point, f64),
        name!(lower, Option<f64>),
        name!(upper, Option<f64>),
    ),
> {
    let periods = validate_inputs(&values, &periods, horizon, level)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_forecast input: {error}"));

    let (fitted, _) = fit_model(&values, &periods)
        .unwrap_or_else(|error| pgrx::error!("Augurs MSTL fit failed: {error}"));
    let rows = predict_rows(&fitted, horizon, level)
        .unwrap_or_else(|error| pgrx::error!("Augurs forecast failed: {error}"));

    TableIterator::new(rows)
}

#[pg_extern]
fn augurs_detect_periods(
    values: Vec<f64>,
    min_period: default!(Option<i32>, "NULL"),
    max_period: default!(Option<i32>, "NULL"),
    threshold: default!(Option<f64>, "NULL"),
) -> Vec<i32> {
    detect_periods(&values, min_period, max_period, threshold)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_detect_periods input: {error}"))
}

#[pg_extern]
fn augurs_detect_changepoints(
    values: Vec<Option<f64>>,
) -> TableIterator<'static, (name!(index, i32),)> {
    let values = validate_changepoint_inputs(&values)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_detect_changepoints input: {error}"));
    let rows = detect_changepoints(&values)
        .unwrap_or_else(|error| pgrx::error!("Augurs changepoint detection failed: {error}"));

    TableIterator::new(rows.into_iter().map(|index| (index,)).collect::<Vec<_>>())
}

#[pg_extern]
#[allow(clippy::type_complexity)]
fn ts_mad_detect(
    values: Vec<Option<f64>>,
    window_size: i32,
    threshold: default!(f64, "3.5"),
    min_samples: default!(Option<i32>, "NULL"),
) -> TableIterator<
    'static,
    (
        name!(index, i32),
        name!(median, Option<f64>),
        name!(mad, Option<f64>),
        name!(lower_bound, Option<f64>),
        name!(upper_bound, Option<f64>),
        name!(score, Option<f64>),
        name!(is_outlier, Option<bool>),
        name!(is_ready, bool),
    ),
> {
    let (values, config) =
        validate_rolling_mad_inputs(&values, window_size, threshold, min_samples)
            .unwrap_or_else(|error| pgrx::error!("invalid ts_mad_detect input: {error}"));
    let rows = rolling_mad_rows(&values, config)
        .unwrap_or_else(|error| pgrx::error!("ts_mad_detect calculation failed: {error}"));

    TableIterator::new(rows)
}

#[pg_extern]
fn augurs_mstl_decompose(
    values: Vec<Option<f64>>,
    periods: Vec<Option<i32>>,
) -> TableIterator<
    'static,
    (
        name!(index, i32),
        name!(trend, f64),
        name!(seasonal, Vec<f64>),
        name!(remainder, f64),
    ),
> {
    let values = values
        .into_iter()
        .enumerate()
        .map(|(index, value)| {
            value.ok_or_else(|| format!("values must not contain NULL at index {index}"))
        })
        .collect::<Result<Vec<_>, _>>()
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_decompose input: {error}"));
    let periods = periods
        .into_iter()
        .enumerate()
        .map(|(index, period)| {
            period.ok_or_else(|| format!("periods must not contain NULL at index {index}"))
        })
        .collect::<Result<Vec<_>, _>>()
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_decompose input: {error}"));

    let rows = decompose_rows(&values, &periods)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_decompose input: {error}"));
    TableIterator::new(rows)
}

#[pg_extern]
fn augurs_mstl_fit(
    series_key: String,
    values: Vec<f64>,
    periods: Vec<i32>,
) -> TableIterator<
    'static,
    (
        name!(series_key, String),
        name!(model_version, i64),
        name!(reused, bool),
        name!(training_points, i32),
        name!(fit_ms, f64),
    ),
> {
    validate_series_key(&series_key)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_fit input: {error}"));
    let periods = validate_fit_inputs(&values, &periods)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_fit input: {error}"));
    let outcome = fit_or_reuse(&series_key, &values, &periods)
        .unwrap_or_else(|error| pgrx::error!("Augurs MSTL fit failed: {error}"));

    TableIterator::new(vec![(
        series_key,
        outcome.model_version,
        outcome.reused,
        values.len() as i32,
        outcome.fit_ms,
    )])
}

#[pg_extern]
fn augurs_mstl_predict(
    series_key: String,
    horizon: i32,
    level: Option<f64>,
) -> TableIterator<
    'static,
    (
        name!(step, i32),
        name!(point, f64),
        name!(lower, Option<f64>),
        name!(upper, Option<f64>),
    ),
> {
    validate_series_key(&series_key)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_predict input: {error}"));
    validate_inputs(&[0.0], &[1], horizon, level)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_predict input: {error}"));

    let fitted = cached_fit(&series_key).unwrap_or_else(|| {
        pgrx::error!(
            "Augurs MSTL model not found for series_key '{series_key}'; call augurs_mstl_fit first"
        )
    });
    let rows = predict_rows(&fitted, horizon, level)
        .unwrap_or_else(|error| pgrx::error!("Augurs forecast failed: {error}"));

    TableIterator::new(rows)
}

#[pg_extern]
fn augurs_mstl_benchmark(
    values: Vec<f64>,
    periods: Vec<i32>,
    horizon: i32,
    level: Option<f64>,
) -> TableIterator<
    'static,
    (
        name!(fit_ms, f64),
        name!(predict_ms, f64),
        name!(model_ms, f64),
        name!(forecast_rows, i32),
    ),
> {
    let periods = validate_inputs(&values, &periods, horizon, level)
        .unwrap_or_else(|error| pgrx::error!("invalid augurs_mstl_benchmark input: {error}"));

    let model_started = Instant::now();
    let (fitted, fit_ms) = fit_model(&values, &periods)
        .unwrap_or_else(|error| pgrx::error!("Augurs MSTL fit failed: {error}"));

    let predict_started = Instant::now();
    let forecast = fitted
        .predict(horizon as usize, level)
        .unwrap_or_else(|error| pgrx::error!("Augurs forecast failed: {error}"));
    let predict_ms = predict_started.elapsed().as_secs_f64() * 1000.0;
    let model_ms = model_started.elapsed().as_secs_f64() * 1000.0;
    let forecast_rows = forecast.point.len() as i32;

    TableIterator::new(vec![(fit_ms, predict_ms, model_ms, forecast_rows)])
}

#[cfg(test)]
mod tests {
    use super::{
        conventional_median, decompose_rows, detect_changepoints, rolling_mad_rows,
        validate_changepoint_inputs, validate_decomposition_inputs, validate_inputs,
        validate_rolling_mad_inputs, validate_seasonality_inputs, FitKey,
    };

    #[test]
    fn accepts_representative_inputs() {
        let periods = validate_inputs(&[1.0; 2_880], &[96, 672], 96, Some(0.95))
            .expect("representative input should be valid");
        assert_eq!(periods, vec![96, 672]);
    }

    #[test]
    fn rejects_invalid_inputs() {
        assert!(validate_inputs(&[], &[96], 96, Some(0.95)).is_err());
        assert!(validate_inputs(&[1.0], &[0], 96, Some(0.95)).is_err());
        assert!(validate_inputs(&[1.0], &[96], 0, Some(0.95)).is_err());
        assert!(validate_inputs(&[1.0], &[96], 96, Some(1.0)).is_err());
        assert!(validate_inputs(&[f64::NAN], &[96], 96, Some(0.95)).is_err());
    }

    #[test]
    fn accepts_decomposition_inputs() {
        let periods = validate_decomposition_inputs(&[1.0; 2_880], &[96, 672])
            .expect("representative decomposition input should be valid");
        assert_eq!(periods, vec![96, 672]);
    }

    #[test]
    fn rejects_invalid_decomposition_inputs() {
        assert!(validate_decomposition_inputs(&[], &[2]).is_err());
        assert!(validate_decomposition_inputs(&[f64::NAN], &[2]).is_err());
        assert!(validate_decomposition_inputs(&[1.0; 8], &[]).is_err());
        assert!(validate_decomposition_inputs(&[1.0; 8], &[1]).is_err());
        assert!(validate_decomposition_inputs(&[1.0; 3], &[2]).is_err());
    }

    #[test]
    fn decomposition_rows_preserve_shape_and_period_order() {
        let values: Vec<f64> = (0..16).map(f64::from).collect();
        let rows = decompose_rows(&values, &[2, 4]).expect("decomposition should succeed");
        let reversed_rows =
            decompose_rows(&values, &[4, 2]).expect("reversed decomposition should succeed");

        assert_eq!(rows.len(), values.len());
        assert_eq!(rows.first().map(|row| row.0), Some(0));
        assert_eq!(rows.last().map(|row| row.0), Some(15));
        assert!(rows.iter().all(|row| row.2.len() == 2));
        for (row, reversed_row) in rows.iter().zip(reversed_rows.iter()) {
            assert_eq!(row.2[0], reversed_row.2[1]);
            assert_eq!(row.2[1], reversed_row.2[0]);
        }
    }

    #[test]
    fn accepts_seasonality_configuration() {
        validate_seasonality_inputs(&[1.0; 2_880], Some(4), Some(1_000), Some(0.8))
            .expect("seasonality configuration should be valid");
    }

    #[test]
    fn rejects_invalid_seasonality_configuration() {
        assert!(validate_seasonality_inputs(&[], None, None, None).is_err());
        assert!(validate_seasonality_inputs(&[f64::NAN], None, None, None).is_err());
        assert!(validate_seasonality_inputs(&[1.0], Some(0), None, None).is_err());
        assert!(validate_seasonality_inputs(&[1.0], None, Some(0), None).is_err());
        assert!(validate_seasonality_inputs(&[1.0], Some(8), Some(4), None).is_err());
        assert!(validate_seasonality_inputs(&[1.0], None, None, Some(f64::INFINITY)).is_err());
    }

    #[test]
    fn accepts_changepoint_inputs() {
        let values = validate_changepoint_inputs(&[Some(1.0); 4])
            .expect("representative changepoint input should be valid");
        assert_eq!(values, vec![1.0; 4]);
    }

    #[test]
    fn rejects_invalid_changepoint_inputs() {
        assert!(validate_changepoint_inputs(&[]).is_err());
        assert!(validate_changepoint_inputs(&[Some(1.0); 3]).is_err());
        assert!(validate_changepoint_inputs(&[Some(1.0), None, Some(1.0), Some(1.0)]).is_err());
        assert!(validate_changepoint_inputs(&[Some(f64::NAN); 4]).is_err());
        assert!(validate_changepoint_inputs(&[Some(f64::INFINITY); 4]).is_err());
    }

    #[test]
    fn detects_native_changepoint_indexes() {
        let values = [0.5, 1.0, 0.4, 0.8, 1.5, 0.9, 0.6, 25.3, 20.4, 27.3, 30.0];
        assert_eq!(detect_changepoints(&values).unwrap(), vec![0, 6]);
    }

    #[test]
    fn changepoint_detection_is_independent_and_preserves_native_order() {
        let shifted = [0.5, 1.0, 0.4, 0.8, 1.5, 0.9, 0.6, 25.3, 20.4, 27.3, 30.0];
        let stable = [1.0, 1.0, 1.0, 1.0];

        assert_eq!(detect_changepoints(&shifted).unwrap(), vec![0, 6]);
        assert_eq!(detect_changepoints(&stable).unwrap(), vec![0]);
        assert_eq!(detect_changepoints(&shifted).unwrap(), vec![0, 6]);
    }

    #[test]
    fn fit_keys_distinguish_series_inputs() {
        let first = FitKey::new(&[1.0, 2.0], &[2]);
        let same = FitKey::new(&[1.0, 2.0], &[2]);
        let changed_value = FitKey::new(&[1.0, 3.0], &[2]);
        let changed_period = FitKey::new(&[1.0, 2.0], &[3]);

        assert_eq!(first, same);
        assert_ne!(first, changed_value);
        assert_ne!(first, changed_period);
    }

    #[test]
    fn rolling_mad_validation_applies_defaults_and_rejects_invalid_inputs() {
        let (values, config) = validate_rolling_mad_inputs(&[Some(1.0), Some(2.0)], 2, 3.5, None)
            .expect("representative rolling MAD input should be valid");
        assert_eq!(values, vec![1.0, 2.0]);
        assert_eq!(config.window_size, 2);
        assert_eq!(config.threshold, 3.5);
        assert_eq!(config.min_samples, 2);

        assert!(validate_rolling_mad_inputs(&[], 2, 3.5, None).is_err());
        assert!(validate_rolling_mad_inputs(&[Some(1.0)], 0, 3.5, None).is_err());
        assert!(validate_rolling_mad_inputs(&[Some(1.0)], 2, 0.0, None).is_err());
        assert!(validate_rolling_mad_inputs(&[Some(1.0)], 2, f64::NAN, None).is_err());
        assert!(validate_rolling_mad_inputs(&[None], 2, 3.5, None).is_err());
        assert!(validate_rolling_mad_inputs(&[Some(f64::INFINITY)], 2, 3.5, None).is_err());
        assert!(validate_rolling_mad_inputs(&[Some(1.0)], 2, 3.5, Some(0)).is_err());
        assert!(validate_rolling_mad_inputs(&[Some(1.0)], 2, 3.5, Some(3)).is_err());
    }

    #[test]
    fn rolling_mad_uses_conventional_even_median() {
        assert_eq!(conventional_median(&[1.0, 2.0, 3.0, 4.0]), 2.5);
        assert_eq!(conventional_median(&[1.0, 2.0, 3.0]), 2.0);
    }

    #[test]
    fn rolling_mad_excludes_current_value_and_detects_spikes() {
        let (_, config) = validate_rolling_mad_inputs(&[Some(1.0); 5], 4, 3.5, None)
            .expect("configuration should be valid");
        let values = [1.0, 2.0, 3.0, 4.0, 100.0];
        let rows = rolling_mad_rows(&values, config).expect("calculation should succeed");

        assert!(rows[..4].iter().all(|row| !row.7));
        let row = rows[4];
        assert_eq!(row.0, 4);
        assert_eq!(row.1, Some(2.5));
        assert_eq!(row.2, Some(1.0));
        assert_eq!(row.6, Some(true));
        assert!(row.5.expect("spike should have a score") > 3.5);
    }

    #[test]
    fn rolling_mad_warmup_and_level_shift_are_trailing() {
        let (_, config) = validate_rolling_mad_inputs(&[Some(1.0); 4], 4, 3.5, Some(2))
            .expect("configuration should be valid");
        let rows = rolling_mad_rows(&[1.0, 2.0, 3.0, 4.0, 10.0, 10.0], config)
            .expect("calculation should succeed");

        assert!(!rows[0].7);
        assert_eq!(rows[0].6, None);
        assert!(!rows[1].7);
        assert!(rows[2].7);
        assert_eq!(rows[2].1, Some(1.5));
        assert_eq!(rows[4].1, Some(2.5));
        assert_eq!(rows[5].1, Some(3.5));
    }

    #[test]
    fn rolling_mad_zero_mad_handles_matching_and_different_values() {
        let (_, config) = validate_rolling_mad_inputs(&[Some(1.0); 3], 3, 3.5, None)
            .expect("configuration should be valid");
        let matching = rolling_mad_rows(&[1.0, 1.0, 1.0, 1.0], config)
            .expect("matching zero-MAD input should succeed");
        assert_eq!(matching[3].1, Some(1.0));
        assert_eq!(matching[3].2, Some(0.0));
        assert_eq!(matching[3].5, Some(0.0));
        assert_eq!(matching[3].6, Some(false));

        let different = rolling_mad_rows(&[1.0, 1.0, 1.0, 2.0], config)
            .expect("different zero-MAD input should succeed");
        assert_eq!(different[3].1, Some(1.0));
        assert_eq!(different[3].2, Some(0.0));
        assert_eq!(different[3].5, None);
        assert_eq!(different[3].6, Some(true));
    }

    #[test]
    fn rolling_mad_outputs_are_finite_or_null() {
        let (_, config) = validate_rolling_mad_inputs(
            &[Some(-2.0), Some(0.0), Some(3.0), Some(8.0)],
            3,
            3.5,
            Some(1),
        )
        .expect("configuration should be valid");
        let rows =
            rolling_mad_rows(&[-2.0, 0.0, 3.0, 8.0], config).expect("calculation should succeed");
        for row in rows {
            for value in [row.1, row.2, row.3, row.4, row.5].into_iter().flatten() {
                assert!(value.is_finite());
            }
        }
    }
}
