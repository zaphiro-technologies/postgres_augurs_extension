\set ON_ERROR_STOP on

CREATE EXTENSION postgres_augurs_extension;

CREATE TEMP TABLE transformer_loading_15m AS
SELECT
    timestamp '2026-01-01 00:00:00 UTC' + (sample * interval '15 minutes') AS bucket,
    60.0
        + 8.0 * sin(2.0 * pi() * sample / 96.0)
        + 3.0 * sin(2.0 * pi() * sample / 672.0)
        + sample / 1000.0 AS value
FROM generate_series(0, 2879) AS samples(sample);

CREATE TEMP TABLE seasonality_history_15m AS
SELECT
    sample,
    60.0
        + 8.0 * sin(2.0 * pi() * sample / 96.0)
        + 8.0 * sin(2.0 * pi() * sample / 672.0) AS value
FROM generate_series(0, 8639) AS samples(sample);

CREATE TEMP TABLE detected_periods AS
SELECT augurs_detect_periods(
    ARRAY(SELECT value FROM seasonality_history_15m ORDER BY sample),
    4,
    2000,
    0.8
) AS periods;

DO $$
DECLARE
    periods integer[];
BEGIN
    SELECT detected_periods.periods
    INTO periods
    FROM detected_periods;

    IF NOT (ARRAY[97, 682] <@ periods) THEN
        RAISE EXCEPTION 'expected native approximate daily and weekly periods, got %', periods;
    END IF;
END
$$;

CREATE TEMP TABLE default_detected_periods AS
SELECT augurs_detect_periods(
    ARRAY(SELECT value FROM seasonality_history_15m ORDER BY sample)
) AS periods;

DO $$
BEGIN
    IF (SELECT periods IS NULL FROM default_detected_periods) THEN
        RAISE EXCEPTION 'default seasonality detection returned NULL';
    END IF;
END
$$;

CREATE TEMP TABLE no_detected_periods AS
SELECT augurs_detect_periods(
    ARRAY(SELECT 1.0 FROM generate_series(1, 8)),
    4,
    8,
    0.8
) AS periods;

DO $$
BEGIN
    IF (SELECT cardinality(periods) <> 0 FROM no_detected_periods) THEN
        RAISE EXCEPTION 'expected no detected periods, got %',
            (SELECT periods FROM no_detected_periods);
    END IF;
END
$$;

CREATE TEMP TABLE changepoint_source AS
SELECT
    timestamp '2026-01-01 00:00:00 UTC' + (sample * interval '15 minutes') AS bucket,
    value
FROM unnest(ARRAY[
    0.5, 1.0, 0.4, 0.8, 1.5, 0.9, 0.6,
    25.3, 20.4, 27.3, 30.0
]::float8[]) WITH ORDINALITY AS samples(value, ordinal)
CROSS JOIN LATERAL (SELECT (samples.ordinal - 1)::integer AS sample) AS positions;

CREATE TEMP TABLE detected_changepoints AS
SELECT *
FROM augurs_detect_changepoints(
    ARRAY(SELECT value FROM changepoint_source ORDER BY bucket)
);

CREATE TEMP TABLE stable_changepoints AS
SELECT *
FROM augurs_detect_changepoints(ARRAY[1.0, 1.0, 1.0, 1.0]::float8[]);

DO $$
DECLARE
    detected_rows bigint;
    first_index integer;
    last_index integer;
    stable_rows bigint;
BEGIN
    SELECT count(*), min(index), max(index)
    INTO detected_rows, first_index, last_index
    FROM detected_changepoints;

    IF detected_rows <> 2 OR first_index <> 0 OR last_index <> 6 THEN
        RAISE EXCEPTION 'unexpected changepoint result: rows %, indexes %..%',
            detected_rows, first_index, last_index;
    END IF;

    SELECT count(*)
    INTO stable_rows
    FROM stable_changepoints;

    IF stable_rows <> 1 OR (SELECT min(index) FROM stable_changepoints) <> 0 THEN
        RAISE EXCEPTION 'stable input should return only the native initial index';
    END IF;
