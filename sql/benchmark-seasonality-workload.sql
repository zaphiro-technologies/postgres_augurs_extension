\set ON_ERROR_STOP on

SELECT
    avg(extract(epoch FROM timings.finished - timings.started) * 1000.0) AS detection_ms,
    count(*) FILTER (WHERE timings.periods IS NOT NULL) AS detected_runs,
    count(*) AS iterations
FROM generate_series(1, :iterations) AS runs(run_id)
CROSS JOIN LATERAL (
    SELECT clock_timestamp() AS started
) AS timings_start
CROSS JOIN LATERAL (
    SELECT augurs_detect_periods(
        ARRAY(
            SELECT value + (runs.run_id::double precision * 0.0)
                + (extract(epoch FROM timings_start.started)::double precision * 0.0)
            FROM augurs_benchmark_history
            ORDER BY sample
            LIMIT :batch_size
        ),
        4,
        2000,
        0.8
    ) AS periods
) AS detection
CROSS JOIN LATERAL (
    SELECT timings_start.started, detection.periods, clock_timestamp() AS finished
) AS timings;
