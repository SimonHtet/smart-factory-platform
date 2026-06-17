-- ============================================================
-- TRI_UPDATE_FILLER_V5.7
-- Database : DB_BUDIBASE
-- Table    : T_M_Filler_Process
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- WHAT CHANGED IN V5.7  (2026-06-17)
-- -------------------------------------------------------
-- REEL -> PALLET TRACEABILITY capture (recall support).
--
-- On each real End-Roll splice (non-cooldown branch) we now log the
-- live outfeed counter to [Reel_Splice_log]. The kth end-roll is the
-- boundary that ENDS reel k and STARTS reel k+1, so the counter at
-- that instant is the outfeed position where the reels change. Pallet
-- assignment is then pure counter math (count / pallet_size), no time.
--
-- Barcodes (Order/Reel) are scanned SEPARATELY by the operator and may
-- land seconds after the splice, so they are NOT captured here -- they
-- are joined back by reel index in the views:
--   analytics.v_reel_pallet_estimate  (id, product_id, supplier_barcode, outfeed)
--   analytics.v_reel_pallet_map        (id, product_id, supplier_barcode, pallet_no)
--
-- Counter only; non-cooldown branch only (the 30s cooldown = the same
-- physical splice double-firing -> must not create a second boundary).
--
-- DEPLOY ORDER:
--   1. CREATE TABLE [dbo].[Reel_Splice_log]      (run once, below)
--   2. DROP TRIGGER [dbo].[TRI_UPDATE_FILLER_V5_6]   -- avoid double-fire
--   3. Run this script  (creates TRI_UPDATE_FILLER_V5_7)
--   4. Create the two views (V_REEL_PALLET.sql)
--
-- Run ONCE before deploying V5.7:
--   CREATE TABLE [dbo].[Reel_Splice_log] (
--       ID              INT IDENTITY(1,1) PRIMARY KEY,
--       Machine         NVARCHAR(50),
--       Batch_ID        INT,            -- = [Change paper brik].ID
--       Splice_No       INT,            -- kth end-roll = boundary index k
--       Counter_Outfeed BIGINT,         -- outfeed at the splice instant
--       Splice_Time     DATETIME,
--       Log_Time        DATETIME
--   );
--
-- WHAT CHANGED IN V5.6  (2026-06-15)
-- -------------------------------------------------------
-- BIG DOWNTIME *duration* (time loss) tracking for A/B/D/M.
--
-- The mini-stoppage logic (11->8->9->10->11) only captures minor
-- stops. A big breakdown goes 11->8->7->12->13->14 (same as the CIP
-- end steps but WITHOUT Signal_Final_CIP) and the 8->7 transition
-- fires the existing ABORT, which rolls back the downtime event and
-- wipes Current_Downtime_Start -- so a big breakdown currently leaves
-- ZERO trace in Total_Downtime_Seconds. V5.6 captures it as a
-- separate duration in [Big_Downtime_log].
--
-- State machine (per batch, A/B/D/M only):
--   8/9/10 -> 7   ABORT  : stash BigDT_Pending_Start = Current_Downtime_Start
--                          BEFORE the rollback wipes it (the 11->8 stop time).
--   7 -> 12       OPEN   : if BigDT_Pending_Start set -> insert Big_Downtime_log
--                          row Status='OPEN', Start_Time = stop time; clear pending.
--   14 + CIP=1    VOID   : FCIP fired -> the run was ended on purpose, not a
--                          breakdown -> set the OPEN row Status='VOID' (no loss).
--   -> 11         CLOSE  : production resumed with no CIP -> Status='CLOSED',
--                          Duration_Seconds = DATEDIFF(s, Start_Time, now). LOSS.
--
-- Same CIP discriminator as the feed-segment fix: CIP signal => not a
-- loss (void); no CIP + resume => real big-downtime loss (count).
-- ASSUMPTION to verify: step 11 is reached only when production truly
-- resumes (the ICIP path 14 -> ... -> 11 must not pass through 11
-- early, or CLOSE would fire too soon). t_log tags _BDL:OPEN/VOID/CLOSE.
--
-- Run ONCE before deploying V5.6:
--   CREATE TABLE [dbo].[Big_Downtime_log] (
--       ID               INT IDENTITY(1,1) PRIMARY KEY,
--       Machine          NVARCHAR(50),
--       Batch_ID         INT,            -- = [Change paper brik].ID
--       Start_Time       DATETIME,
--       End_Time         DATETIME,
--       Duration_Seconds INT,
--       Status           NVARCHAR(10),   -- 'OPEN' / 'CLOSED' / 'VOID'
--       Log_Time         DATETIME
--   );
--   ALTER TABLE [Change paper brik] ADD BigDT_Pending_Start DATETIME NULL;
--
-- WHAT CHANGED IN V5.5  (2026-06-15)
-- -------------------------------------------------------
-- BIG DOWNTIME feed-counter accumulation for A/B/D/M.
--
-- Problem: on a real (big) breakdown the OPMS feed counter on
-- T_M_Filler_Process (counter_infeed / counter_outfeed) resets to
-- 0 and climbs again from scratch WITHOUT a CIP. One production
-- loop therefore looks like 130000 -> 0 -> 150000 when the true
-- total is 280000. The reset is the SAME batch continuing, not a
-- new run.
--
-- Fix: detect the reset (counter drops to 0) while the batch is
-- still open (End_time_CIP IS NULL = no FCIP yet = breakdown/ICIP,
-- not a clean finish) and log the PRE-reset value (deleted.*) as a
-- segment in [Feed_Segment_log]. The true batch total is then
-- SUM(segments) + final counter (computed in v_group_production_run).
--
-- Why End_time_CIP IS NULL is the whole discriminator:
--   * ICIP (breakdown clean) NEVER raises Signal_Final_CIP, so
--     End_time_CIP stays NULL  -> we accumulate.
--   * FCIP (loop finished) raises Signal_Final_CIP -> End_time_CIP
--     is stamped HOURS before the counter zeros for the next loop,
--     so a clean-finish reset is excluded by the guard.
--   * Mini breakdowns (11->8->9->10) never zero the counter, so
--     they never reach this section.
--
-- Vendor feed is pre-cleaned of jitter, so an exact 0 at this table
-- is always a real restart -> plain (was >0, now =0) detection.
--
-- Run ONCE before deploying V5.5:
--   CREATE TABLE [dbo].[Feed_Segment_log] (
--       ID            INT IDENTITY(1,1) PRIMARY KEY,
--       Machine       NVARCHAR(50),
--       Batch_ID      INT,            -- = [Change paper brik].ID
--       Segment_No    INT,            -- 1,2,3... within the batch
--       In_Feed_Seg   BIGINT,         -- pre-reset counter_infeed
--       Out_Feed_Seg  BIGINT,         -- pre-reset counter_outfeed
--       Reset_Time    DATETIME,
--       Ended_By      NVARCHAR(10),   -- 'BREAKDOWN'
--       Log_Time      DATETIME
--   );
--
-- ---- (history) -----------------------------------------
-- V5.4 : Step 13 end_time re-log for A/D/M while End_time_CIP IS NULL.
--        (patched 2026-06-11: B machines added to CIP group)
-- V5.3 : End_time_CIP = GETUTCDATE() (actual CIP time).
-- V5.2 : End Roll / Strip splice gated on Step 11.
-- V5.1 : Group M CIP online.
-- V5   : per-step downtime tracking (8/9/10 segments) + Down_log.
--
-- EVENTS HANDLED
-- -------------------------------------------------------
--   Step 10           -> Splicing loop started
--   Step 13           -> Splicing loop ended; counter snapshot
--   Step 14 + CIP=1   -> CIP end (Machine A/B/D/M); 1-hr cooldown
--   counter -> 0      -> [V5.5] BIG DOWNTIME segment (A/B/D/M)
--   End roll 0->1     -> Paper roll splice; 30-s cooldown
--   Strip signal 0->1 -> Strip splice; 30-s cooldown
--   Step 11 -> 8      -> Downtime START
--   Step 8  -> 9      -> SEGMENT
--   Step 9  -> 10     -> SEGMENT
--   Step 10 -> 11     -> END
--   Step 8/9/10 -> 7  -> ABORT
--
-- t_log event codes
-- -------------------------------------------------------
--   _BD:RESET      [V5.5] big-downtime counter reset logged
--   _DT:START/SEG/END/ABORT  minor stoppage events
--   _EndRoll / _ST           splice events
--   _S14                     CIP end event
-- ============================================================