END
$$;

CREATE TEMP TABLE changepoint_timestamp_mapping AS
WITH series AS (
    SELECT
        row_number() OVER (ORDER BY bucket) - 1 AS index,
        bucket,
        value
    FROM changepoint_source
), changes AS (
    SELECT *
    FROM augurs_detect_changepoints(
        ARRAY(SELECT value FROM series ORDER BY index)
    )
)
SELECT
    changes.index,
    series.bucket AS change_before
FROM changes
JOIN series USING (index);

DO $$
DECLARE
    change_index integer;
    change_before timestamp;
BEGIN
    SELECT mapping.index, mapping.change_before
    INTO change_index, change_before
    FROM changepoint_timestamp_mapping AS mapping
    WHERE mapping.index > 0;

    IF change_index <> 6
        OR change_before <> timestamp '2026-01-01 01:30:00 UTC' THEN
        RAISE EXCEPTION 'unexpected timestamp mapping: index %, bucket %',
            change_index, change_before;
    END IF;
END
$$;

CREATE TEMP TABLE decomposition_single AS
SELECT *
FROM augurs_mstl_decompose(
    ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
    ARRAY[96]
);

DO $$
DECLARE
    decomposition_rows bigint;
    seasonal_width bigint;
    first_index integer;
    last_index integer;
BEGIN
    SELECT count(*), min(index), max(index), min(cardinality(seasonal))
    INTO decomposition_rows, first_index, last_index, seasonal_width
    FROM decomposition_single;

    IF decomposition_rows <> 2880 OR first_index <> 0 OR last_index <> 2879 THEN
        RAISE EXCEPTION 'unexpected single-period decomposition shape: rows %, indexes %..%',
            decomposition_rows, first_index, last_index;
    END IF;

    IF seasonal_width <> 1 OR EXISTS (
        SELECT 1 FROM decomposition_single WHERE cardinality(seasonal) <> 1
    ) THEN
        RAISE EXCEPTION 'single-period decomposition should return one seasonal value per row';
    END IF;
END
$$;

CREATE TEMP TABLE decomposition_multiple AS
SELECT *
FROM augurs_mstl_decompose(
    ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
    ARRAY[96, 672]
);

CREATE TEMP TABLE decomposition_reversed AS
SELECT *
FROM augurs_mstl_decompose(
    ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
    ARRAY[672, 96]
);

DO $$
DECLARE
    decomposition_rows bigint;
    max_reconstruction_error double precision;
    max_period_order_error double precision;
BEGIN
    SELECT count(*)
    INTO decomposition_rows
    FROM decomposition_multiple;

    IF decomposition_rows <> 2880 OR EXISTS (
        SELECT 1 FROM decomposition_multiple WHERE cardinality(seasonal) <> 2
    ) THEN
        RAISE EXCEPTION 'unexpected multiple-period decomposition shape';
    END IF;

    SELECT max(abs(source.value - decomposition.trend - decomposition.remainder
        - (SELECT coalesce(sum(component), 0.0)
           FROM unnest(decomposition.seasonal) AS components(component))))
    INTO max_reconstruction_error
    FROM (
        SELECT
            row_number() OVER (ORDER BY bucket) - 1 AS index,
            value
        FROM transformer_loading_15m
    ) AS source
    JOIN decomposition_multiple AS decomposition USING (index);

    IF max_reconstruction_error >= 0.001 THEN
        RAISE EXCEPTION 'decomposition reconstruction error too large: %',
            max_reconstruction_error;
    END IF;

    SELECT max(abs(forward.seasonal[1] - reverse.seasonal[2]))
    INTO max_period_order_error
    FROM decomposition_multiple AS forward
    JOIN decomposition_reversed AS reverse USING (index);

    IF max_period_order_error >= 0.000001 THEN
        RAISE EXCEPTION 'seasonal component order was not preserved: %',
            max_period_order_error;
    END IF;
END
$$;

