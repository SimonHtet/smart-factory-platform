-- ============================================================
-- TRI_TEMP_PRODUCTION_RUN
-- Database : DB_BUDIBASE
-- Table    : analytics.temp_production_run
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- WMS-free replacement for mart_production_runs while WMS ingest
-- is paused (IT security review). Tracks efficiency, waste,
-- downtime per machine per day from T_M_Filler_Process signals.
--
-- Fires on: splice signals (0->1), Step 13, Step 14+CIP (A/D/M)
-- Guards  : zero-guard on counters, end-time lock on closed rows
--
-- STEP 1 : CREATE TABLE  (run once)
-- STEP 2 : CREATE TRIGGER
-- STEP 3 : Manual refresh for a specific date
-- ============================================================


-- ============================================================
-- STEP 1 : CREATE TABLE  (run once, skip if exists)
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
    waste_tba_pct            FLOAT,
    scanned_briks            INT,
    waste_op                 INT,
    downtime_count           INT,
    total_downtime_seconds   INT,
    total_downtime_minutes   FLOAT,
    downtime_lost_briks      FLOAT,
    efficiency_outfeed       FLOAT,
    efficiency_scanned       FLOAT,
    efficiency_lost_downtime FLOAT,
    last_updated             DATETIME,
    date_status AS (
        CASE
            WHEN product_date = CAST(GETDATE() AS DATE)
                THEN 'Today'
            ELSE CONVERT(varchar, product_date, 23)
        END
    )
);

