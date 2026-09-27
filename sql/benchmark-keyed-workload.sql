\set ON_ERROR_STOP on

WITH fitted AS MATERIALIZED (
    SELECT *
    FROM augurs_mstl_fit(
        'benchmark:' || :batch_size,
        ARRAY(
            SELECT value
            FROM augurs_benchmark_history
            ORDER BY sample
            LIMIT :batch_size
        ),
        ARRAY[96, 672]
    )
), predictions AS MATERIALIZED (
    SELECT
        started.started_at,
        finished.finished_at,
        forecast.forecast_rows
    FROM fitted
    CROSS JOIN LATERAL generate_series(1, :keyed_iterations) AS runs(run_id)
    CROSS JOIN LATERAL (
        SELECT clock_timestamp() AS started_at
    ) AS started
    CROSS JOIN LATERAL (
        SELECT count(*)::integer AS forecast_rows
        FROM augurs_mstl_predict('benchmark:' || :batch_size, 96, 0.95)
    ) AS forecast
    CROSS JOIN LATERAL (
        SELECT clock_timestamp() AS finished_at
    ) AS finished
)
SELECT
    fitted.fit_ms,
    fitted.reused,
    avg(EXTRACT(EPOCH FROM (predictions.finished_at - predictions.started_at)) * 1000.0) AS predict_avg_ms,
    CASE WHEN bool_and(predictions.forecast_rows = 96) THEN 96 ELSE -1 END AS forecast_rows,
    count(*) AS iterations
FROM fitted
CROSS JOIN predictions
GROUP BY fitted.fit_ms, fitted.reused;