CREATE TEMP TABLE detected_decomposition AS
SELECT *
FROM augurs_mstl_decompose(
    ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
    (SELECT periods FROM detected_periods)
);

DO $$
BEGIN
    IF (SELECT count(*) FROM detected_decomposition) <> 2880
        OR EXISTS (
            SELECT 1 FROM detected_decomposition WHERE cardinality(seasonal) <> 2
        ) THEN
        RAISE EXCEPTION 'detected periods could not be passed to MSTL decomposition';
    END IF;
END
$$;

CREATE TEMP TABLE forecast AS
WITH history AS (
    SELECT
        bucket,
        value
    FROM transformer_loading_15m
    WHERE bucket >= timestamp '2026-01-31 00:00:00 UTC' - interval '30 days'
    ORDER BY bucket
)
SELECT *
FROM augurs_mstl_forecast(
    ARRAY(
        SELECT value
        FROM history
        ORDER BY bucket
    ),
    ARRAY[96, 672],
    96,
    0.95
);

DO $$
DECLARE
    forecast_rows bigint;
    bounded_rows bigint;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE lower <= point AND point <= upper)
    INTO forecast_rows, bounded_rows
    FROM forecast;

    IF forecast_rows <> 96 THEN
        RAISE EXCEPTION 'expected 96 forecast rows, got %', forecast_rows;
    END IF;

    IF bounded_rows <> 96 THEN
        RAISE EXCEPTION 'expected 96 bounded forecast rows, got %', bounded_rows;
    END IF;
END
$$;

SELECT * FROM forecast ORDER BY step LIMIT 5;

DO $$
DECLARE
    first_reused boolean;
    second_reused boolean;
    first_version bigint;
    second_version bigint;
BEGIN
    SELECT reused, model_version
    INTO first_reused, first_version
    FROM augurs_mstl_fit(
        'transformer:T1:loading:15m',
        ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
        ARRAY[96, 672]
    );

    IF first_reused THEN
        RAISE EXCEPTION 'first keyed fit should not be reused';
    END IF;

    SELECT reused, model_version
    INTO second_reused, second_version
    FROM augurs_mstl_fit(
        'transformer:T1:loading:15m',
        ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
        ARRAY[96, 672]
    );

    IF NOT second_reused OR second_version <> first_version THEN
        RAISE EXCEPTION 'second keyed fit should reuse the first model';
    END IF;
END
$$;

CREATE TEMP TABLE keyed_forecast AS
SELECT *
FROM augurs_mstl_predict('transformer:T1:loading:15m', 96, 0.95);

DO $$
DECLARE
    forecast_rows bigint;
    bounded_rows bigint;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE lower <= point AND point <= upper)
    INTO forecast_rows, bounded_rows
    FROM keyed_forecast;

    IF forecast_rows <> 96 THEN
        RAISE EXCEPTION 'expected 96 keyed forecast rows, got %', forecast_rows;
    END IF;

    IF bounded_rows <> 96 THEN
        RAISE EXCEPTION 'expected 96 bounded keyed forecast rows, got %', bounded_rows;
    END IF;
END
$$;

CREATE TEMP TABLE point_only_forecast AS
SELECT *
FROM augurs_mstl_forecast(
    ARRAY(SELECT value FROM transformer_loading_15m ORDER BY bucket),
    ARRAY[96, 672],
    96,
    NULL
);

DO $$
DECLARE
    forecast_rows bigint;
    interval_rows bigint;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE lower IS NOT NULL OR upper IS NOT NULL)
    INTO forecast_rows, interval_rows
    FROM point_only_forecast;

    IF forecast_rows <> 96 THEN
        RAISE EXCEPTION 'expected 96 point-only forecast rows, got %', forecast_rows;
    END IF;

    IF interval_rows <> 0 THEN
        RAISE EXCEPTION 'expected no interval rows for NULL level, got %', interval_rows;
    END IF;
END
$$;

