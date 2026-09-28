\set ON_ERROR_STOP on

SELECT
    avg(extract(epoch FROM timings.finished - timings.started) * 1000.0) AS rolling_mad_ms,
    count(*) FILTER (WHERE timings.result_rows = :batch_size) AS complete_runs,
    count(*) AS iterations
FROM generate_series(1, :iterations) AS runs(run_id)
CROSS JOIN LATERAL (
    SELECT clock_timestamp() AS started
) AS timings_start
CROSS JOIN LATERAL (
    SELECT count(*) AS result_rows
    FROM ts_mad_detect(
        ARRAY(
            SELECT
                50.0
                    + 2.0 * sin(2.0 * pi() * sample / 96.0)
                    + CASE
                        WHEN sample = (:batch_size / 2)::integer THEN 25.0
                        ELSE 0.0
                      END
                    + (runs.run_id::double precision * 0.0)
                FROM generate_series(0, :batch_size - 1) AS samples(sample)
                ORDER BY sample
        ),
        96,
        3.5,
        24
    )
) AS detector
CROSS JOIN LATERAL (
    SELECT
        timings_start.started,
        detector.result_rows,
        clock_timestamp() AS finished
) AS timings;