-- Add missing columns to existing table:
-- ALTER TABLE [analytics].[temp_production_run] ADD total_downtime_minutes   FLOAT NULL;
-- ALTER TABLE [analytics].[temp_production_run] ADD downtime_lost_briks      FLOAT NULL;
-- ALTER TABLE [analytics].[temp_production_run] ADD waste_tba_pct            FLOAT NULL;
-- ALTER TABLE [analytics].[temp_production_run] ADD date_status AS (
--     CASE WHEN product_date = CAST(GETDATE() AS DATE) THEN 'Today'
--          ELSE CONVERT(varchar, product_date, 23) END
-- );
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

    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted d ON i.Machine = d.Machine
        WHERE (i.Paper_Splicing_In_roll_Signal_Brik  = 1 AND d.Paper_Splicing_In_roll_Signal_Brik  = 0)
           OR (i.Paper_Splicing_End_roll_Signal_Brik = 1 AND d.Paper_Splicing_End_roll_Signal_Brik = 0)
           OR (i.Strip_Splicing_Signal_Strip         = 1 AND d.Strip_Splicing_Signal_Strip         = 0)
           OR (i.Machine_Step_No = 13)
           OR (i.Machine_Step_No = 14 AND i.Signal_Final_CIP = 1
               AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%'))
    )
    RETURN;

    BEGIN TRANSACTION;
    BEGIN TRY

        -- Step 13 : close batch — read end_time from [Change paper brik]
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 13)
        BEGIN
            UPDATE tpr
            SET
                tpr.end_time             = ISNULL(cpb.[end time], GETUTCDATE()),
                tpr.run_duration_minutes = DATEDIFF(minute, tpr.start_time, ISNULL(cpb.[end time], GETUTCDATE())),
                tpr.efficiency_outfeed   = CASE
                    WHEN tpr.out_feed_mc   > 0 THEN tpr.out_feed_mc   / (NULLIF(DATEDIFF(minute, tpr.start_time, ISNULL(cpb.[end time], GETUTCDATE())), 0) * 400.0)
                    WHEN tpr.scanned_briks > 0 THEN tpr.scanned_briks / (NULLIF(DATEDIFF(minute, tpr.start_time, ISNULL(cpb.[end time], GETUTCDATE())), 0) * 400.0)
                    ELSE tpr.efficiency_outfeed
                END,
                tpr.efficiency_scanned   = CASE
                    WHEN tpr.scanned_briks > 0 THEN tpr.scanned_briks / (NULLIF(DATEDIFF(minute, tpr.start_time, ISNULL(cpb.[end time], GETUTCDATE())), 0) * 400.0)
                    ELSE tpr.efficiency_scanned
                END,
                tpr.last_updated         = GETUTCDATE()
            FROM [analytics].[temp_production_run] tpr
            JOIN inserted i ON tpr.machine = i.Machine
            CROSS APPLY (
                SELECT TOP 1 [end time]
                FROM [dbo].[Change paper brik]
                WHERE Machine = i.Machine
                ORDER BY ID DESC
            ) cpb
            WHERE i.Machine_Step_No = 13
              AND tpr.start_time IS NOT NULL
              AND (
                    (
                        (i.Machine LIKE 'A%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
                        AND tpr.end_time_cip IS NULL
                    )
                    OR
                    (
                        i.Machine NOT LIKE 'A%'
                        AND i.Machine NOT LIKE 'D%'
                        AND i.Machine NOT LIKE 'M%'
                        AND tpr.end_time IS NULL
                    )
                  );
        END

        -- Step 14 + CIP : write end_time_cip — A/D/M only
        IF EXISTS (
            SELECT 1 FROM inserted
            WHERE Machine_Step_No = 14
              AND Signal_Final_CIP = 1
              AND (Machine LIKE 'A%' OR Machine LIKE 'D%' OR Machine LIKE 'M%')
        )
        BEGIN
            UPDATE tpr
            SET
                tpr.end_time_cip = ISNULL(cpb.[End_time_CIP], GETUTCDATE()),
                tpr.last_updated = GETUTCDATE()
            FROM [analytics].[temp_production_run] tpr
            JOIN inserted i ON tpr.machine = i.Machine
            CROSS APPLY (
                SELECT TOP 1 [End_time_CIP]
                FROM [dbo].[Change paper brik]
                WHERE Machine = i.Machine
                ORDER BY ID DESC
            ) cpb
            WHERE i.Machine_Step_No = 14
              AND i.Signal_Final_CIP = 1
              AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
              AND tpr.end_time_cip IS NULL
              AND tpr.end_time IS NOT NULL;
        END

        -- Splice signals : MERGE live counters into temp_production_run
        ;WITH src AS (
            SELECT
                CONVERT(varchar, cpb.[Product Date], 112) + i.Machine           AS run_key,
                i.Machine                                                        AS machine,
                CAST(cpb.[Product Date] AS DATE)                                 AS product_date,
                cpb.[Product_ID]                                                 AS product_id,
                cpb.[Splicing time 1]                                            AS start_time,
                cpb.[end time]                                                   AS end_time,
                cpb.[End_time_CIP]                                               AS end_time_cip,
                DATEDIFF(minute, cpb.[Splicing time 1],
                    ISNULL(cpb.[end time], GETUTCDATE())) AS run_duration_minutes,
                i.counter_infeed                                                 AS in_feed_mc,
                i.counter_outfeed                                                AS out_feed_mc,
                ISNULL(cpb.[total_Var_Brik], 0)                                 AS scanned_briks,
                ISNULL(cpb.[Downtime_Count], 0)                                 AS downtime_count,
                ISNULL(cpb.[Total_Downtime_Seconds], 0)                         AS total_downtime_seconds
            FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            JOIN [dbo].[Change paper brik] cpb
                ON cpb.Machine = i.Machine
               AND cpb.ID = (SELECT MAX(ID) FROM [dbo].[Change paper brik] WHERE Machine = i.Machine)
            WHERE (i.Paper_Splicing_In_roll_Signal_Brik  = 1 AND d.Paper_Splicing_In_roll_Signal_Brik  = 0)
               OR (i.Paper_Splicing_End_roll_Signal_Brik = 1 AND d.Paper_Splicing_End_roll_Signal_Brik = 0)
               OR (i.Strip_Splicing_Signal_Strip         = 1 AND d.Strip_Splicing_Signal_Strip         = 0)
        )

        MERGE [analytics].[temp_production_run] AS tgt
        USING src ON tgt.run_key = src.run_key

        WHEN MATCHED THEN UPDATE SET

            -- End-time lock: once set by Step 13/14 blocks, never overwrite
            tgt.end_time     = CASE WHEN tgt.end_time     IS NOT NULL THEN tgt.end_time     ELSE src.end_time     END,
            tgt.end_time_cip = CASE WHEN tgt.end_time_cip IS NOT NULL THEN tgt.end_time_cip ELSE src.end_time_cip END,
            tgt.run_duration_minutes   = src.run_duration_minutes,
            tgt.scanned_briks          = src.scanned_briks,
            tgt.downtime_count         = src.downtime_count,
            tgt.total_downtime_seconds = src.total_downtime_seconds,
            tgt.total_downtime_minutes = src.total_downtime_seconds / 60.0,
            tgt.downtime_lost_briks    = (src.total_downtime_seconds / 60.0) * 400,

            -- Counter lock: frozen once closed; zero-guard on open batches
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

            tgt.waste_tba = CASE
                WHEN tgt.end_time IS NOT NULL                    THEN tgt.waste_tba
                WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0 THEN src.in_feed_mc - src.out_feed_mc
                ELSE tgt.waste_tba
            END,
            tgt.waste_tba_pct = CASE
                WHEN tgt.end_time IS NOT NULL                    THEN tgt.waste_tba_pct
                WHEN src.in_feed_mc > 0 AND src.out_feed_mc  > 0 THEN CAST(src.in_feed_mc - src.out_feed_mc AS FLOAT) / src.out_feed_mc
                WHEN src.in_feed_mc > 0 AND src.scanned_briks > 0 THEN CAST(src.in_feed_mc - src.out_feed_mc AS FLOAT) / src.scanned_briks
                ELSE tgt.waste_tba_pct
            END,
            tgt.waste_op = CASE
                WHEN tgt.end_time IS NOT NULL THEN tgt.waste_op
                WHEN src.in_feed_mc > 0       THEN src.scanned_briks - src.in_feed_mc
                ELSE tgt.waste_op
            END,

            tgt.efficiency_outfeed = CASE
                WHEN tgt.end_time IS NOT NULL                                                        THEN tgt.efficiency_outfeed
                WHEN src.out_feed_mc > 0 AND src.run_duration_minutes > 0                           THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
                WHEN src.out_feed_mc = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0 THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
                ELSE tgt.efficiency_outfeed
            END,
            tgt.efficiency_scanned = CASE
                WHEN tgt.end_time IS NOT NULL                                THEN tgt.efficiency_scanned
                WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0 THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
                ELSE tgt.efficiency_scanned
            END,
            tgt.efficiency_lost_downtime = CASE
                WHEN tgt.end_time IS NOT NULL THEN tgt.efficiency_lost_downtime
                WHEN src.out_feed_mc  > 0    THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
                WHEN src.scanned_briks > 0   THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
                ELSE tgt.efficiency_lost_downtime
            END,

            tgt.last_updated = GETUTCDATE()

        WHEN NOT MATCHED AND src.start_time IS NOT NULL THEN INSERT (
            run_key, machine, product_date, product_id,
            start_time, end_time, end_time_cip, run_duration_minutes,
            in_feed_mc, out_feed_mc, waste_tba, waste_tba_pct, scanned_briks, waste_op,
            downtime_count, total_downtime_seconds, total_downtime_minutes, downtime_lost_briks,
            efficiency_outfeed, efficiency_scanned, efficiency_lost_downtime,
            last_updated
        ) VALUES (
            src.run_key, src.machine, src.product_date, src.product_id,
            src.start_time, src.end_time, src.end_time_cip, src.run_duration_minutes,
            src.in_feed_mc, src.out_feed_mc,
            CASE WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0 THEN src.in_feed_mc - src.out_feed_mc ELSE NULL END,
            CASE
                WHEN src.in_feed_mc > 0 AND src.out_feed_mc   > 0 THEN CAST(src.in_feed_mc - src.out_feed_mc AS FLOAT) / src.out_feed_mc
                WHEN src.in_feed_mc > 0 AND src.scanned_briks > 0 THEN CAST(src.in_feed_mc - src.out_feed_mc AS FLOAT) / src.scanned_briks
                ELSE NULL
            END,
            src.scanned_briks,
            CASE WHEN src.in_feed_mc > 0 THEN src.scanned_briks - src.in_feed_mc ELSE NULL END,
            src.downtime_count,
            src.total_downtime_seconds,
            src.total_downtime_seconds / 60.0,
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
                WHEN src.out_feed_mc   > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
                WHEN src.scanned_briks > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
                ELSE NULL
            END,
            GETUTCDATE()
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION;
        INSERT INTO t_log(txt) VALUES ('TRI_TEMP_PRODUCTION_RUN:ERROR:' + ERROR_MESSAGE());
    END CATCH
END;
GO


-- ============================================================
-- STEP 3 : Manual refresh for a specific date
-- Replace '2026-05-29' with the date you want.
-- ============================================================
/*
;WITH base AS (
    SELECT
        cpb.Machine,
        CAST(cpb.[Product Date] AS DATE) AS product_date_key,
        MAX(cpb.ID)                      AS max_id
    FROM [dbo].[Change paper brik] cpb
    WHERE CAST(cpb.[Product Date] AS DATE) = '2026-05-29'
      AND cpb.Machine IS NOT NULL
    GROUP BY cpb.Machine, CAST(cpb.[Product Date] AS DATE)
),
src AS (
    SELECT
        CONVERT(varchar, b.product_date_key, 112) + b.Machine AS run_key,
        cpb.[Splicing time 1]                                  AS start_time,
        cpb.[end time]                                         AS end_time,
        cpb.[End_time_CIP]                                     AS end_time_cip,
        DATEDIFF(minute, cpb.[Splicing time 1],
            ISNULL(cpb.[end time], GETUTCDATE()))              AS run_duration_minutes,
        cpb.[In_Feed_MC]                                       AS in_feed_mc,
        cpb.[Out_Feed_MC]                                      AS out_feed_mc,
        ISNULL(cpb.[total_Var_Brik], 0)                       AS scanned_briks,
        ISNULL(cpb.[Downtime_Count], 0)                       AS downtime_count,
        ISNULL(cpb.[Total_Downtime_Seconds], 0)               AS total_downtime_seconds
    FROM base b
    JOIN [dbo].[Change paper brik] cpb ON cpb.ID = b.max_id
)
UPDATE tpr
SET
    tpr.start_time             = src.start_time,
    tpr.end_time               = src.end_time,
    tpr.end_time_cip           = src.end_time_cip,
    tpr.run_duration_minutes   = src.run_duration_minutes,
    tpr.scanned_briks          = src.scanned_briks,
    tpr.downtime_count         = src.downtime_count,
    tpr.total_downtime_seconds = src.total_downtime_seconds,
    tpr.total_downtime_minutes = src.total_downtime_seconds / 60.0,
    tpr.downtime_lost_briks    = (src.total_downtime_seconds / 60.0) * 400,
    tpr.in_feed_mc    = CASE WHEN src.in_feed_mc  > 0 THEN src.in_feed_mc  ELSE tpr.in_feed_mc  END,
    tpr.out_feed_mc   = CASE WHEN src.out_feed_mc > 0 THEN src.out_feed_mc ELSE tpr.out_feed_mc END,
    tpr.waste_tba     = CASE WHEN src.in_feed_mc > 0 AND src.out_feed_mc > 0 THEN src.in_feed_mc - src.out_feed_mc ELSE tpr.waste_tba END,
    tpr.waste_tba_pct = CASE
        WHEN src.in_feed_mc > 0 AND src.out_feed_mc   > 0 THEN CAST(src.in_feed_mc - src.out_feed_mc AS FLOAT) / src.out_feed_mc
        WHEN src.in_feed_mc > 0 AND src.scanned_briks > 0 THEN CAST(src.in_feed_mc - src.out_feed_mc AS FLOAT) / src.scanned_briks
        ELSE tpr.waste_tba_pct
    END,
    tpr.waste_op = CASE WHEN src.in_feed_mc > 0 THEN src.scanned_briks - src.in_feed_mc ELSE tpr.waste_op END,
    tpr.efficiency_outfeed = CASE
        WHEN src.out_feed_mc  > 0 AND src.run_duration_minutes > 0 THEN src.out_feed_mc  / (src.run_duration_minutes * 400.0)
        WHEN src.out_feed_mc  = 0 AND src.scanned_briks > 0 AND src.run_duration_minutes > 0 THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE tpr.efficiency_outfeed
    END,
    tpr.efficiency_scanned = CASE
        WHEN src.scanned_briks > 0 AND src.run_duration_minutes > 0 THEN src.scanned_briks / (src.run_duration_minutes * 400.0)
        ELSE tpr.efficiency_scanned
    END,
    tpr.efficiency_lost_downtime = CASE
        WHEN src.out_feed_mc   > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.out_feed_mc, 0)
        WHEN src.scanned_briks > 0 THEN (src.total_downtime_seconds / 60.0) * 400 / NULLIF(src.scanned_briks, 0)
        ELSE tpr.efficiency_lost_downtime
    END,
    tpr.last_updated = GETUTCDATE()
FROM [analytics].[temp_production_run] tpr
JOIN src ON tpr.run_key = src.run_key;
*/


-- ============================================================
-- STEP 4 : TRIGGER — Late scan update (scanned_briks)
-- Fires on [Change paper brik] UPDATE when total_Var_Brik changes.
-- Allows operators to scan briks after production end_time is set.
-- Only scanned_briks, waste_op, efficiency_scanned update —
-- all other columns (in_feed_mc, run_duration_minutes, etc.) untouched.
-- ============================================================
CREATE OR ALTER TRIGGER [dbo].[TRI_UPDATE_SCANNED_BRIKS]
ON [dbo].[Change paper brik]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (
        SELECT 1 FROM inserted i
        JOIN deleted d ON i.ID = d.ID
        WHERE ISNULL(i.[total_Var_Brik], 0) <> ISNULL(d.[total_Var_Brik], 0)
    )
    RETURN;

    BEGIN TRANSACTION;
    BEGIN TRY

        UPDATE tpr
        SET
            tpr.scanned_briks      = ISNULL(i.[total_Var_Brik], 0),
            tpr.waste_op           = CASE
                                         WHEN tpr.in_feed_mc > 0
                                         THEN ISNULL(i.[total_Var_Brik], 0) - tpr.in_feed_mc
                                         ELSE tpr.waste_op
                                     END,
            tpr.efficiency_scanned = CASE
                                         WHEN ISNULL(i.[total_Var_Brik], 0) > 0
                                          AND tpr.run_duration_minutes > 0
                                         THEN ISNULL(i.[total_Var_Brik], 0) / (tpr.run_duration_minutes * 400.0)
                                         ELSE tpr.efficiency_scanned
                                     END,
            tpr.last_updated       = GETUTCDATE()
        FROM [analytics].[temp_production_run] tpr
        JOIN inserted i
            ON tpr.run_key = CONVERT(varchar, CAST(i.[Product Date] AS DATE), 112) + i.Machine
        WHERE ISNULL(i.[total_Var_Brik], 0) <> 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION;
        INSERT INTO t_log(txt) VALUES ('TRI_UPDATE_SCANNED_BRIKS:ERROR:' + ERROR_MESSAGE());
    END CATCH
END;
GO
