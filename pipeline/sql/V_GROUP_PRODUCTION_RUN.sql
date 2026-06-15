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
--
-- 2026-06-15 — BIG DOWNTIME segment correction (pairs with V5.5)
-- -------------------------------------------------------
-- On a big breakdown the OPMS feed counter resets to 0 mid-batch
-- without a CIP (130000 -> 0 -> 150000). temp_production_run only
-- carries the FINAL segment (150000); the pre-reset segments are
-- captured in dbo.Feed_Segment_log by TRI_UPDATE_FILLER_V5.5.
-- The `seg` CTE sums those lost segments per machine + product_date
-- (1 batch ≈ 1 CIP-to-CIP loop ≈ 1 day, so this maps 1:1 to a tpr
-- row) and adds them back into in_feed_mc / out_feed_mc / waste_tba.
-- efficiency_outfeed recomputes off the corrected out_feed_mc.
--
-- ASSUMPTION (verify with VERIFY query at bottom): tpr.in_feed_mc
-- holds the LAST segment (e.g. 150000) and Feed_Segment_log holds
-- only the PRIOR breakdown segments (e.g. 130000) — so adding them
-- is correct and never double-counts. If tpr ever froze on the
-- FIRST segment instead, this would over-count; the VERIFY query
-- catches that on day one.
--
-- 2026-06-15 — BIG DOWNTIME loss exposure (pairs with V5.6)
-- -------------------------------------------------------
-- The `bdl` CTE sums big-downtime DURATION (CLOSED rows only) from
-- dbo.Big_Downtime_log per machine + product_date and exposes it as
-- big_downtime_seconds / _minutes / _lost_briks (= minutes * 400),
-- kept SEPARATE from the mini-stoppage downtime_* columns so the two
-- stay splittable (matches the >30-min breakdown classification).
-- OPEN rows are excluded (not finished); VOID rows are excluded (FCIP
-- = intentional end, not a loss).
-- ============================================================

