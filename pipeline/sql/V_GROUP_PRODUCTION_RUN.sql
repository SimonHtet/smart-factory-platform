-- ============================================================
-- V_GROUP_PRODUCTION_RUN
-- Database : DB_BUDIBASE
-- Schema   : analytics
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- PURPOSE
-- -------
-- Group-level summary view over analytics.temp_production_run.
-- A / D / M machines are aggregated by machine prefix + product_date.
-- B1, B2 appear as individual rows (no peer machines to group with).
--
-- Efficiency = SUM(out_feed_mc) / (SUM(run_duration_minutes) * 400)
-- date_status = 'Today' for the latest product_date per group,
--               YYYY-MM-DD string for all older dates (sorts correctly).
-- ============================================================

CREATE OR ALTER VIEW [analytics].[v_group_production_run] AS
WITH grouped AS (
    -- A, D, M: grouped by machine prefix + product_date
    SELECT
        CASE
            WHEN machine LIKE 'A%' THEN 'Group A'
            WHEN machine LIKE 'D%' THEN 'Group D'
            WHEN machine LIKE 'M%' THEN 'Group M'
        END                                     AS machine_group,
        product_date,
        SUM(run_duration_minutes)               AS total_run_duration_minutes,
        SUM(in_feed_mc)                         AS in_feed_mc,
        SUM(out_feed_mc)                        AS out_feed_mc,
        SUM(waste_tba)                          AS waste_tba,
        SUM(scanned_briks)                      AS scanned_briks,
        SUM(waste_op)                           AS waste_op,
        SUM(downtime_count)                     AS downtime_count,
        SUM(total_downtime_seconds)             AS total_downtime_seconds,
        SUM(total_downtime_minutes)             AS total_downtime_minutes,
        SUM(downtime_lost_briks)                AS downtime_lost_briks,
        MAX(last_updated)                       AS last_updated
    FROM [analytics].[temp_production_run]
    WHERE machine LIKE 'A%' OR machine LIKE 'D%' OR machine LIKE 'M%'
    GROUP BY
        CASE
            WHEN machine LIKE 'A%' THEN 'Group A'
            WHEN machine LIKE 'D%' THEN 'Group D'
            WHEN machine LIKE 'M%' THEN 'Group M'
        END,
        product_date

    UNION ALL

    -- B1, B2: individual rows, no grouping
    SELECT
        machine                                 AS machine_group,
        product_date,
        run_duration_minutes                    AS total_run_duration_minutes,
        in_feed_mc,
        out_feed_mc,
        waste_tba,
        scanned_briks,
        waste_op,
        downtime_count,
        total_downtime_seconds,
        total_downtime_minutes,
        downtime_lost_briks,
        last_updated
    FROM [analytics].[temp_production_run]
    WHERE machine IN ('B1', 'B2')
)
SELECT
    machine_group,
    product_date,
    total_run_duration_minutes,
    in_feed_mc,
    out_feed_mc,
    waste_tba,
    CAST(waste_tba AS FLOAT) / NULLIF(out_feed_mc, 0)                  AS waste_tba_pct,
    scanned_briks,
    waste_op,
    downtime_count,
    total_downtime_seconds,
    total_downtime_minutes,
    downtime_lost_briks,
    out_feed_mc   / NULLIF(total_run_duration_minutes * 400.0, 0)       AS efficiency_outfeed,
    scanned_briks / NULLIF(total_run_duration_minutes * 400.0, 0)       AS efficiency_scanned,
    downtime_lost_briks / NULLIF(out_feed_mc, 0)                        AS efficiency_lost_downtime,
    last_updated,
    CASE
        WHEN product_date = MAX(product_date) OVER (PARTITION BY machine_group)
        THEN 'Today'
        ELSE CONVERT(varchar, product_date, 23)
    END                                                                  AS date_status
FROM grouped;
GO
