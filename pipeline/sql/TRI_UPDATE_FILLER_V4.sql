-- ============================================================
-- TRI_UPDATE_FILLER_V4
-- Database : DB_BUDIBASE
-- Table    : T_M_Filler_Process  (PLC writes machine state here every cycle)
-- Deployed : 2026-05-13
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- WHAT THIS TRIGGER DOES
-- -------------------------------------------------------
-- Fires AFTER every UPDATE on T_M_Filler_Process.
-- The PLC updates rows in this table continuously as the
-- Tetra Pak filler machines change state.  The trigger
-- reads the transition (deleted = old row, inserted = new
-- row) and writes structured batch data into two tables:
--
--   [Change paper brik]  — one open row per active batch
--   [Change strip]       — strip-change log per batch
--
-- V4 adds downtime (minor stoppage) logging on top of V3.
-- "Downtime" here means any unplanned stop during production
-- (step 8).  Full breakdown = >30 min — that classification
-- is done at the reporting layer, not in the trigger.
--
-- EVENTS HANDLED
-- -------------------------------------------------------
--   Step 10           → Splicing loop started
--   Step 13           → Splicing loop ended; batch counter snapshot
--   Step 14 + CIP=1   → CIP end timestamp (Machine A/D only); 1-hr cooldown
--   End roll 0→1      → Paper roll splice counted; 30-s bounce cooldown
--   Strip signal 0→1  → Strip splice counted; 30-s bounce cooldown
--   Step 11 → 8 [NEW] → Machine stopped — start timing downtime
--   Step 8  → 9       → Machine recovered — accumulate downtime seconds
--   Step 8  → 7 [NEW] → Batch aborted — nullify all downtime data
--
-- HOW "OPEN BATCH" IS FOUND
-- -------------------------------------------------------
-- Every section needs to know which [Change paper brik]
-- row belongs to the current active batch for a machine.
-- Rule:
--   A / D machines  → End_time_CIP IS NULL  (CIP closes the row)
--   All others      → [end time] IS NULL     (Step 13 closes the row)
-- Exception: all three downtime sections use [end time] IS NULL
-- across the board (End_time_CIP logic not yet applied there).
--
-- DOWNTIME COLUMNS (added to [Change paper brik] in V4)
-- -------------------------------------------------------
--   Downtime_Count          INT  — number of stops (step 8 entries) this batch
--   Total_Downtime_Seconds  INT  — cumulative downtime in seconds
--   Current_Downtime_Start  DATETIME — when current stop started
--                                      (cleared to NULL on recovery)
--
-- Run these once before deploying if columns don't exist:
--   ALTER TABLE [Change paper brik] ADD Downtime_Count          INT      NULL
--   ALTER TABLE [Change paper brik] ADD Total_Downtime_Seconds  INT      NULL
--   ALTER TABLE [Change paper brik] ADD Current_Downtime_Start  DATETIME NULL
--
-- If renaming from V4-beta columns (Breakdown_Count, Current_Breakdown_Start):
--   EXEC sp_rename 'Change paper brik.Breakdown_Count',         'Downtime_Count',         'COLUMN'
--   EXEC sp_rename 'Change paper brik.Current_Breakdown_Start', 'Current_Downtime_Start', 'COLUMN'
--
-- DOWN_LOG TABLE (create once):
--   CREATE TABLE [dbo].[Down_log] (
--       ID                     INT IDENTITY(1,1) PRIMARY KEY,
--       Machine                NVARCHAR(50),
--       Event                  NVARCHAR(10),   -- 'START', 'END', 'ABORT'
--       Batch_ID               INT,            -- ID from [Change paper brik]
--       Downtime_Count         INT,            -- which stop number this batch
--       Duration_Seconds       INT,            -- NULL on START/ABORT, filled on END
--       Total_Downtime_Seconds INT,            -- running total after END, NULL on START/ABORT
--       Log_Time               DATETIME        -- GETUTCDATE()
--   )
--
-- COOLDOWN LOGIC
-- -------------------------------------------------------
-- Splice signals from the PLC can bounce (pulse 0→1
-- multiple times within milliseconds for one physical
-- event).  A 30-second cooldown window suppresses
-- duplicate counts.  CIP end uses a 1-hour cooldown
-- because Step 14 fires repeatedly while the machine
-- stays in that state.
--
-- AUDIT LOG
-- -------------------------------------------------------
-- Every write also inserts a row into t_log(txt) with a
-- structured key so you can trace exactly what fired:
--   _DT:START   downtime started (step 11→8)
--   _DT:END     downtime ended, duration in seconds logged
--   _DT:ABORT   batch aborted (step 8→7), downtime nullified
--   _EndRoll    paper roll splice
--   _ST         strip splice
--   _S14        CIP end event
-- ============================================================

