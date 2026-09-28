\set ON_ERROR_STOP on

SELECT
    avg(extract(epoch FROM timings.finished - timings.started) * 1000.0) AS decomposition_ms,
    count(*) FILTER (WHERE timings.decomposition_rows = :batch_size) AS complete_runs,
    count(*) AS iterations
FROM generate_series(1, :iterations) AS runs(run_id)
CROSS JOIN LATERAL (
    SELECT clock_timestamp() AS started
) AS timings_start
CROSS JOIN LATERAL (
    SELECT count(*) AS decomposition_rows
    FROM augurs_mstl_decompose(
        ARRAY(
            SELECT value + (runs.run_id::double precision * 0.0)
                + (extract(epoch FROM timings_start.started)::double precision * 0.0)
            FROM augurs_benchmark_history
            ORDER BY sample
            LIMIT :batch_size
        ),
        ARRAY[96, 672]
    )
) AS decomposition
CROSS JOIN LATERAL (
    SELECT
        timings_start.started,
        decomposition.decomposition_rows,
        clock_timestamp() AS finished
) AS timings;
