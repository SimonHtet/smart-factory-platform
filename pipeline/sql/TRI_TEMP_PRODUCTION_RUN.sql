-- ============================================================
-- TRI_TEMP_PRODUCTION_RUN
-- Database : DB_BUDIBASE
-- Table    : analytics.temp_production_run
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- PURPOSE
-- -------
-- Temporary replacement for dbt mart_production_runs while
-- WMS ingest is paused (IT security review).
-- Tracks efficiency, waste, downtime — no WMS/FG columns.
--
-- Fires on T_M_Filler_Process splice signals (0->1):
--   Paper_Splicing_In_roll_Signal_Brik
--   Paper_Splicing_End_roll_Signal_Brik
--   Strip_Splicing_Signal_Strip
--
-- ZERO-GUARD (V2)
-- -------
-- WHEN MATCHED: in_feed_mc / out_feed_mc are only overwritten
-- when the incoming value is > 0.  If the PLC momentarily
-- sends 0 (machine stopped, counter reset, end-of-day reset),
-- the existing non-zero values are preserved.
-- Derived columns (waste_tba, efficiency_*) are also kept
-- when both counters are 0.
--
-- END-TIME LOCK (V2)
-- -------
-- Once end_time is written (batch closed), in_feed_mc,
-- out_feed_mc, and all derived counter columns are frozen.
-- Stale or cross-batch splice signals cannot corrupt closed rows.
--
-- STEPS
-- -------
-- STEP 1 : CREATE TABLE  (run once)
-- STEP 2 : CREATE TRIGGER
-- STEP 3 : Historical backfill from 2026-01-01
-- STEP 4 : Quick manual refresh (current open batch per machine)
-- ============================================================

-- ============================================================
-- STEP 1 : CREATE TABLE
-- Run once in SSMS.  Skip if table already exists.
-- ============================================================
/*
CREATE TABLE [analytics].[temp_production_run] (
    run_key                  VARCHAR(20)  NOT NULL PRIMARY KEY,
    machine                  NVARCHAR(50),
    product_date             DATE,
    product_id               NVARCHAR(100),
    start_time               DATETIME,
    end_time                 DATETIME,
    end_time_cip             DATETIME,
    run_duration_minutes     INT,
    in_feed_mc               INT,
    out_feed_mc              INT,
    waste_tba                INT,
    scanned_briks            INT,
    waste_op                 INT,
    downtime_count           INT,
    total_downtime_seconds   INT,
    downtime_lost_briks      FLOAT,
    efficiency_outfeed       FLOAT,
    efficiency_scanned       FLOAT,
    efficiency_lost_downtime FLOAT,
    last_updated             DATETIME
);

-- If table already exists but is missing downtime_lost_briks:
-- ALTER TABLE [analytics].[temp_production_run]
-- ADD downtime_lost_briks FLOAT NULL;
*/


