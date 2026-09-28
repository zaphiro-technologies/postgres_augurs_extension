\set ON_ERROR_STOP on

SELECT
    avg(timings.fit_ms) AS fit_ms,
    avg(timings.predict_ms) AS predict_ms,
    avg(timings.model_ms) AS model_ms,
    CASE WHEN bool_and(timings.forecast_rows = 96) THEN 96 ELSE -1 END AS forecast_rows,
    count(*) AS iterations
FROM generate_series(1, :iterations) AS runs(run_id)
CROSS JOIN LATERAL augurs_mstl_benchmark(
            ARRAY(
                SELECT value + (runs.run_id::double precision * 0.0)
                FROM augurs_benchmark_history
                ORDER BY sample
                LIMIT :batch_size
            ),
            ARRAY[96, 672],
            96,
            0.95
) AS timings;
