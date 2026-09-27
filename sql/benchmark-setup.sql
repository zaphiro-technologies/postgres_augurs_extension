\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS postgres_augurs_extension;

DROP TABLE IF EXISTS augurs_benchmark_history;

CREATE TABLE augurs_benchmark_history AS
SELECT
    sample,
    60.0
        + 8.0 * sin(2.0 * pi() * sample / 96.0)
        + 3.0 * sin(2.0 * pi() * sample / 672.0)
        + sample / 1000.0 AS value
FROM generate_series(0, 5759) AS samples(sample);