-- ============================================================
-- STEP 2 : TRIGGER
-- ============================================================
CREATE OR ALTER TRIGGER [dbo].[TRI_TEMP_PRODUCTION_RUN]
ON [dbo].[T_M_Filler_Process]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Only proceed when at least one splice signal went 0->1
    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON i.Machine = d.Machine
        WHERE (i.Paper_Splicing_In_roll_Signal_Brik  = 1 AND d.Paper_Splicing_In_roll_Signal_Brik  = 0)
           OR (i.Paper_Splicing_End_roll_Signal_Brik = 1 AND d.Paper_Splicing_End_roll_Signal_Brik = 0)
           OR (i.Strip_Splicing_Signal_Strip         = 1 AND d.Strip_Splicing_Signal_Strip         = 0)
    )
    RETURN;

    BEGIN TRANSACTION;
    BEGIN TRY

        -- Source: one row per machine that fired a splice signal
        -- Uses live counter values from T_M_Filler_Process (INSERTED)
        -- and metadata from the latest [Change paper brik] row
        ;WITH src AS (
            SELECT
                CONVERT(varchar, cpb.[Product Date], 112) + i.Machine   AS run_key,
                i.Machine                                                AS machine,
                CAST(cpb.[Product Date] AS DATE)                         AS product_date,
                cpb.[Product_ID]                                         AS product_id,
                cpb.[Splicing time 1]                                    AS start_time,
                cpb.[end time]                                           AS end_time,
                cpb.[End_time_CIP]                                       AS end_time_cip,
                DATEDIFF(minute, cpb.[Splicing time 1], cpb.[end time])  AS run_duration_minutes,
                i.counter_infeed                                         AS in_feed_mc,
                i.counter_outfeed                                        AS out_feed_mc,
                ISNULL(cpb.[total_Var_Brik], 0)                         AS scanned_briks,
                ISNULL(cpb.[Downtime_Count], 0)                         AS downtime_count,
                ISNULL(cpb.[Total_Downtime_Seconds], 0)                 AS total_downtime_seconds
            FROM inserted i
            JOIN deleted  d  ON i.Machine = d.Machine
            JOIN [dbo].[Change paper brik] cpb
                ON cpb.Machine = i.Machine
               AND cpb.ID = (
                    SELECT MAX(ID)
                    FROM [dbo].[Change paper brik]
                    WHERE Machine = i.Machine
                )
            WHERE (i.Paper_Splicing_In_roll_Signal_Brik  = 1 AND d.Paper_Splicing_In_roll_Signal_Brik  = 0)
               OR (i.Paper_Splicing_End_roll_Signal_Brik = 1 AND d.Paper_Splicing_End_roll_Signal_Brik = 0)
               OR (i.Strip_Splicing_Signal_Strip         = 1 AND d.Strip_Splicing_Signal_Strip         = 0)
        )

        MERGE [analytics].[temp_production_run] AS tgt
        USING src ON tgt.run_key = src.run_key

        -- -------------------------------------------------------
        -- UPDATE existing row
        -- End-time lock: if batch is already closed (end_time set),
        -- counter columns and derived metrics are frozen.
        -- Zero-guard on top: also skip if incoming counter is 0.
        -- -------------------------------------------------------
        WHEN MATCHED THEN UPDATE SET

            tgt.end_time             = src.end_time,
            tgt.end_time_cip         = src.end_time_cip,
            tgt.run_duration_minutes = src.run_duration_minutes,
            tgt.scanned_briks        = src.scanned_briks,
            tgt.downtime_count       = src.downtime_count,
            tgt.total_downtime_seconds = src.total_downtime_seconds,
            tgt.downtime_lost_briks  = (src.total_downtime_seconds / 60.0) * 400,

            -- Counter lock: if batch is already closed (end_time set), never
            -- overwrite in_feed_mc / out_feed_mc — any later splice signal
            -- belongs to a new batch or is a stale signal.
            -- Zero-guard on top: also skip if incoming counter is 0.
            tgt.in_feed_mc  = CASE
                WHEN tgt.end_time IS NOT NULL THEN tgt.in_feed_mc
                WHEN src.in_feed_mc  > 0     THEN src.in_feed_mc
                ELSE tgt.in_feed_mc
            END,
            tgt.out_feed_mc = CASE
                WHEN tgt.end_time IS NOT NULL THEN tgt.out_feed_mc
                WHEN src.out_feed_mc > 0     THEN src.out_feed_mc
                ELSE tgt.out_feed_mc
            END,

            -- waste_tba: only update when batch is still open and counters are valid
            tgt.waste_tba = CASE
                WHEN tgt.end_time IS NOT NULL                        THEN tgt.waste_tba
                WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0     THEN src.in_feed_mc - src.out_feed_mc
                ELSE tgt.waste_tba
            END,

            -- waste_op: same end_time lock
            tgt.waste_op = CASE
                WHEN tgt.end_time IS NOT NULL THEN tgt.waste_op
                WHEN src.in_feed_mc > 0       THEN src.scanned_briks - src.in_feed_mc
                ELSE tgt.waste_op
            END,

            -- efficiency_outfeed: locked once batch closed
            tgt.efficiency_outfeed = CASE
                WHEN tgt.end_time IS NOT NULL                                                    THEN tgt.efficiency_outfeed
                WHEN src.out_feed_mc > 0 AND src.run_duration_minutes > 0                       THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
                WHEN src.out_feed_mc = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0 THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
                ELSE tgt.efficiency_outfeed
            END,

            -- efficiency_scanned: locked once batch closed
            tgt.efficiency_scanned = CASE
                WHEN tgt.end_time IS NOT NULL                                  THEN tgt.efficiency_scanned
                WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0   THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
                ELSE tgt.efficiency_scanned
            END,

            -- efficiency_lost_downtime: locked once batch closed
            tgt.efficiency_lost_downtime = CASE
                WHEN tgt.end_time IS NOT NULL THEN tgt.efficiency_lost_downtime
                WHEN src.out_feed_mc  > 0    THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
                WHEN src.scanned_briks > 0   THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
                ELSE tgt.efficiency_lost_downtime
            END,

            tgt.last_updated = GETUTCDATE()

        -- -------------------------------------------------------
        -- INSERT new row (first splice signal for this run_key)
        -- -------------------------------------------------------
        WHEN NOT MATCHED THEN INSERT (
            run_key, machine, product_date, product_id,
            start_time, end_time, end_time_cip, run_duration_minutes,
            in_feed_mc, out_feed_mc, waste_tba, scanned_briks, waste_op,
            downtime_count, total_downtime_seconds, downtime_lost_briks,
            efficiency_outfeed, efficiency_scanned, efficiency_lost_downtime,
            last_updated
        ) VALUES (
            src.run_key, src.machine, src.product_date, src.product_id,
            src.start_time, src.end_time, src.end_time_cip, src.run_duration_minutes,
            src.in_feed_mc, src.out_feed_mc,
            -- waste_tba
            CASE WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0
                 THEN src.in_feed_mc - src.out_feed_mc ELSE NULL END,
            src.scanned_briks,
            -- waste_op
            CASE WHEN src.in_feed_mc > 0 THEN src.scanned_briks - src.in_feed_mc ELSE NULL END,
            src.downtime_count,
            src.total_downtime_seconds,
            (src.total_downtime_seconds / 60.0) * 400,
            -- efficiency_outfeed
            CASE
                WHEN src.out_feed_mc  > 0 AND src.run_duration_minutes > 0
                    THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
                WHEN src.out_feed_mc  = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0
                    THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
                ELSE NULL
            END,
            -- efficiency_scanned
            CASE
                WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0
                    THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
                ELSE NULL
            END,
            -- efficiency_lost_downtime
            CASE
                WHEN src.out_feed_mc  > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
                WHEN src.scanned_briks > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
                ELSE NULL
            END,
            GETUTCDATE()
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION;
        INSERT INTO t_log(txt)
        VALUES ('TRI_TEMP_PRODUCTION_RUN:ERROR:' + ERROR_MESSAGE());
    END CATCH
END;
GO


-- ============================================================
-- STEP 3 : Historical backfill from 2026-01-01
-- Run once in SSMS after deploying the trigger.
-- Deduplicates by run_key (Machine + product_date) using MAX(ID)
-- to avoid the MERGE duplicate row error.
-- Old rows are never deleted.
-- ============================================================
/*
;WITH base AS (
    SELECT
        cpb.Machine,
        CAST(cpb.[Product Date] AS DATE)                                        AS product_date_key,
        MAX(cpb.ID)                                                             AS max_id
    FROM [dbo].[Change paper brik] cpb
    WHERE cpb.[Product Date] IS NOT NULL
      AND cpb.Machine IS NOT NULL
      AND CAST(cpb.[Product Date] AS DATE) >= '2026-01-01'
    GROUP BY cpb.Machine, CAST(cpb.[Product Date] AS DATE)
),

src AS (
    SELECT
        CONVERT(varchar, b.product_date_key, 112) + b.Machine                  AS run_key,
        b.Machine                                                               AS machine,
        b.product_date_key                                                      AS product_date,
        cpb.[Product_ID]                                                        AS product_id,
        cpb.[Splicing time 1]                                                   AS start_time,
        cpb.[end time]                                                          AS end_time,
        cpb.[End_time_CIP]                                                      AS end_time_cip,
        DATEDIFF(minute, cpb.[Splicing time 1], cpb.[end time])                AS run_duration_minutes,

        -- For open batches: use live counter from T_M_Filler_Process
        -- For closed batches: use stored value from Change paper brik
        COALESCE(
            CASE WHEN cpb.[end time] IS NULL THEN filler.counter_infeed  ELSE NULL END,
            cpb.[In_Feed_MC]
        )                                                                       AS in_feed_mc,
        COALESCE(
            CASE WHEN cpb.[end time] IS NULL THEN filler.counter_outfeed ELSE NULL END,
            cpb.[Out_Feed_MC]
        )                                                                       AS out_feed_mc,

        ISNULL(cpb.[total_Var_Brik], 0)                                        AS scanned_briks,
        ISNULL(cpb.[Downtime_Count], 0)                                        AS downtime_count,
        ISNULL(cpb.[Total_Downtime_Seconds], 0)                               AS total_downtime_seconds
    FROM base b
    JOIN [dbo].[Change paper brik] cpb ON cpb.ID = b.max_id
    LEFT JOIN [dbo].[T_M_Filler_Process] filler ON filler.Machine = b.Machine
)

MERGE [analytics].[temp_production_run] AS tgt
USING src ON tgt.run_key = src.run_key

WHEN MATCHED THEN UPDATE SET
    tgt.end_time             = src.end_time,
    tgt.end_time_cip         = src.end_time_cip,
    tgt.run_duration_minutes = src.run_duration_minutes,
    tgt.scanned_briks        = src.scanned_briks,
    tgt.downtime_count       = src.downtime_count,
    tgt.total_downtime_seconds = src.total_downtime_seconds,
    tgt.downtime_lost_briks  = (src.total_downtime_seconds / 60.0) * 400,

    tgt.in_feed_mc  = CASE WHEN src.in_feed_mc  > 0 THEN src.in_feed_mc  ELSE tgt.in_feed_mc  END,
    tgt.out_feed_mc = CASE WHEN src.out_feed_mc > 0 THEN src.out_feed_mc ELSE tgt.out_feed_mc END,

    tgt.waste_tba = CASE
        WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0
            THEN src.in_feed_mc - src.out_feed_mc
        ELSE tgt.waste_tba
    END,
    tgt.waste_op = CASE
        WHEN src.in_feed_mc > 0 THEN src.scanned_briks - src.in_feed_mc
        ELSE tgt.waste_op
    END,

    tgt.efficiency_outfeed = CASE
        WHEN src.out_feed_mc  > 0 AND src.run_duration_minutes > 0
            THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
        WHEN src.out_feed_mc  = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0
            THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE tgt.efficiency_outfeed
    END,
    tgt.efficiency_scanned = CASE
        WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0
            THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE tgt.efficiency_scanned
    END,
    tgt.efficiency_lost_downtime = CASE
        WHEN src.out_feed_mc  > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
        WHEN src.scanned_briks > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
        ELSE tgt.efficiency_lost_downtime
    END,

    tgt.last_updated = GETUTCDATE()

WHEN NOT MATCHED THEN INSERT (
    run_key, machine, product_date, product_id,
    start_time, end_time, end_time_cip, run_duration_minutes,
    in_feed_mc, out_feed_mc, waste_tba, scanned_briks, waste_op,
    downtime_count, total_downtime_seconds, downtime_lost_briks,
    efficiency_outfeed, efficiency_scanned, efficiency_lost_downtime,
    last_updated
) VALUES (
    src.run_key, src.machine, src.product_date, src.product_id,
    src.start_time, src.end_time, src.end_time_cip, src.run_duration_minutes,
    src.in_feed_mc, src.out_feed_mc,
    CASE WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0
         THEN src.in_feed_mc - src.out_feed_mc ELSE NULL END,
    src.scanned_briks,
    CASE WHEN src.in_feed_mc > 0 THEN src.scanned_briks - src.in_feed_mc ELSE NULL END,
    src.downtime_count,
    src.total_downtime_seconds,
    (src.total_downtime_seconds / 60.0) * 400,
    CASE
        WHEN src.out_feed_mc  > 0 AND src.run_duration_minutes > 0
            THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
        WHEN src.out_feed_mc  = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0
            THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE NULL
    END,
    CASE
        WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0
            THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE NULL
    END,
    CASE
        WHEN src.out_feed_mc  > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
        WHEN src.scanned_briks > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
        ELSE NULL
    END,
    GETUTCDATE()
);
*/


-- ============================================================
-- STEP 4 : Quick manual refresh for a specific date
-- Use this to re-sync rows for a given product_date.
-- Replace '2026-05-29' with the date you want to refresh.
-- Zero-guard applies here too: won't overwrite non-zero values
-- with 0 when [Change paper brik] has no counter data.
-- ============================================================
/*
;WITH base AS (
    SELECT
        cpb.Machine,
        CAST(cpb.[Product Date] AS DATE)    AS product_date_key,
        MAX(cpb.ID)                         AS max_id
    FROM [dbo].[Change paper brik] cpb
    WHERE CAST(cpb.[Product Date] AS DATE) = '2026-05-29'   -- change date here
      AND cpb.Machine IS NOT NULL
    GROUP BY cpb.Machine, CAST(cpb.[Product Date] AS DATE)
),
src AS (
    SELECT
        CONVERT(varchar, b.product_date_key, 112) + b.Machine  AS run_key,
        cpb.[Splicing time 1]                                   AS start_time,
        cpb.[end time]                                          AS end_time,
        cpb.[End_time_CIP]                                      AS end_time_cip,
        DATEDIFF(minute, cpb.[Splicing time 1], cpb.[end time]) AS run_duration_minutes,
        cpb.[In_Feed_MC]                                        AS in_feed_mc,
        cpb.[Out_Feed_MC]                                       AS out_feed_mc,
        ISNULL(cpb.[total_Var_Brik], 0)                        AS scanned_briks,
        ISNULL(cpb.[Downtime_Count], 0)                        AS downtime_count,
        ISNULL(cpb.[Total_Downtime_Seconds], 0)               AS total_downtime_seconds
    FROM base b
    JOIN [dbo].[Change paper brik] cpb ON cpb.ID = b.max_id
)
UPDATE tpr
SET
    tpr.start_time           = src.start_time,
    tpr.end_time             = src.end_time,
    tpr.end_time_cip         = src.end_time_cip,
    tpr.run_duration_minutes = src.run_duration_minutes,
    tpr.scanned_briks        = src.scanned_briks,
    tpr.downtime_count       = src.downtime_count,
    tpr.total_downtime_seconds = src.total_downtime_seconds,
    tpr.downtime_lost_briks  = (src.total_downtime_seconds / 60.0) * 400,

    -- Zero-guard: keep existing value when source is 0
    tpr.in_feed_mc  = CASE WHEN src.in_feed_mc  > 0 THEN src.in_feed_mc  ELSE tpr.in_feed_mc  END,
    tpr.out_feed_mc = CASE WHEN src.out_feed_mc > 0 THEN src.out_feed_mc ELSE tpr.out_feed_mc END,

    tpr.waste_tba = CASE
        WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0
            THEN src.in_feed_mc - src.out_feed_mc
        ELSE tpr.waste_tba
    END,
    tpr.waste_op = CASE
        WHEN src.in_feed_mc > 0 THEN src.scanned_briks - src.in_feed_mc
        ELSE tpr.waste_op
    END,
    tpr.efficiency_outfeed = CASE
        WHEN src.out_feed_mc  > 0 AND src.run_duration_minutes > 0
            THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
        WHEN src.out_feed_mc  = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0
            THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE tpr.efficiency_outfeed
    END,
    tpr.efficiency_scanned = CASE
        WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0
            THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE tpr.efficiency_scanned
    END,
    tpr.efficiency_lost_downtime = CASE
        WHEN src.out_feed_mc  > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
        WHEN src.scanned_briks > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
        ELSE tpr.efficiency_lost_downtime
    END,

    tpr.last_updated = GETUTCDATE()

FROM [analytics].[temp_production_run] tpr
JOIN src ON tpr.run_key = src.run_key;
*/