USE [DB_BUDIBASE]
GO
CREATE OR ALTER TRIGGER [dbo].[TRI_UPDATE_FILLER_V4]
ON [dbo].[T_M_Filler_Process]
AFTER UPDATE
AS
BEGIN
        SET NOCOUNT ON;

        DECLARE @Machine                   NVARCHAR(50)
        DECLARE @GID                       INT
        DECLARE @GID_ST                    INT
        DECLARE @Splicing_Count            INT
        DECLARE @Splicing_Count_ST         INT
        DECLARE @LastSpliceTime            DATETIME
        DECLARE @LastStripTime             DATETIME
        DECLARE @ColumnName                NVARCHAR(50)
        DECLARE @SQL                       NVARCHAR(MAX)

        BEGIN TRANSACTION
        BEGIN TRY

                -- -------------------------------------------------------
                -- STEP 10 : Start Splicing Loop
                -- Marks [Splicing time 1] on the open batch row for this
                -- machine in both [Change paper brik] and [Change strip].
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
                -- Closes the batch: writes [end time] and takes a final
                -- snapshot of infeed/outfeed counters from the PLC row.
                -- End_time_CIP is NOT written here — Step 14 handles that
                -- separately for machines that go through CIP.
                -- -------------------------------------------------------
                IF EXISTS (SELECT 1 FROM inserted WHERE Machine_Step_No = 13)
                BEGIN
                        UPDATE cpb
                        SET
                                [end time]     = GETUTCDATE(),
                                [In_Feed_MC]   = i.counter_infeed,
                                [Out_Feed_MC]  = i.counter_outfeed
                        FROM [Change paper brik] cpb
                        JOIN inserted i ON cpb.Machine = i.Machine
                        WHERE cpb.[end time] IS NULL
                        AND cpb.[Splicing time 1] IS NOT NULL

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
                -- STEP 14 : CIP End  (Machine A and D only)
                -- Machine A and D run a CIP (clean-in-place) cycle after
                -- production.  Step 14 + Signal_Final_CIP=1 signals that
                -- the CIP is fully complete.  We write End_time_CIP to
                -- the [Change paper brik] row that already has [end time]
                -- set (batch closed at Step 13, CIP closes it further).
                -- 1-hour cooldown prevents duplicate writes while the
                -- machine stays in step 14.
                -- -------------------------------------------------------
                IF EXISTS (
                        SELECT 1 FROM inserted
                        WHERE Machine_Step_No = 14
                        AND Signal_Final_CIP = 1
                        AND (Machine LIKE 'A%' OR Machine LIKE 'D%')
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
                                AND (Machine LIKE 'A%' OR Machine LIKE 'D%')

                        OPEN step14_cursor
                        FETCH NEXT FROM step14_cursor INTO @cur_Machine_S14

                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                                SELECT @GID_S14 = MAX(ID)
                                FROM [Change paper brik]
                                WHERE Machine      = @cur_Machine_S14
                                AND [end time] IS NOT NULL

                                IF @GID_S14 IS NOT NULL
                                BEGIN
                                        SELECT
                                                @EndTime_S14  = [end time],
                                                @Outfeed_S14  = CAST([Out_Feed_MC] AS NVARCHAR(50))
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
                                                SET End_time_CIP = @EndTime_S14
                                                WHERE ID = @GID_S14

                                                INSERT INTO [endtime_log_test] (Machine, Step, Signal_CIP, Outfeed, End_Time, Log_Time)
                                                VALUES (
                                                        @cur_Machine_S14,
                                                        14,
                                                        1,
                                                        @Outfeed_S14,
                                                        @EndTime_S14,
                                                        GETUTCDATE()
                                                )

                                                INSERT INTO t_log (txt)
                                                VALUES (
                                                        @cur_Machine_S14 + '_S14:CIP=1:ID=' + CAST(@GID_S14 AS NVARCHAR) +
                                                        ':Outfeed=' + ISNULL(@Outfeed_S14, 'NULL') +
                                                        ':EndTime=' + CONVERT(NVARCHAR, @EndTime_S14, 121) + '-LOGGED'
                                                )
                                        END
                                        ELSE
                                        BEGIN
                                                INSERT INTO t_log (txt)
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
                -- End Roll Signal (0 -> 1)  — paper roll splice counter
                -- The PLC signal pulses 0→1 each time the machine splices
                -- a new paper roll.  We count these per batch into
                -- Splicing_Count and timestamp each one in dynamic columns
                -- ([Splicing time 2], [Splicing time 3], ...).
                -- 30-second cooldown suppresses PLC signal bounce.
                -- A/D machines: open row = End_time_CIP IS NULL
                -- Others      : open row = [end time] IS NULL
                -- -------------------------------------------------------
                IF EXISTS (
                        SELECT 1 FROM inserted i
                        JOIN deleted d ON i.Machine = d.Machine
                        WHERE i.Paper_Splicing_End_roll_Signal_Brik = 1
                        AND d.Paper_Splicing_End_roll_Signal_Brik = 0
                )
                BEGIN
                        DECLARE @cur_Machine_ER NVARCHAR(50)

                        DECLARE endroll_cursor CURSOR FOR
                                SELECT i.Machine
                                FROM inserted i
                                JOIN deleted d ON i.Machine = d.Machine
                                WHERE i.Paper_Splicing_End_roll_Signal_Brik = 1
                                AND d.Paper_Splicing_End_roll_Signal_Brik = 0

                        OPEN endroll_cursor
                        FETCH NEXT FROM endroll_cursor INTO @cur_Machine_ER

                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                                IF @cur_Machine_ER LIKE 'A%' OR @cur_Machine_ER LIKE 'D%'
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
                                        @Splicing_Count   = ISNULL(Splicing_Count, 0) + 1,
                                        @LastSpliceTime   = Last_Splice_Time
                                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                                WHERE ID = @GID

                                IF @LastSpliceTime IS NULL
                                OR DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) >= 30000
                                OR DATEDIFF(MILLISECOND, @LastSpliceTime, SYSDATETIME()) < -500
                                BEGIN
                                        UPDATE [Change paper brik]
                                        SET Splicing_Count     = @Splicing_Count,
                                            Last_Splice_Time   = SYSDATETIME()
                                        WHERE ID = @GID

                                        SET @ColumnName = 'Splicing time ' + CAST(@Splicing_Count + 1 AS NVARCHAR)
                                        SET @SQL = 'UPDATE [Change paper brik] SET [' + @ColumnName + '] = GETUTCDATE() WHERE ID = @ID'
                                        EXEC sp_executesql @SQL, N'@ID INT', @ID = @GID

                                        INSERT INTO t_log(txt)
                                        VALUES (@cur_Machine_ER + '_EndRoll:' + CAST(@GID AS NVARCHAR) + ':' + CAST(@Splicing_Count AS NVARCHAR) + '-UPD')
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

                                FETCH NEXT FROM endroll_cursor INTO @cur_Machine_ER
                        END

                        CLOSE endroll_cursor
                        DEALLOCATE endroll_cursor
                END

                -- -------------------------------------------------------
                -- Strip Signal (0 -> 1)  — strip splice counter
                -- Same bounce-cooldown logic as End Roll but targets
                -- [Change strip] table.  No End_time_CIP on this table —
                -- open row is always [end time] IS NULL for all machines.
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

                        OPEN strip_cursor
                        FETCH NEXT FROM strip_cursor INTO @cur_Machine_ST

                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                                SELECT @GID_ST = MAX(ID)
                                FROM [Change Strip] WITH (UPDLOCK, HOLDLOCK)
                                WHERE Machine = @cur_Machine_ST

                                SELECT
                                        @Splicing_Count_ST   = ISNULL(Splicing_Count, 0) + 1,
                                        @LastStripTime       = Last_Splice_Time
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
                -- [V4 NEW] STEP 11 -> 8 : Downtime Start
                -- Step 11 = machine running.  Step 8 = machine stopped
                -- (unplanned stop / minor stoppage).  On this transition:
                --   1. Increment Downtime_Count for the open batch
                --   2. Stamp Current_Downtime_Start = now
                -- The start time is kept in-row so the exact duration can
                -- be calculated when the machine recovers.
                -- Note: "breakdown" in company terms = >30 min downtime.
                -- That classification happens at the reporting layer.
                -- Open batch: [end time] IS NULL (all machines).
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
                                        SET Downtime_Count           = @DT_Count,
                                            Current_Downtime_Start   = GETUTCDATE()
                                        WHERE ID = @GID_DT

                                        INSERT INTO t_log(txt)
                                        VALUES (@cur_Machine_DT + '_DT:START:ID=' + CAST(@GID_DT AS NVARCHAR) + ':count=' + CAST(@DT_Count AS NVARCHAR))

                                        INSERT INTO [Down_log] (Machine, Event, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                                        VALUES (@cur_Machine_DT, 'START', @GID_DT, @DT_Count, NULL, NULL, GETUTCDATE())
                                END

                                FETCH NEXT FROM dt_start_cursor INTO @cur_Machine_DT
                        END

                        CLOSE dt_start_cursor
                        DEALLOCATE dt_start_cursor
                END

                -- -------------------------------------------------------
                -- [V4 NEW] STEP 8 -> 9 : Downtime End (recovered)
                -- Step 9 is the recovery step before returning to step 11.
                -- Only fires if Current_Downtime_Start IS NOT NULL (inner
                -- guard on line below), meaning a real 11→8→9 sequence
                -- occurred.  Startup 8→9 (no prior 11→8) is skipped because
                -- Current_Downtime_Start is NULL in that case.
                -- Duration = DATEDIFF(SECOND, Current_Downtime_Start, now)
                -- Added to Total_Downtime_Seconds (cumulative — multiple
                -- stops per batch all accumulate into one total).
                -- Current_Downtime_Start is cleared to NULL after use.
                -- -------------------------------------------------------
                IF EXISTS (
                        SELECT 1 FROM inserted i
                        JOIN deleted d ON i.Machine = d.Machine
                        WHERE d.Machine_Step_No = 8
                        AND i.Machine_Step_No = 9
                )
                BEGIN
                        DECLARE @cur_Machine_DTE   NVARCHAR(50)
                        DECLARE @GID_DTE           INT
                        DECLARE @DT_Start          DATETIME
                        DECLARE @DT_Duration       INT
                        DECLARE @DT_CountEnd       INT
                        DECLARE @DT_NewTotal       INT

                        DECLARE dt_end_cursor CURSOR FOR
                                SELECT i.Machine
                                FROM inserted i
                                JOIN deleted d ON i.Machine = d.Machine
                                WHERE d.Machine_Step_No = 8
                                AND i.Machine_Step_No = 9

                        OPEN dt_end_cursor
                        FETCH NEXT FROM dt_end_cursor INTO @cur_Machine_DTE

                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                                SELECT @GID_DTE = MAX(ID)
                                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                                WHERE Machine = @cur_Machine_DTE
                                AND [end time] IS NULL

                                IF @GID_DTE IS NOT NULL
                                BEGIN
                                        SELECT @DT_Start    = Current_Downtime_Start,
                                               @DT_CountEnd = Downtime_Count
                                        FROM [Change paper brik]
                                        WHERE ID = @GID_DTE

                                        IF @DT_Start IS NOT NULL
                                        BEGIN
                                                SET @DT_Duration = DATEDIFF(SECOND, @DT_Start, GETUTCDATE())
                                                SET @DT_NewTotal = ISNULL((SELECT Total_Downtime_Seconds FROM [Change paper brik] WHERE ID = @GID_DTE), 0) + @DT_Duration

                                                UPDATE [Change paper brik]
                                                SET Total_Downtime_Seconds  = @DT_NewTotal,
                                                    Current_Downtime_Start  = NULL
                                                WHERE ID = @GID_DTE

                                                INSERT INTO t_log(txt)
                                                VALUES (@cur_Machine_DTE + '_DT:END:ID=' + CAST(@GID_DTE AS NVARCHAR) + ':duration=' + CAST(@DT_Duration AS NVARCHAR) + 's')

                                                INSERT INTO [Down_log] (Machine, Event, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                                                VALUES (@cur_Machine_DTE, 'END', @GID_DTE, @DT_CountEnd, @DT_Duration, @DT_NewTotal, GETUTCDATE())
                                        END
                                END

                                FETCH NEXT FROM dt_end_cursor INTO @cur_Machine_DTE
                        END

                        CLOSE dt_end_cursor
                        DEALLOCATE dt_end_cursor
                END

                -- -------------------------------------------------------
                -- [V4 NEW] STEP 8 -> 7 : Batch Aborted (current stop only)
                -- Step 7 is pre-run — machine went 8→7 without recovering.
                -- Only undo the in-progress stop: decrement Downtime_Count
                -- by 1 and clear Current_Downtime_Start.
                -- Total_Downtime_Seconds from previous valid stops is kept.
                -- No-op if Current_Downtime_Start is NULL (no active stop).
                -- -------------------------------------------------------
                IF EXISTS (
                        SELECT 1 FROM inserted i
                        JOIN deleted d ON i.Machine = d.Machine
                        WHERE d.Machine_Step_No = 8
                        AND i.Machine_Step_No = 7
                )
                BEGIN
                        DECLARE @cur_Machine_DTA   NVARCHAR(50)
                        DECLARE @GID_DTA           INT
                        DECLARE @DT_CountAbort     INT

                        DECLARE dt_abort_cursor CURSOR FOR
                                SELECT i.Machine
                                FROM inserted i
                                JOIN deleted d ON i.Machine = d.Machine
                                WHERE d.Machine_Step_No = 8
                                AND i.Machine_Step_No = 7

                        OPEN dt_abort_cursor
                        FETCH NEXT FROM dt_abort_cursor INTO @cur_Machine_DTA

                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                                SELECT @GID_DTA = MAX(ID)
                                FROM [Change paper brik] WITH (UPDLOCK, HOLDLOCK)
                                WHERE Machine = @cur_Machine_DTA
                                AND [end time] IS NULL

                                IF @GID_DTA IS NOT NULL
                                BEGIN
                                        SELECT @DT_CountAbort = Downtime_Count,
                                               @DT_Start      = Current_Downtime_Start
                                        FROM [Change paper brik]
                                        WHERE ID = @GID_DTA

                                        IF @DT_Start IS NOT NULL
                                        BEGIN
                                                UPDATE [Change paper brik]
                                                SET Downtime_Count         = ISNULL(Downtime_Count, 1) - 1,
                                                    Current_Downtime_Start = NULL
                                                WHERE ID = @GID_DTA

                                                INSERT INTO t_log(txt)
                                                VALUES (@cur_Machine_DTA + '_DT:ABORT:ID=' + CAST(@GID_DTA AS NVARCHAR) + ':step8->7:count=' + CAST(@DT_CountAbort AS NVARCHAR) + ':decremented')

                                                INSERT INTO [Down_log] (Machine, Event, Batch_ID, Downtime_Count, Duration_Seconds, Total_Downtime_Seconds, Log_Time)
                                                VALUES (@cur_Machine_DTA, 'ABORT', @GID_DTA, @DT_CountAbort, NULL, NULL, GETUTCDATE())
                                        END
                                END

                                FETCH NEXT FROM dt_abort_cursor INTO @cur_Machine_DTA
                        END

                        CLOSE dt_abort_cursor
                        DEALLOCATE dt_abort_cursor
                END

        COMMIT TRANSACTION
        END TRY
        BEGIN CATCH
                ROLLBACK TRANSACTION
                INSERT INTO t_log(txt) VALUES (ERROR_MESSAGE())
        END CATCH

END
