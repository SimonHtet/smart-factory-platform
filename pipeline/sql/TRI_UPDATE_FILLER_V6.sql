-- ============================================================
-- TRI_UPDATE_FILLER_V6
-- Database : DB_BUDIBASE
-- Table    : T_M_Filler_Process
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- WHAT CHANGED IN V6  (2026-07-13)
-- -------------------------------------------------------
-- 1) DE DOWNTIME SUBORDINATED TO THE FILLING STATE MACHINE.
--
--    V5.8 tracked DE as an independent edge stream. Two problems in
--    production: (a) the DE signal spikes 0-1-0-1 during filler stops,
--    inflating DE_Downtime_Count with junk micro-episodes; (b) DE and
--    filling downtime overlap incoherently, so tba_actual_downtime
--    (= total - DE) was not a clean attribution split.
--
--    V6 rule (stakeholder-approved): inside a filling downtime window
--    (11->8 ... ->11/7), DE stops being an event stream and becomes a
--    BLAME FLAG on the filling event:
--      * Any DE=1 seen during the window => the ENTIRE filling event
--        duration is credited to DE downtime as well. ONE episode,
--        same span as the filling event. Filling numbers UNCHANGED.
--      * All other DE edges inside the window are ignored (spikes
--        are swallowed silently -- no log rows, no counts).
--      * Filling END (10->11) settles the flag (see state table).
--      * Filling ABORT (8/9/10->7) discards the flag -- DE aborts
--        with filling, nothing counted (mirrors the filling rollback).
--    Outside a window (machine at 11, producing) the V5.8 standalone
--    edge logic is unchanged: 0->1 opens, 1->0 closes.
--
--    Handover ("unless the filling goes back to 11"): at filling END
--    the update row carries the live level in i.signal_DE_NotReady.
--    If DE is still down at that instant the episode is left/created
--    OPEN so the tail after resume keeps counting until the real
--    1->0 edge. Always exactly ONE episode per filling window.
--
--    STATE TABLE at filling END (10->11), flag set:
--      OPEN row exists (DE was down before the stop):
--        signal=0 now -> close it at window end (its 1->0 was
--                        swallowed); duration = its start -> now.
--        signal=1 now -> leave OPEN; real 1->0 closes it later.
--        (count stays 1 -- incremented at the original open)
--      No OPEN row (blip-only during the stop):
--        signal=0 now -> insert CLOSED row spanning the filling event
--                        (Start = now - full event duration); count++.
--        signal=1 now -> insert OPEN row starting at the filling event
--                        start; count++; real 1->0 closes it later.
--
--    Filling START (11->8) also reads i.signal_DE_NotReady: if DE is
--    already down when the filler stops (classic starvation sequence)
--    the flag is set immediately; an already-OPEN standalone episode
--    simply rides through the window and is settled at END (one
--    episode covering lead-in + window [+ tail]).
--
-- 2) STEP 13 CLOSES OPEN DE EPISODES (fix for the fallback over-count).
--    Any OPEN DE_Downtime_log row for a machine hitting Step 13 is
--    closed with duration truncated at [end time]; the truncated
--    duration is added to Total_DE_Downtime_Seconds and the batch's
--    Current_DE_Downtime_Start / DE_Flag_Current_Event are cleared.
--    Time after the production loop ends is no longer counted as DE
--    downtime (same philosophy as the mini-downtime ABORT). The 1->0
--    fallback close is kept as a safety net -- once Step 13 has closed
--    the row it finds nothing and is a no-op.
--
-- 3) LATENT STEP-FILTER PATCH (queued since 2026-07-03).
--    The Step-10 and Step-13 [Change paper brik] UPDATEs joined on
--    Machine only; a multi-machine PLC write containing machine X at
--    step 10/13 and machine Y at another step could stamp Y's batch.
--    Both UPDATEs now filter i.Machine_Step_No explicitly (the
--    [Change strip] UPDATEs always did).
--
-- KNOWN EDGE (accepted, edge-driven design): after an ABORT into the
-- big-downtime path (7->12), or after a Step-13 close-out, a DE line
-- that is STILL physically down is untracked until its next 0->1
-- edge. Same class of gap as the 2026-06-24 motor-start revision.
-- Big_Downtime_log is deliberately NOT DE-attributed in V6.
--
-- Run ONCE before deploying V6:
--   ALTER TABLE [Change paper brik] ADD DE_Flag_Current_Event BIT NULL;
--   ALTER TABLE [DE_Downtime_log]   ADD Source NVARCHAR(10) NULL;
--       -- 'SIGNAL'  = standalone edge episode (V5.8 style)
--       -- 'FILLING' = slaved to a filling downtime event
--
-- DEPLOY ORDER:
--   1. Run the two ALTER TABLEs above.
--   2. DROP TRIGGER [dbo].[TRI_UPDATE_FILLER_V5_8]   -- avoid double-fire
--   3. Run this script (creates TRI_UPDATE_FILLER_V6).
--   4. TRI_TEMP_PRODUCTION_RUN, TRI_CPB_FEED_GUARD: NO changes needed.
--      (FEED_GUARD exempts by TRIGGER_NESTLEVEL() > 1, so V6's writes
--      pass exactly as V5.8's did.)
--
-- ---- (history) -----------------------------------------
-- V5.8 : DE-line downtime tracking (signal_DE_NotReady edges),
--        tba_actual_downtime = total - de_downtime; motor-start gate
--        rev 06-24; Step-13 DE-infeed + Sampling_Waste snapshots
--        rev 06-29. DE edge semantics superseded by V6 rule above.
-- V5.7 : Reel -> pallet traceability ([Reel_Splice_log] on end-roll).
-- V5.6 : Big-downtime duration tracking ([Big_Downtime_log], A/B/D/M).
-- V5.5 : Big-downtime feed-counter segments ([Feed_Segment_log]).
-- V5.4 : Step 13 end_time re-log for A/D/M while End_time_CIP IS NULL
--        (B machines added 2026-06-11).
-- V5.3 : End_time_CIP = GETUTCDATE() (actual CIP time).
-- V5.2 : End Roll / Strip splice gated on Step 11.
-- V5.1 : Group M CIP online.
-- V5   : per-step downtime tracking (8/9/10 segments) + Down_log.
--
-- EVENTS HANDLED
-- -------------------------------------------------------
--   Step 10           -> Splicing loop started
--   Step 13           -> Splicing loop ended; counter snapshot;
--                        [V6] OPEN DE episodes closed at end time
--   Step 14 + CIP=1   -> CIP end (Machine A/B/D/M); 1-hr cooldown
--   counter -> 0      -> [V5.5] BIG DOWNTIME segment (A/B/D/M)
--   End roll 0->1     -> Paper roll splice; 30-s cooldown
--   Strip signal 0->1 -> Strip splice; 30-s cooldown
--   Step 11 -> 8      -> Downtime START; [V6] DE flag if DE already down
--   Step 8  -> 9      -> SEGMENT
--   Step 9  -> 10     -> SEGMENT
--   Step 10 -> 11     -> END; [V6] DE flag settlement
--   Step 8/9/10 -> 7  -> ABORT; [V6] DE flag discarded
--   DE 0->1           -> [V6] window active: set flag / else standalone OPEN
--   DE 1->0           -> [V6] window active: swallowed / else CLOSE
--
-- t_log event codes
-- -------------------------------------------------------
--   _BD:RESET                     [V5.5] big-downtime counter reset
--   _BDL:OPEN/VOID/CLOSE          [V5.6] big-downtime episodes
--   _DT:START/SEG/END/ABORT       minor stoppage events
--   _DE:START/END                 standalone DE episodes (V5.8 style)
--   _DE:FLAG                      [V6] DE seen down inside filling window
--   _DE:FILLCLOSE                 [V6] slaved episode closed at filling END
--   _DE:FILLOPEN                  [V6] slaved episode left/created OPEN at
--                                      filling END (DE still down)
--   _DE:S13CLOSE                  [V6] OPEN episode truncated at Step 13
--   _EndRoll / _ST                splice events
--   _S14                          CIP end event
-- ============================================================

USE [DB_BUDIBASE]
GO
CREATE OR ALTER TRIGGER [dbo].[TRI_UPDATE_FILLER_V6]
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
        -- [V6] step-filter patch: i.Machine_Step_No = 10 now applied
        -- to the cpb UPDATE (was Machine-join only).
        -- -------------------------------------------------------
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 10)
        BEGIN
            UPDATE cpb
            SET [Splicing time 1] = GETUTCDATE()
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE i.Machine_Step_No = 10
            AND cpb.[Splicing time 1] IS NULL

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
        -- V5.4: A/B/D/M re-stamp end_time while End_time_CIP IS NULL.
        --        F/G/H/K unchanged — write once ([end time] IS NULL).
        -- [V6] step-filter patch: i.Machine_Step_No = 13 now applied.
        -- [V6] OPEN DE episodes for the machine are closed here,
        --      truncated at [end time] (= now).
        -- -------------------------------------------------------
        IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 13)
        BEGIN
            UPDATE cpb
            SET
                [end time]       = GETUTCDATE(),
                [In_Feed_MC]     = i.counter_infeed,
                [Out_Feed_MC]    = i.counter_outfeed,
                [In_Feed_DE_MC]  = i.counter_infeed_DE,
                [Sampling_Waste] = i.counter_outfeed - i.counter_infeed_DE
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE i.Machine_Step_No = 13
              AND cpb.[Splicing time 1] IS NOT NULL
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

            -- [V6] Close any OPEN DE episode for the machines ending
            -- their loop: production is over, so DE downtime stops
            -- accruing HERE. Duration truncated at [end time] (= now).
            -- Also sweeps orphaned OPEN rows from older batches of the
            -- same machine (late, but better than never-closed).
            -- Idempotent across A/B/D/M step-13 re-fires: only OPEN
            -- rows are touched.
            DECLARE @DEClose_S13 TABLE (Machine NVARCHAR(50), Batch_ID INT, Dur INT);

            UPDATE del
            SET End_Time         = GETUTCDATE(),
                Duration_Seconds = DATEDIFF(SECOND, del.Start_Time, GETUTCDATE()),
                Status           = 'CLOSED',
                Log_Time         = GETUTCDATE()
            OUTPUT inserted.Machine, inserted.Batch_ID, inserted.Duration_Seconds
            INTO @DEClose_S13 (Machine, Batch_ID, Dur)
            FROM [DE_Downtime_log] del
            WHERE del.Status = 'OPEN'
              AND del.Machine IN (SELECT Machine FROM inserted WHERE Machine_Step_No = 13)

            UPDATE cpb
            SET Total_DE_Downtime_Seconds = ISNULL(cpb.Total_DE_Downtime_Seconds, 0) + c.Dur,
                Current_DE_Downtime_Start = NULL,
                DE_Flag_Current_Event     = NULL
            FROM [Change paper brik] cpb
            JOIN @DEClose_S13 c ON cpb.ID = c.Batch_ID

            INSERT INTO t_log(txt)
            SELECT c.Machine + '_DE:S13CLOSE:ID=' + CAST(c.Batch_ID AS NVARCHAR) +
                   ':dur=' + CAST(c.Dur AS NVARCHAR) + 's'
            FROM @DEClose_S13 c

            -- Flag hygiene: a flag with no OPEN row (blip-only event that
            -- was aborted into the end sequence) is dead at step 13.
            UPDATE cpb
            SET DE_Flag_Current_Event     = NULL,
                Current_DE_Downtime_Start = NULL
            FROM [Change paper brik] cpb
            JOIN inserted i ON cpb.Machine = i.Machine
            WHERE i.Machine_Step_No = 13
              AND (cpb.DE_Flag_Current_Event = 1 OR cpb.Current_DE_Downtime_Start IS NOT NULL)

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
        -- [V6] also reads the live DE level: if DE is already down
        -- when the filler stops (starvation sequence), set the blame
        -- flag now. An already-OPEN standalone DE episode is NOT
        -- closed — it rides through the window and is settled at the
        -- filling END (one episode: lead-in + window [+ tail]).
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
            DECLARE @DE_Sig_DT        INT             -- [V6] live DE level at stop

            DECLARE dt_start_cursor CURSOR FOR
                SELECT i.Machine, ISNULL(i.signal_DE_NotReady, 0)
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.Machine_Step_No = 8
                AND d.Machine_Step_No = 11

            OPEN dt_start_cursor
            FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT, @DE_Sig_DT

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
                        Current_Event_Seconds  = 0,
                        -- [V6] DE already down at the stop -> flag the event
                        DE_Flag_Current_Event  = CASE WHEN @DE_Sig_DT = 1 THEN 1
                                                      ELSE DE_Flag_Current_Event END
                    WHERE ID = @GID_DT

                    INSERT INTO t_log(txt)
                    VALUES (@cur_Machine_DT + '_DT:START:step=11->8:ID=' + CAST(@GID_DT AS NVARCHAR) + ':count=' + CAST(@DT_Count AS NVARCHAR))

                    IF @DE_Sig_DT = 1
                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_DT + '_DE:FLAG:atstart:ID=' + CAST(@GID_DT AS NVARCHAR))

                    INSERT INTO [Down_log] (Machine, Event, Step_From, Step_To, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                    VALUES (@cur_Machine_DT, 'START', 11, 8, @GID_DT, @DT_Count, NULL, NULL, GETUTCDATE())
                END

                FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT, @DE_Sig_DT
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
        -- [V6] DE flag settlement (see state table in header):
        --   flag set + OPEN DE row  + DE=0 now -> close row at window
        --                                          end (edge was swallowed)
        --   flag set + OPEN DE row  + DE=1 now -> leave OPEN (tail counts)
        --   flag set + no OPEN row  + DE=0 now -> insert CLOSED row
        --                                          spanning the filling event
        --   flag set + no OPEN row  + DE=1 now -> insert OPEN row starting
        --                                          at the filling event start
        -- Filling numbers are NOT touched by any of this.
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
            DECLARE @DE_Sig_1011        INT             -- [V6] live DE level at resume
            DECLARE @DT_EventSecs_1011  INT             -- [V6] prior segment legs
            DECLARE @DE_Flag_1011       BIT             -- [V6] blame flag
            DECLARE @FullDur_1011       INT             -- [V6] full filling event duration
            DECLARE @DE_OpenID_1011     INT
            DECLARE @DE_OpenStart_1011  DATETIME
            DECLARE @DE_CloseDur_1011   INT
            DECLARE @DE_EvStart_1011    DATETIME
            DECLARE @DE_Count_1011      INT

            DECLARE dt_end1011_cursor CURSOR FOR
                SELECT i.Machine, ISNULL(i.signal_DE_NotReady, 0)
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE d.Machine_Step_No = 10
                AND i.Machine_Step_No = 11

            OPEN dt_end1011_cursor
            FETCH NEXT FROM dt_end1011_cursor INTO @cur_Machine_1011, @DE_Sig_1011

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_1011 = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_1011
                AND [end time] IS NULL

                IF @GID_1011 IS NOT NULL
                BEGIN
                    SELECT @DT_Start_1011     = Current_Downtime_Start,
                           @DT_Count_1011     = Downtime_Count,
                           @DT_EventSecs_1011 = ISNULL(Current_Event_Seconds, 0),
                           @DE_Flag_1011      = ISNULL(DE_Flag_Current_Event, 0)
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

                        -- ------------------------------------------------
                        -- [V6] DE flag settlement for this filling event.
                        -- Full event duration = prior segment legs + last leg
                        -- (Total_Downtime_Seconds got exactly this amount).
                        -- ------------------------------------------------
                        IF @DE_Flag_1011 = 1
                        BEGIN
                            SET @FullDur_1011 = @DT_EventSecs_1011 + @DT_Dur_1011

                            SELECT @DE_OpenID_1011 = MAX(ID)
                            FROM [DE_Downtime_log]
                            WHERE Batch_ID = @GID_1011 AND Status = 'OPEN'

                            IF @DE_OpenID_1011 IS NOT NULL
                            BEGIN
                                -- Episode began BEFORE the stop (starvation lead-in).
                                IF @DE_Sig_1011 = 0
                                BEGIN
                                    -- Its 1->0 edge was swallowed inside the window:
                                    -- close at window end, per "take the filling downtime".
                                    SELECT @DE_OpenStart_1011 = Start_Time
                                    FROM [DE_Downtime_log]
                                    WHERE ID = @DE_OpenID_1011

                                    SET @DE_CloseDur_1011 = DATEDIFF(SECOND, @DE_OpenStart_1011, GETUTCDATE())

                                    UPDATE [DE_Downtime_log]
                                    SET End_Time         = GETUTCDATE(),
                                        Duration_Seconds = @DE_CloseDur_1011,
                                        Status           = 'CLOSED',
                                        Log_Time         = GETUTCDATE()
                                    WHERE ID = @DE_OpenID_1011

                                    UPDATE [Change paper brik]
                                    SET Total_DE_Downtime_Seconds = ISNULL(Total_DE_Downtime_Seconds, 0) + @DE_CloseDur_1011,
                                        Current_DE_Downtime_Start = NULL
                                    WHERE ID = @GID_1011

                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLCLOSE:ID=' + CAST(@GID_1011 AS NVARCHAR) +
                                            ':dur=' + CAST(@DE_CloseDur_1011 AS NVARCHAR) + 's:absorbed')
                                END
                                ELSE
                                BEGIN
                                    -- DE still down at resume: leave OPEN, the real
                                    -- 1->0 closes it (tail after resume keeps counting).
                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLOPEN:ID=' + CAST(@GID_1011 AS NVARCHAR) + ':carried')
                                END
                            END
                            ELSE
                            BEGIN
                                -- Blip-only inside the window: ONE episode spanning
                                -- the whole filling event (stakeholder rule: any DE
                                -- blip during a filler stop blames the full stop).
                                SELECT @DE_Count_1011 = ISNULL(DE_Downtime_Count, 0) + 1
                                FROM [Change paper brik]
                                WHERE ID = @GID_1011

                                SET @DE_EvStart_1011 = DATEADD(SECOND, -@FullDur_1011, GETUTCDATE())

                                IF @DE_Sig_1011 = 0
                                BEGIN
                                    INSERT INTO [DE_Downtime_log]
                                        (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Source, Log_Time)
                                    VALUES
                                        (@cur_Machine_1011, @GID_1011, @DE_EvStart_1011, GETUTCDATE(),
                                         @FullDur_1011, 'CLOSED', 'FILLING', GETUTCDATE())

                                    UPDATE [Change paper brik]
                                    SET DE_Downtime_Count         = @DE_Count_1011,
                                        Total_DE_Downtime_Seconds = ISNULL(Total_DE_Downtime_Seconds, 0) + @FullDur_1011
                                    WHERE ID = @GID_1011

                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLCLOSE:ID=' + CAST(@GID_1011 AS NVARCHAR) +
                                            ':dur=' + CAST(@FullDur_1011 AS NVARCHAR) + 's:count=' + CAST(@DE_Count_1011 AS NVARCHAR))
                                END
                                ELSE
                                BEGIN
                                    -- DE still down at resume: open from the filling
                                    -- event start so window + tail land in ONE episode.
                                    INSERT INTO [DE_Downtime_log]
                                        (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Source, Log_Time)
                                    VALUES
                                        (@cur_Machine_1011, @GID_1011, @DE_EvStart_1011, NULL,
                                         NULL, 'OPEN', 'FILLING', GETUTCDATE())

                                    UPDATE [Change paper brik]
                                    SET DE_Downtime_Count         = @DE_Count_1011,
                                        Current_DE_Downtime_Start = @DE_EvStart_1011
                                    WHERE ID = @GID_1011

                                    INSERT INTO t_log(txt)
                                    VALUES (@cur_Machine_1011 + '_DE:FILLOPEN:ID=' + CAST(@GID_1011 AS NVARCHAR) +
                                            ':count=' + CAST(@DE_Count_1011 AS NVARCHAR))
                                END
                            END

                            -- Flag consumed either way.
                            UPDATE [Change paper brik]
                            SET DE_Flag_Current_Event = NULL
                            WHERE ID = @GID_1011
                        END
                    END
                END

                FETCH NEXT FROM dt_end1011_cursor INTO @cur_Machine_1011, @DE_Sig_1011
            END

            CLOSE dt_end1011_cursor
            DEALLOCATE dt_end1011_cursor
        END

        -- -------------------------------------------------------
        -- [V5] STEP 8/9/10 -> 7 : Abort
        -- [V6] DE aborts with filling: the blame flag is discarded in
        -- the same rollback UPDATE — nothing counted, no DE row.
        -- (An OPEN standalone episode from BEFORE the window is left
        -- alone; the Step-13 close-out truncates it at [end time].)
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
                            BigDT_Pending_Start    = @DT_Start_A,
                            -- [V6] DE aborts with filling.
                            DE_Flag_Current_Event  = NULL
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

        -- -------------------------------------------------------
        -- [V6] DE LINE DOWN START : signal_DE_NotReady 0 -> 1
        -- Window active (Current_Downtime_Start set) -> set the blame
        -- flag only: no episode, no count (spikes collapse into one).
        -- Window inactive -> V5.8 standalone episode (unchanged),
        -- still gated on motor start ([Splicing time 1] IS NOT NULL,
        -- rev 2026-06-24) and one OPEN row per batch.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.signal_DE_NotReady = 1
            AND d.signal_DE_NotReady = 0
        )
        BEGIN
            DECLARE @cur_Machine_DE   NVARCHAR(50)
            DECLARE @GID_DE           INT
            DECLARE @DE_Count         INT
            DECLARE @DT_Active_DE     BIT             -- [V6] filling window active?
            DECLARE @Flag_DE          BIT             -- [V6] flag already set?

            DECLARE de_start_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.signal_DE_NotReady = 1
                AND d.signal_DE_NotReady = 0

            OPEN de_start_cursor
            FETCH NEXT FROM de_start_cursor INTO @cur_Machine_DE

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- [V5.8 rev 2026-06-24] Gate DE downtime on the filler having
                -- actually reached motor start (Step 10). Step 10 stamps
                -- [Splicing time 1], so [Splicing time 1] IS NOT NULL = "the
                -- production loop has started for this batch". A DE-not-ready
                -- signal during startup, BEFORE motor start, is not lost
                -- production time, so it must NOT open a DE episode.
                SELECT @GID_DE = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DE
                AND [end time] IS NULL
                AND [Splicing time 1] IS NOT NULL

                IF @GID_DE IS NOT NULL
                BEGIN
                    SELECT @DT_Active_DE = CASE WHEN Current_Downtime_Start IS NOT NULL THEN 1 ELSE 0 END,
                           @Flag_DE      = ISNULL(DE_Flag_Current_Event, 0)
                    FROM [Change paper brik]
                    WHERE ID = @GID_DE

                    IF @DT_Active_DE = 1
                    BEGIN
                        -- [V6] Inside a filling window: blame flag only.
                        -- Repeat spikes while already flagged are silent.
                        IF @Flag_DE = 0
                        BEGIN
                            UPDATE [Change paper brik]
                            SET DE_Flag_Current_Event = 1
                            WHERE ID = @GID_DE

                            INSERT INTO t_log(txt)
                            VALUES (@cur_Machine_DE + '_DE:FLAG:ID=' + CAST(@GID_DE AS NVARCHAR))
                        END
                    END
                    ELSE IF NOT EXISTS (SELECT 1 FROM [DE_Downtime_log] WHERE Batch_ID = @GID_DE AND Status = 'OPEN')
                    BEGIN
                        -- Standalone episode (filler producing, DE stalls).
                        SELECT @DE_Count = ISNULL(DE_Downtime_Count, 0) + 1
                        FROM [Change paper brik]
                        WHERE ID = @GID_DE

                        UPDATE [Change paper brik]
                        SET DE_Downtime_Count         = @DE_Count,
                            Current_DE_Downtime_Start = GETUTCDATE()
                        WHERE ID = @GID_DE

                        INSERT INTO [DE_Downtime_log]
                            (Machine, Batch_ID, Start_Time, End_Time, Duration_Seconds, Status, Source, Log_Time)
                        VALUES
                            (@cur_Machine_DE, @GID_DE, GETUTCDATE(), NULL, NULL, 'OPEN', 'SIGNAL', GETUTCDATE())

                        INSERT INTO t_log(txt)
                        VALUES (@cur_Machine_DE + '_DE:START:ID=' + CAST(@GID_DE AS NVARCHAR) +
                                ':count=' + CAST(@DE_Count AS NVARCHAR))
                    END
                END

                FETCH NEXT FROM de_start_cursor INTO @cur_Machine_DE
            END

            CLOSE de_start_cursor
            DEALLOCATE de_start_cursor
        END

        -- -------------------------------------------------------
        -- [V6] DE LINE DOWN END : signal_DE_NotReady 1 -> 0
        -- Window active -> edge swallowed (spike; the flag decides at
        -- filling END, an OPEN lead-in episode rides through).
        -- Window inactive -> V5.8 close (unchanged): stamp duration,
        -- add to Total_DE_Downtime_Seconds. Fallback to the OPEN row's
        -- batch kept as a safety net; usually a no-op now that Step 13
        -- closes OPEN episodes at batch end.
        -- -------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM inserted i
            JOIN deleted d ON i.Machine = d.Machine
            WHERE i.signal_DE_NotReady = 0
            AND d.signal_DE_NotReady = 1
        )
        BEGIN
            DECLARE @cur_Machine_DEE  NVARCHAR(50)
            DECLARE @GID_DEE          INT
            DECLARE @DE_ID_E          INT
            DECLARE @DE_Start_E       DATETIME
            DECLARE @DE_Dur_E         INT
            DECLARE @DT_Active_DEE    BIT             -- [V6] filling window active?

            DECLARE de_end_cursor CURSOR FOR
                SELECT i.Machine
                FROM inserted i
                JOIN deleted d ON i.Machine = d.Machine
                WHERE i.signal_DE_NotReady = 0
                AND d.signal_DE_NotReady = 1

            OPEN de_end_cursor
            FETCH NEXT FROM de_end_cursor INTO @cur_Machine_DEE

            WHILE @@FETCH_STATUS = 0
            BEGIN
                SELECT @GID_DEE = MAX(ID)
                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                WHERE Machine = @cur_Machine_DEE
                AND [end time] IS NULL

                SET @DT_Active_DEE = 0
                IF @GID_DEE IS NOT NULL
                    SELECT @DT_Active_DEE = CASE WHEN Current_Downtime_Start IS NOT NULL THEN 1 ELSE 0 END
                    FROM [Change paper brik]
                    WHERE ID = @GID_DEE

                -- [V6] Edge inside a filling window: swallowed (silent).
                IF @DT_Active_DEE = 0
                BEGIN
                    -- fall back to the OPEN episode's batch if the batch closed
                    IF @GID_DEE IS NULL
                        SELECT @GID_DEE = MAX(Batch_ID)
                        FROM [DE_Downtime_log]
                        WHERE Machine = @cur_Machine_DEE AND Status = 'OPEN'

                    IF @GID_DEE IS NOT NULL
                    BEGIN
                        SELECT @DE_ID_E = MAX(ID)
                        FROM [DE_Downtime_log]
                        WHERE Batch_ID = @GID_DEE AND Status = 'OPEN'

                        IF @DE_ID_E IS NOT NULL
                        BEGIN
                            SELECT @DE_Start_E = Start_Time
                            FROM [DE_Downtime_log]
                            WHERE ID = @DE_ID_E

                            SET @DE_Dur_E = DATEDIFF(SECOND, @DE_Start_E, GETUTCDATE())

                            UPDATE [DE_Downtime_log]
                            SET End_Time         = GETUTCDATE(),
                                Duration_Seconds = @DE_Dur_E,
                                Status           = 'CLOSED',
                                Log_Time         = GETUTCDATE()
                            WHERE ID = @DE_ID_E

                            UPDATE [Change paper brik]
                            SET Total_DE_Downtime_Seconds = ISNULL(Total_DE_Downtime_Seconds, 0) + @DE_Dur_E,
                                Current_DE_Downtime_Start = NULL
                            WHERE ID = @GID_DEE

                            INSERT INTO t_log(txt)
                            VALUES (@cur_Machine_DEE + '_DE:END:ID=' + CAST(@GID_DEE AS NVARCHAR) +
                                    ':dur=' + CAST(@DE_Dur_E AS NVARCHAR) + 's')
                        END
                    END
                END

                FETCH NEXT FROM de_end_cursor INTO @cur_Machine_DEE
            END

            CLOSE de_end_cursor
            DEALLOCATE de_end_cursor
        END

    COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION
        INSERT INTO t_log(txt) VALUES (ERROR_MESSAGE())
    END CATCH

END

GO