CREATE OR ALTER VIEW [analytics].[v_group_production_run] AS
WITH seg AS (
    -- feed lost to big-downtime resets, per machine per product_date
    SELECT
        cpb.Machine                       AS machine,
        CAST(cpb.[Product Date] AS DATE)  AS product_date,
        SUM(fs.In_Feed_Seg)               AS seg_in_feed,
        SUM(fs.Out_Feed_Seg)              AS seg_out_feed
    FROM [dbo].[Feed_Segment_log] fs
    JOIN [dbo].[Change paper brik] cpb ON cpb.ID = fs.Batch_ID
    GROUP BY cpb.Machine, CAST(cpb.[Product Date] AS DATE)
),
bdl AS (
    -- big-downtime time loss (CLOSED rows only) per machine per product_date
    SELECT
        cpb.Machine                       AS machine,
        CAST(cpb.[Product Date] AS DATE)  AS product_date,
        SUM(bd.Duration_Seconds)          AS big_dt_seconds
    FROM [dbo].[Big_Downtime_log] bd
    JOIN [dbo].[Change paper brik] cpb ON cpb.ID = bd.Batch_ID
    WHERE bd.Status = 'CLOSED'
    GROUP BY cpb.Machine, CAST(cpb.[Product Date] AS DATE)
),
tpr AS (
    SELECT
        t.*,
        ISNULL(s.seg_in_feed, 0)    AS seg_in_feed,
        ISNULL(s.seg_out_feed, 0)   AS seg_out_feed,
        ISNULL(b.big_dt_seconds, 0) AS big_dt_seconds
    FROM [analytics].[temp_production_run] t
    LEFT JOIN seg s
        ON s.machine = t.machine
       AND s.product_date = t.product_date
    LEFT JOIN bdl b
        ON b.machine = t.machine
       AND b.product_date = t.product_date
),
grouped AS (
    -- A, D, M: grouped by machine prefix + product_date
    SELECT
        CASE
            WHEN machine LIKE 'A%' THEN 'Group A'
            WHEN machine LIKE 'D%' THEN 'Group D'
            WHEN machine LIKE 'M%' THEN 'Group M'
        END                                     AS machine_group,
        product_date,
        SUM(run_duration_minutes)               AS total_run_duration_minutes,
        SUM(in_feed_mc  + seg_in_feed)          AS in_feed_mc,
        SUM(out_feed_mc + seg_out_feed)         AS out_feed_mc,
        SUM(waste_tba + (seg_in_feed - seg_out_feed)) AS waste_tba,
        SUM(scanned_briks)                      AS scanned_briks,
        SUM(waste_op)                           AS waste_op,
        SUM(downtime_count)                     AS downtime_count,
        SUM(total_downtime_seconds)             AS total_downtime_seconds,
        SUM(total_downtime_minutes)             AS total_downtime_minutes,
        SUM(downtime_lost_briks)                AS downtime_lost_briks,
        SUM(big_dt_seconds)                     AS big_downtime_seconds,
        SUM(big_dt_seconds) / 60.0              AS big_downtime_minutes,
        (SUM(big_dt_seconds) / 60.0) * 400      AS big_downtime_lost_briks,
        MAX(last_updated)                       AS last_updated
    FROM tpr
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
        in_feed_mc  + seg_in_feed               AS in_feed_mc,
        out_feed_mc + seg_out_feed              AS out_feed_mc,
        waste_tba + (seg_in_feed - seg_out_feed) AS waste_tba,
        scanned_briks,
        waste_op,
        downtime_count,
        total_downtime_seconds,
        total_downtime_minutes,
        downtime_lost_briks,
        big_dt_seconds                          AS big_downtime_seconds,
        big_dt_seconds / 60.0                   AS big_downtime_minutes,
        (big_dt_seconds / 60.0) * 400           AS big_downtime_lost_briks,
        last_updated
    FROM tpr
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
    big_downtime_seconds,
    big_downtime_minutes,
    big_downtime_lost_briks,
    out_feed_mc   / NULLIF(total_run_duration_minutes * 400.0, 0)       AS efficiency_outfeed,
    scanned_briks / NULLIF(total_run_duration_minutes * 400.0, 0)       AS efficiency_scanned,
    downtime_lost_briks     / NULLIF(out_feed_mc, 0)                    AS efficiency_lost_downtime,
    big_downtime_lost_briks / NULLIF(out_feed_mc, 0)                    AS efficiency_lost_big_downtime,
    last_updated,
    CASE
        WHEN product_date = MAX(product_date) OVER (PARTITION BY machine_group)
        THEN 'Today'
        ELSE CONVERT(varchar, product_date, 23)
    END                                                                  AS date_status
FROM grouped;
GO

-- ============================================================
-- VERIFY (run after first big downtime with a logged segment)
-- Confirms tpr keeps the FINAL segment and the log keeps the PRIOR
-- ones — i.e. seg + tpr = true total, no double count.
-- ============================================================
/*
SELECT
    fs.Machine,
    CAST(cpb.[Product Date] AS DATE)        AS product_date,
    SUM(fs.In_Feed_Seg)                     AS prior_segments_infeed,   -- e.g. 130000
    MAX(tpr.in_feed_mc)                      AS tpr_final_infeed,        -- expect 150000, NOT 130000
    SUM(fs.In_Feed_Seg) + MAX(tpr.in_feed_mc) AS true_total_infeed       -- expect 280000
FROM [dbo].[Feed_Segment_log] fs
JOIN [dbo].[Change paper brik] cpb ON cpb.ID = fs.Batch_ID
JOIN [analytics].[temp_production_run] tpr
     ON tpr.machine = fs.Machine
    AND tpr.product_date = CAST(cpb.[Product Date] AS DATE)
GROUP BY fs.Machine, CAST(cpb.[Product Date] AS DATE)
ORDER BY product_date DESC;
*/

-- ============================================================
-- SAFETY NET — stale open CIP detector (orphan batch alarm)
-- If an FCIP sensor misses, End_time_CIP stays NULL forever and the
-- next batch's reset would accumulate onto the dead one. Surface it
-- instead of letting totals balloon silently. Tune the -8h window.
-- ============================================================
/*
SELECT Machine, ID AS Batch_ID, [end time],
       DATEDIFF(HOUR, [end time], GETUTCDATE()) AS hrs_open
FROM [dbo].[Change paper brik]
WHERE End_time_CIP IS NULL
  AND (Machine LIKE 'A%' OR Machine LIKE 'B%' OR Machine LIKE 'D%' OR Machine LIKE 'M%')
  AND [end time] < DATEADD(HOUR, -8, GETUTCDATE())
ORDER BY hrs_open DESC;
*/