USE [DB_BUDIBASE]
GO
CREATE OR ALTER TRIGGER [dbo].[TRI_UPDATE_FILLER_V5_7]
ON [dbo].[T_M_Filler_Process]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Machine               NVARCHAR(50)
    DECLARE @GID                   INT
    DECLARE @GID_ST                INT
    DECLARE @Splicing_Count        INT
    DECLARE @Splicing_Count_ST     INT
    DECLARE @LastSpliceTime        DATETIME
    DECLARE @LastStripTime         DATETIME
    DECLARE @ColumnName            NVARCHAR(50)
    DECLARE @SQL                   NVARCHAR(MAX)

    BEGIN TRANSACTION
    BEGIN TRY

        -- -------------------------------------------------------
        -- STEP 10 : Start Splicing Loop
        -- -------------------------------------------------------
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 10)
        BEGIN
            UPDATE cpb
            SET [Splicing time 1] = GETUTCDATE()
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE cpb.[Splicing time 1] IS NULL

            UPDATE cs
            SET [Splicing time 1] = GETUTCDATE()
            FROM [Change strip] cs
            JOIN (
                SELECT Machine, MAX(ID) MaxID FROM [Change strip] GROUP BY Machine
            ) x ON cs.Machine = x.Machine AND cs.ID = x.MaxID
            JOIN inserted i ON cs.Machine = i.Machine
            WHERE i.Machine_Step_No = 10
            AND cs.[Splicing time 1] IS NULL
        END

        -- -------------------------------------------------------
        -- STEP 13 : End Splicing Loop
        -- V5.4: A/D/M re-stamp end_time while End_time_CIP IS NULL.
        --        F/G/H/K unchanged — write once ([end time] IS NULL).
        -- V5.4 patch 2026-06-11: B machines added to CIP group (same as A/D/M).
        -- -------------------------------------------------------
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 13)
        BEGIN
            UPDATE cpb
            SET
                [end time]    = GETUTCDATE(),
                [In_Feed_MC]  = i.counter_infeed,
                [Out_Feed_MC] = i.counter_outfeed
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE cpb.[Splicing time 1] IS NOT NULL
              AND (
                    -- A/B/D/M: re-log while CIP has not fired
                    (
                        (cpb.Machine LIKE 'A%' OR cpb.Machine LIKE 'B%' OR cpb.Machine LIKE 'D%' OR cpb.Machine LIKE 'M%')
                        AND cpb.End_time_CIP IS NULL
                    )
                    OR
                    -- All others: write once only
                    (
                        cpb.Machine NOT LIKE 'A%'
                        AND cpb.Machine NOT LIKE 'B%'
                        AND cpb.Machine NOT LIKE 'D%'
                        AND cpb.Machine NOT LIKE 'M%'
                        AND cpb.[end time] IS NULL
                    )
                  )

            UPDATE cs
            SET [end time] = GETUTCDATE()
            FROM [Change strip] cs
            JOIN (
                SELECT Machine, MAX(ID) MaxID FROM [Change strip] GROUP BY Machine
            ) x ON cs.Machine = x.Machine AND cs.ID = x.MaxID
            JOIN inserted i ON cs.Machine = i.Machine
            WHERE i.Machine_Step_No = 13
            AND cs.[end time] IS NULL
            AND cs.[Splicing time 1] IS NOT NULL
        END

        -- -------------------------------------------------------
        -- STEP 14 : CIP End (Machine A, B, D, M)
        -- V5.3 fix: End_time_CIP = GETUTCDATE() (actual CIP time).
        -- @EndTime_S14 ([end time]) retained for logging only.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted
            WHERE Machine_Step_No = 14
            AND Signal_Final_CIP = 1
            AND (Machine LIKE 'A%' OR Machine LIKE 'B%' OR Machine LIKE 'D%' OR Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_S14   NVARCHAR(50)
            DECLARE @GID_S14           INT
            DECLARE @LastLogTime_S14   DATETIME
            DECLARE @Outfeed_S14       NVARCHAR(50)
            DECLARE @EndTime_S14       DATETIME

            DECLARE step14_cursor CURSOR FOR
                SELECT DISTINCT Machine
                FROM inserted
                WHERE Machine_Step_No = 14
                AND Signal_Final_CIP = 1
                AND (Machine LIKE 'A%' OR Machine LIKE 'B%' OR Machine LIKE 'D%' OR Machine LIKE 'M%')

            OPEN step14_cursor
            FETCH NEXT FROM step14_cursor INTO @cur_Machine_S14

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_S14 = MAX(ID)
                FROM [Change paper brik]
                WHERE Machine = @cur_Machine_S14
                AND [end time] IS NOT NULL
                AND End_time_CIP IS NULL

                IF @GID_S14 IS NOT NULL
                BEGIN
                    -- [V5.6] FCIP fired -> this batch ended on purpose, not a
                    -- breakdown. Void any OPEN big-downtime row so it is NOT
                    -- counted as a loss when step 11 later resumes.
                    UPDATE [Big_Downtime_log]
                    SET Status = 'VOID', Log_Time = GETUTCDATE()
                    WHERE Batch_ID = @GID_S14 AND Status = 'OPEN'

                    IF @@ROWCOUNT > 0
                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_S14 + '_BDL:VOID:ID=' + CAST(@GID_S14 AS NVARCHAR) + ':FCIP')

                    SELECT
                        @EndTime_S14 = [end time],
                        @Outfeed_S14 = CAST([Out_Feed_MC] AS NVARCHAR(50))
                    FROM [Change paper brik]
                    WHERE ID = @GID_S14

                    SELECT @LastLogTime_S14 = MAX(Log_Time)
                    FROM [endtime_log_test]
                    WHERE Machine = @cur_Machine_S14

                    IF @LastLogTime_S14 IS NULL
                    OR DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) >= 3600
                    OR DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) < 0
                    BEGIN
                        UPDATE [Change paper brik]
                        SET End_time_CIP = GETUTCDATE()
                        WHERE ID = @GID_S14

                        INSERT INTO [endtime_log_test] (Machine, Step, Signal_CIP, Outfeed, End_Time, Log_Time)
                        VALUES (
                            @cur_Machine_S14, 14, 1,
                            @Outfeed_S14, @EndTime_S14, GETUTCDATE()
                        )

                        INSERT INTO t_log(txt)
                        VALUES (
                            @cur_Machine_S14 + '_S14:CIP=1:ID=' + CAST(@GID_S14 AS NVARCHAR) +
                            ':Outfeed=' + ISNULL(@Outfeed_S14, 'NULL') +
                            ':BatchEndTime=' + CONVERT(NVARCHAR, @EndTime_S14, 121) +
                            ':CIPTime=' + CONVERT(NVARCHAR, GETUTCDATE(), 121) + '-LOGGED'
                        )
                    END
                    ELSE
                    BEGIN
                        INSERT INTO t_log(txt)
                        VALUES (
                            @cur_Machine_S14 + '_S14:CIP=1:COOLDOWN' +
                            ':diff=' + CAST(DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) AS NVARCHAR) + 's' +
                            ':remaining=' + CAST(3600 - DATEDIFF(SECOND, @LastLogTime_S14, SYSDATETIME()) AS NVARCHAR) + 's'
                        )
                    END
                END

                FETCH NEXT FROM step14_cursor INTO @cur_Machine_S14
            END

            CLOSE step14_cursor
            DEALLOCATE step14_cursor
        END

        -- -------------------------------------------------------
        -- [V5.5] BIG DOWNTIME : feed counter reset (A/B/D/M)
        -- Real restart = counter_infeed drops to 0 while the batch is
        -- still open (End_time_CIP IS NULL -> no FCIP yet ->
        -- breakdown / ICIP). deleted.counter_infeed holds the
        -- pre-reset value; log it as a segment so the true batch
        -- total = SUM(segments) + final counter (done in the view).
        -- Mini breakdowns (11->8->9->10) never zero the counter, so
        -- they never reach here. Clean finishes stamp End_time_CIP
        -- hours before the counter zeros, so they are excluded.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.counter_infeed > 0
            AND i.counter_infeed = 0
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_BD   NVARCHAR(50)
            DECLARE @GID_BD           INT
            DECLARE @PreInfeed_BD     BIGINT
            DECLARE @PreOutfeed_BD    BIGINT
            DECLARE @Seg_No_BD        INT

            DECLARE bd_cursor CURSOR FOR
                SELECT i.Machine, d.counter_infeed, d.counter_outfeed
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.counter_infeed > 0
                AND i.counter_infeed = 0
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN bd_cursor
            FETCH NEXT FROM bd_cursor INTO @cur_Machine_BD, @PreInfeed_BD, @PreOutfeed_BD

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_BD = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_BD
                AND End_time_CIP IS NULL

                IF @GID_BD IS NOT NULL
                BEGIN
                    SELECT @Seg_No_BD = ISNULL(MAX(Segment_No), 0) + 1
                    FROM [Feed_Segment_log]
                    WHERE Batch_ID = @GID_BD

                    INSERT INTO [Feed_Segment_log]
                        (Machine, Batch_ID, Segment_No, In_Feed_Seg, Out_Feed_Seg, Reset_Time, Ended_By, Log_Time)
                    VALUES
                        (@cur_Machine_BD, @GID_BD, @Seg_No_BD, @PreInfeed_BD, @PreOutfeed_BD,
                         GETUTCDATE(), 'BREAKDOWN', GETUTCDATE())

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_BD + '_BD:RESET:ID=' + CAST(@GID_BD AS NVARCHAR) +
                            ':seg=' + CAST(@Seg_No_BD AS NVARCHAR) +
                            ':infeed=' + CAST(@PreInfeed_BD AS NVARCHAR) +
                            ':outfeed=' + CAST(@PreOutfeed_BD AS NVARCHAR) + '-LOGGED')
                END

                FETCH NEXT FROM bd_cursor INTO @cur_Machine_BD, @PreInfeed_BD, @PreOutfeed_BD
            END

            CLOSE bd_cursor
            DEALLOCATE bd_cursor
        END

        -- -------------------------------------------------------
        -- End Roll Signal (0 -> 1)
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Paper_Splicing_End_roll_Signal_Brik = 1
            AND d.Paper_Splicing_End_roll_Signal_Brik = 0
        )
        BEGIN
            DECLARE @cur_Machine_ER NVARCHAR(50)
            DECLARE @Outfeed_ER     BIGINT          -- [V5.7] outfeed counter at splice instant

            DECLARE endroll_cursor CURSOR FOR
                SELECT i.Machine, i.counter_outfeed
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Paper_Splicing_End_roll_Signal_Brik = 1
                AND d.Paper_Splicing_End_roll_Signal_Brik = 0
                AND i.Machine_Step_No = 11

            OPEN endroll_cursor
            FETCH NEXT FROM endroll_cursor INTO @cur_Machine_ER, @Outfeed_ER

            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @cur_Machine_ER LIKE 'A%' OR @cur_Machine_ER LIKE 'B%' OR @cur_Machine_ER LIKE 'D%' OR @cur_Machine_ER LIKE 'M%'
                BEGIN
                    SELECT @GID = MAX(ID)
                    FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                    WHERE Machine = @cur_Machine_ER
                    AND End_time_CIP IS NULL
                END
                ELSE
                BEGIN
                    SELECT @GID = MAX(ID)
                    FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                    WHERE Machine = @cur_Machine_ER
                    AND [end time] IS NULL
                END

                SELECT
                    @Splicing_Count = ISNULL(Splicing_Count, 0) + 1,
                    @LastSpliceTime = Last_Splice_Time
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE ID = @GID

                IF @LastSpliceTime IS NULL
                OR DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) >= 30000
                OR DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) < -500
                BEGIN
                    UPDATE [Change paper brik]
                    SET Splicing_Count   = @Splicing_Count,
                        Last_Splice_Time = SYSDATETIME()
                    WHERE ID = @GID

                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count + 1 AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change paper brik] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID'
                    EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ER + '_EndRoll:' + CAST(@GID AS NVARCHAR) + ':' + CAST(@Splicing_Count AS NVARCHAR) + '-UPD')

                    -- [V5.7] reel boundary capture for pallet traceability.
                    -- @Splicing_Count = kth end-roll = boundary that ends reel k
                    -- and starts reel k+1. Counter only; barcode joined back in
                    -- the views (Order/Reel scanned separately by operator).
                    INSERT INTO [dbo].[Reel_Splice_log]
                        (Machine, Batch_ID, Splice_No, Counter_Outfeed, Splice_Time, Log_Time)
                    VALUES
                        (@cur_Machine_ER, @GID, @Splicing_Count, @Outfeed_ER, SYSDATETIME(), GETUTCDATE())
                END
                ELSE
                BEGIN
                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change paper brik] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID'
                    EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ER + '_EndRoll:COOLDOWN:count=' + CAST(@Splicing_Count - 1 AS NVARCHAR) +
                            ':diff=' + CAST(DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) AS NVARCHAR) + 'ms')
                END

                FETCH NEXT FROM endroll_cursor INTO @cur_Machine_ER, @Outfeed_ER
            END

            CLOSE endroll_cursor
            DEALLOCATE endroll_cursor
        END

        -- -------------------------------------------------------
        -- Strip Signal (0 -> 1)
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Strip_Splicing_Signal_Strip = 1
            AND d.Strip_Splicing_Signal_Strip = 0
        )
        BEGIN
            DECLARE @cur_Machine_ST NVARCHAR(50)

            DECLARE strip_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Strip_Splicing_Signal_Strip = 1
                AND d.Strip_Splicing_Signal_Strip = 0
                AND i.Machine_Step_No = 11

            OPEN strip_cursor
            FETCH NEXT FROM strip_cursor INTO @cur_Machine_ST

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_ST = MAX(ID)
                FROM [Change Strip] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_ST

                SELECT
                    @Splicing_Count_ST = ISNULL(Splicing_Count, 0) + 1,
                    @LastStripTime     = Last_Splice_Time
                FROM [Change Strip] WITH (UPDLOCK, HOLDLOCK)
                WHERE ID = @GID_ST

                IF @LastStripTime IS NULL
                OR DATEDIFF(MILLISECOND, @LastStripTime, SYSDATETIME()) >= 30000
                OR DATEDIFF(MILLISECOND, @LastStripTime, SYSDATETIME()) < -500
                BEGIN
                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count_ST + 1 AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change Strip] SET [' + @ColumnName + '] = GETUTCDATE(), Splicing_Count = @CNT, Last_Splice_Time = SYSDATETIME() WHERE ID = @ID AND [end time] IS NULL'
                    IF @Splicing_Count_ST = 1
                        SET @SQL = 'UPDATE [Change Strip] SET [' + @ColumnName + '] = GETUTCDATE(), Splicing_Count = @CNT, Last_Splice_Time = SYSDATETIME() WHERE ID = @ID AND [end time] IS NULL AND [Splicing time 1] IS NOT NULL'
                    EXEC sp_executesql @SQL, N'@ID INT, @CNT INT', @ID = @GID_ST, @CNT = @Splicing_Count_ST

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ST + '_ST:' + CAST(@GID_ST AS NVARCHAR) + ':' + CAST(@Splicing_Count_ST AS NVARCHAR) + '-UPD')
                END
                ELSE
                BEGIN
                    SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count_ST AS NVARCHAR)
                    SET @SQL = 'UPDATE [Change Strip] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID AND [end time] IS NULL'
                    EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID_ST
                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_ST + '_ST:COOLDOWN:count=' + CAST(@Splicing_Count_ST - 1 AS NVARCHAR) +
                            ':diff=' + CAST(DATEDIFF(MILLISECOND, @LastStripTime, SYSDATETIME()) AS NVARCHAR) + 'ms')
                END

                FETCH NEXT FROM strip_cursor INTO @cur_Machine_ST
            END

            CLOSE strip_cursor
            DEALLOCATE strip_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 11 -> 8 : Downtime Start
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 8
            AND d.Machine_Step_No = 11
        )
        BEGIN
            DECLARE @cur_Machine_DT   NVARCHAR(50)
            DECLARE @GID_DT           INT
            DECLARE @DT_Count         INT

            DECLARE dt_start_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 8
                AND d.Machine_Step_No = 11

            OPEN dt_start_cursor
            FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_DT = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DT
                AND [end time] IS NULL

                IF @GID_DT IS NOT NULL
                BEGIN
                    SELECT @DT_Count = ISNULL(Downtime_Count, 0) + 1
                    FROM [Change paper brik]
                    WHERE ID = @GID_DT

                    UPDATE [Change paper brik]
                    SET Downtime_Count         = @DT_Count,
                        Current_Downtime_Start = GETUTCDATE(),
                        Current_Event_Seconds  = 0
                    WHERE ID = @GID_DT

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_DT + '_DT:START:step=11->8:ID=' + CAST(@GID_DT AS NVARCHAR) + ':count=' + CAST(@DT_Count AS NVARCHAR))

                    INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                    VALUES (@cur_Machine_DT, 'START', 11, 8, @GID_DT, @DT_Count, NULL, NULL, GETUTCDATE())
                END

                FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT
            END

            CLOSE dt_start_cursor
            DEALLOCATE dt_start_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 8 -> 9 : Segment
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 8
            AND i.Machine_Step_No = 9
        )
        BEGIN
            DECLARE @cur_Machine_89   NVARCHAR(50)
            DECLARE @GID_89           INT
            DECLARE @DT_Start_89      DATETIME
            DECLARE @DT_Dur_89        INT
            DECLARE @DT_Count_89      INT
            DECLARE @DT_NewTotal_89   INT

            DECLARE dt_seg89_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 8
                AND i.Machine_Step_No = 9

            OPEN dt_seg89_cursor
            FETCH NEXT FROM dt_seg89_cursor INTO @cur_Machine_89

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_89 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_89
                AND [end time] IS NULL

                IF @GID_89 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_89 = Current_Downtime_Start,
                           @DT_Count_89 = Downtime_Count
                    FROM [Change paper brik]
                    WHERE ID = @GID_89

                    IF @DT_Start_89 IS NOT NULL
                    BEGIN
                        SET @DT_Dur_89      = DATEDIFF(SECOND, @DT_Start_89, GETUTCDATE())
                        SET @DT_NewTotal_89 = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_89), 0) + @DT_Dur_89

                        UPDATE [Change paper brik]
                        SET Total_Downtime_Seconds = @DT_NewTotal_89,
                            Current_Event_Seconds  = ISNULL(Current_Event_Seconds, 0) + @DT_Dur_89,
                            Current_Downtime_Start = GETUTCDATE()
                        WHERE ID = @GID_89

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_89 + '_DT:SEG:step=8->9:dur=' + CAST(@DT_Dur_89 AS NVARCHAR) + 's:total=' + CAST(@DT_NewTotal_89 AS NVARCHAR) + 's')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_89, 'SEGMENT', 8, 9, @GID_89, @DT_Count_89, @DT_Dur_89, @DT_NewTotal_89, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_seg89_cursor INTO @cur_Machine_89
            END

            CLOSE dt_seg89_cursor
            DEALLOCATE dt_seg89_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 9 -> 10 : Segment
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 9
            AND i.Machine_Step_No = 10
        )
        BEGIN
            DECLARE @cur_Machine_910   NVARCHAR(50)
            DECLARE @GID_910           INT
            DECLARE @DT_Start_910      DATETIME
            DECLARE @DT_Dur_910        INT
            DECLARE @DT_Count_910      INT
            DECLARE @DT_NewTotal_910   INT

            DECLARE dt_seg910_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 9
                AND i.Machine_Step_No = 10

            OPEN dt_seg910_cursor
            FETCH NEXT FROM dt_seg910_cursor INTO @cur_Machine_910

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_910 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_910
                AND [end time] IS NULL

                IF @GID_910 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_910 = Current_Downtime_Start,
                           @DT_Count_910 = Downtime_Count
                    FROM [Change paper brik]
                    WHERE ID = @GID_910

                    IF @DT_Start_910 IS NOT NULL
                    BEGIN
                        SET @DT_Dur_910      = DATEDIFF(SECOND, @DT_Start_910, GETUTCDATE())
                        SET @DT_NewTotal_910 = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_910), 0) + @DT_Dur_910

                        UPDATE [Change paper brik]
                        SET Total_Downtime_Seconds = @DT_NewTotal_910,
                            Current_Event_Seconds  = ISNULL(Current_Event_Seconds, 0) + @DT_Dur_910,
                            Current_Downtime_Start = GETUTCDATE()
                        WHERE ID = @GID_910

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_910 + '_DT:SEG:step=9->10:dur=' + CAST(@DT_Dur_910 AS NVARCHAR) + 's:total=' + CAST(@DT_NewTotal_910 AS NVARCHAR) + 's')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_910, 'SEGMENT', 9, 10, @GID_910, @DT_Count_910, @DT_Dur_910, @DT_NewTotal_910, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_seg910_cursor INTO @cur_Machine_910
            END

            CLOSE dt_seg910_cursor
            DEALLOCATE dt_seg910_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 10 -> 11 : Downtime End
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 10
            AND i.Machine_Step_No = 11
        )
        BEGIN
            DECLARE @cur_Machine_1011   NVARCHAR(50)
            DECLARE @GID_1011           INT
            DECLARE @DT_Start_1011      DATETIME
            DECLARE @DT_Dur_1011        INT
            DECLARE @DT_Count_1011      INT
            DECLARE @DT_NewTotal_1011   INT

            DECLARE dt_end1011_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 10
                AND i.Machine_Step_No = 11

            OPEN dt_end1011_cursor
            FETCH NEXT FROM dt_end1011_cursor INTO @cur_Machine_1011

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_1011 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_1011
                AND [end time] IS NULL

                IF @GID_1011 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_1011 = Current_Downtime_Start,
                           @DT_Count_1011 = Downtime_Count
                    FROM [Change paper brik]
                    WHERE ID = @GID_1011

                    IF @DT_Start_1011 IS NOT NULL
                    BEGIN
                        SET @DT_Dur_1011      = DATEDIFF(SECOND, @DT_Start_1011, GETUTCDATE())
                        SET @DT_NewTotal_1011 = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_1011), 0) + @DT_Dur_1011

                        UPDATE [Change paper brik]
                        SET Total_Downtime_Seconds = @DT_NewTotal_1011,
                            Current_Downtime_Start = NULL,
                            Current_Event_Seconds  = NULL
                        WHERE ID = @GID_1011

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_1011 + '_DT:END:step=10->11:dur=' + CAST(@DT_Dur_1011 AS NVARCHAR) + 's:total=' + CAST(@DT_NewTotal_1011 AS NVARCHAR) + 's')

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_1011, 'END', 10, 11, @GID_1011, @DT_Count_1011, @DT_Dur_1011, @DT_NewTotal_1011, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_end1011_cursor INTO @cur_Machine_1011
            END

            CLOSE dt_end1011_cursor
            DEALLOCATE dt_end1011_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 8/9/10 -> 7 : Abort
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 7
            AND d.Machine_Step_No IN (8, 9, 10)
        )
        BEGIN
            DECLARE @cur_Machine_DTA   NVARCHAR(50)
            DECLARE @GID_DTA           INT
            DECLARE @DT_CountAbort     INT
            DECLARE @DT_EventSecs      INT
            DECLARE @DT_Start_A        DATETIME
            DECLARE @DT_StepFrom       INT

            DECLARE dt_abort_cursor CURSOR FOR
                SELECT i.Machine, d.Machine_Step_No
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 7
                AND d.Machine_Step_No IN (8, 9, 10)

            OPEN dt_abort_cursor
            FETCH NEXT FROM dt_abort_cursor INTO @cur_Machine_DTA, @DT_StepFrom

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_DTA = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DTA
                AND [end time] IS NULL

                IF @GID_DTA IS NOT NULL
                BEGIN
                    SELECT @DT_Start_A    = Current_Downtime_Start,
                           @DT_CountAbort = Downtime_Count,
                           @DT_EventSecs  = ISNULL(Current_Event_Seconds, 0)
                    FROM [Change paper brik]
                    WHERE ID = @GID_DTA

                    IF @DT_Start_A IS NOT NULL
                    BEGIN
                        UPDATE [Change paper brik]
                        SET Downtime_Count         = ISNULL(Downtime_Count, 1) - 1,
                            Total_Downtime_Seconds = ISNULL(Total_Downtime_Seconds, 0) - @DT_EventSecs,
                            Current_Downtime_Start = NULL,
                            Current_Event_Seconds  = NULL,
                            -- [V5.6] stash the 11->8 stop time before it is wiped,
                            -- so a following 7->12 can open a big-downtime row.
                            BigDT_Pending_Start    = @DT_Start_A
                        WHERE ID = @GID_DTA

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_DTA + '_DT:ABORT:step=' + CAST(@DT_StepFrom AS NVARCHAR) +
                                '->7:rollback=' + CAST(@DT_EventSecs AS NVARCHAR) + 's:count=' + CAST(@DT_CountAbort AS NVARCHAR))

                        INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                        VALUES (@cur_Machine_DTA, 'ABORT', @DT_StepFrom, 7, @GID_DTA, @DT_CountAbort, NULL, NULL, GETUTCDATE())
                    END
                END

                FETCH NEXT FROM dt_abort_cursor INTO @cur_Machine_DTA, @DT_StepFrom
            END

            CLOSE dt_abort_cursor
            DEALLOCATE dt_abort_cursor
        END

        -- -------------------------------------------------------
        -- [V5.6] STEP 7 -> 12 : Big downtime OPEN (A/B/D/M)
        -- The 11->8->7->12 path = a real big breakdown entering the
        -- ICIP/end sequence. Open a Big_Downtime_log row using the
        -- stop time stashed at the abort. Stays OPEN until step 11
        -- resume (CLOSE) or FCIP (VOID).
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE d.Machine_Step_No = 7
            AND i.Machine_Step_No = 12
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_BO   NVARCHAR(50)
            DECLARE @GID_BO           INT
            DECLARE @PendStart_BO     DATETIME

            DECLARE bo_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 7
                AND i.Machine_Step_No = 12
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN bo_cursor
            FETCH NEXT FROM bo_cursor INTO @cur_Machine_BO

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_BO = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_BO
                AND End_time_CIP IS NULL

                IF @GID_BO IS NOT NULL
                BEGIN
                    SELECT @PendStart_BO = BigDT_Pending_Start
                    FROM [Change paper brik]
                    WHERE ID = @GID_BO

                    IF @PendStart_BO IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM [Big_Downtime_log] WHERE Batch_ID = @GID_BO AND Status = 'OPEN')
                    BEGIN
                        INSERT INTO [Big_Downtime_log]
                            (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Log_Time)
                        VALUES
                            (@cur_Machine_BO, @GID_BO, @PendStart_BO, NULL, NULL, 'OPEN', GETUTCDATE())

                        UPDATE [Change paper brik]
                        SET BigDT_Pending_Start = NULL
                        WHERE ID = @GID_BO

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_BO + '_BDL:OPEN:ID=' + CAST(@GID_BO AS NVARCHAR) +
                                ':start=' + CONVERT(NVARCHAR, @PendStart_BO, 121))
                    END
                END

                FETCH NEXT FROM bo_cursor INTO @cur_Machine_BO
            END

            CLOSE bo_cursor
            DEALLOCATE bo_cursor
        END

        -- -------------------------------------------------------
        -- [V5.6] -> STEP 11 : Big downtime CLOSE (resume, A/B/D/M)
        -- Production resumed and no FCIP voided the row -> real big
        -- downtime. Close the OPEN row and stamp the duration (loss).
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.Machine_Step_No = 11
            AND d.Machine_Step_No <> 11
            AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')
        )
        BEGIN
            DECLARE @cur_Machine_BC   NVARCHAR(50)
            DECLARE @GID_BC           INT
            DECLARE @BDL_ID_BC        INT
            DECLARE @BDL_Start_BC     DATETIME

            DECLARE bc_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 11
                AND d.Machine_Step_No <> 11
                AND (i.Machine LIKE 'A%' OR i.Machine LIKE 'B%' OR i.Machine LIKE 'D%' OR i.Machine LIKE 'M%')

            OPEN bc_cursor
            FETCH NEXT FROM bc_cursor INTO @cur_Machine_BC

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_BC = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_BC
                AND End_time_CIP IS NULL

                IF @GID_BC IS NOT NULL
                BEGIN
                    SELECT @BDL_ID_BC = MAX(ID)
                    FROM [Big_Downtime_log]
                    WHERE Batch_ID = @GID_BC AND Status = 'OPEN'

                    IF @BDL_ID_BC IS NOT NULL
                    BEGIN
                        SELECT @BDL_Start_BC = Start_Time
                        FROM [Big_Downtime_log]
                        WHERE ID = @BDL_ID_BC

                        UPDATE [Big_Downtime_log]
                        SET End_Time         = GETUTCDATE(),
                            Duration_Seconds = DATEDIFF(SECOND, @BDL_Start_BC, GETUTCDATE()),
                            Status           = 'CLOSED',
                            Log_Time         = GETUTCDATE()
                        WHERE ID = @BDL_ID_BC

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_BC + '_BDL:CLOSE:ID=' + CAST(@GID_BC AS NVARCHAR) +
                                ':dur=' + CAST(DATEDIFF(SECOND, @BDL_Start_BC, GETUTCDATE()) AS NVARCHAR) + 's')
                    END
                END

                FETCH NEXT FROM bc_cursor INTO @cur_Machine_BC
            END

            CLOSE bc_cursor
            DEALLOCATE bc_cursor
        END

    COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION
        INSERT INTO t_log(txt) VALUES (ERROR_MESSAGE())
    END CATCH

END

GO