DO $$
BEGIN
    BEGIN
        PERFORM augurs_mstl_forecast(ARRAY[]::float8[], ARRAY[96], 96, 0.95);
        RAISE EXCEPTION 'empty values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_forecast input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_forecast(ARRAY[1.0]::float8[], ARRAY[96], 96, 1.0);
        RAISE EXCEPTION 'invalid level should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_forecast input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_forecast(ARRAY[1.0]::float8[], ARRAY[0], 96, 0.95);
        RAISE EXCEPTION 'invalid periods should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_forecast input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_forecast(ARRAY[1.0]::float8[], ARRAY[96], 0, 0.95);
        RAISE EXCEPTION 'invalid horizon should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_forecast input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_forecast(ARRAY['NaN'::float8], ARRAY[96], 96, 0.95);
        RAISE EXCEPTION 'non-finite values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_forecast input:%' THEN
                RAISE;
            END IF;
        END;

    BEGIN
        PERFORM augurs_detect_periods(ARRAY[]::float8[]);
        RAISE EXCEPTION 'empty seasonality values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_periods input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_periods(ARRAY['NaN'::float8]);
        RAISE EXCEPTION 'non-finite seasonality values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_periods input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_periods(ARRAY[1.0]::float8[], 0, NULL, NULL);
        RAISE EXCEPTION 'non-positive minimum period should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_periods input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_periods(ARRAY[1.0]::float8[], NULL, 0, NULL);
        RAISE EXCEPTION 'non-positive maximum period should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_periods input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_periods(ARRAY[1.0]::float8[], 8, 4, NULL);
        RAISE EXCEPTION 'reversed period bounds should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_periods input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_periods(ARRAY[1.0]::float8[], NULL, NULL, 'NaN'::float8);
        RAISE EXCEPTION 'non-finite threshold should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_periods input:%' THEN
                RAISE;
            END IF;
        END;

    BEGIN
        PERFORM augurs_detect_changepoints(ARRAY[]::float8[]);
        RAISE EXCEPTION 'empty changepoint values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_changepoints input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_changepoints(
            ARRAY[1.0, NULL, 1.0, 1.0]::float8[]
        );
        RAISE EXCEPTION 'NULL changepoint values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_changepoints input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_changepoints(
            ARRAY['NaN'::float8, 1.0, 1.0, 1.0]
        );
        RAISE EXCEPTION 'non-finite changepoint values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_changepoints input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_changepoints(
            ARRAY['Infinity'::float8, 1.0, 1.0, 1.0]
        );
        RAISE EXCEPTION 'infinite changepoint values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_changepoints input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_detect_changepoints(ARRAY[1.0, 2.0, 3.0]::float8[]);
        RAISE EXCEPTION 'too-short changepoint values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_detect_changepoints input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(ARRAY[]::float8[], ARRAY[2]);
        RAISE EXCEPTION 'empty decomposition values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(ARRAY[NULL]::float8[], ARRAY[2]);
        RAISE EXCEPTION 'NULL decomposition values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(ARRAY['NaN'::float8], ARRAY[2]);
        RAISE EXCEPTION 'non-finite decomposition values should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(ARRAY[1.0, 2.0, 3.0, 4.0]::float8[], ARRAY[]::integer[]);
        RAISE EXCEPTION 'empty decomposition periods should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(ARRAY[1.0, 2.0, 3.0, 4.0]::float8[], ARRAY[1]);
        RAISE EXCEPTION 'period one should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(ARRAY[1.0, 2.0, 3.0]::float8[], ARRAY[2]);
        RAISE EXCEPTION 'insufficient decomposition history should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;

    BEGIN
        PERFORM augurs_mstl_decompose(
            ARRAY[1.0, 2.0, 3.0, 4.0]::float8[],
            ARRAY[NULL]::integer[]
        );
        RAISE EXCEPTION 'NULL decomposition periods should be rejected';
    EXCEPTION
        WHEN others THEN
            IF SQLERRM NOT LIKE 'invalid augurs_mstl_decompose input:%' THEN
                RAISE;
            END IF;
    END;
END
$$;
