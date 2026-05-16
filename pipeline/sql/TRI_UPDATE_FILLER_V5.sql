-- ============================================================
-- TRI_UPDATE_FILLER_V5
-- Database : DB_BUDIBASE
-- Table    : T_M_Filler_Process
-- Deployed : 2026-05-16
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- WHAT CHANGED FROM V4
-- -------------------------------------------------------
-- V4 clocked the full stop as a single window (11->8 start,
-- 8->9 end).  V5 tracks each recovery step individually:
--
--   8  -> 9   SEGMENT: how long was machine stopped (step 8)
--   9  -> 10  SEGMENT: how long in restart sequence (step 9)
--   10 -> 11  END    : how long in warmup (step 10)
--
-- Total_Downtime_Seconds = sum of all three segments.
-- Downtime_Count increments only when machine reaches step 11.
-- Abort at any ->7 rolls back the entire current event using
-- Current_Event_Seconds as a per-event accumulator.
--
-- EVENTS HANDLED
-- -------------------------------------------------------
--   Step 10           -> Splicing loop started
--   Step 13           -> Splicing loop ended; counter snapshot
--   Step 14 + CIP=1   -> CIP end (Machine A/D only); 1-hr cooldown
--   End roll 0->1     -> Paper roll splice; 30-s cooldown
--   Strip signal 0->1 -> Strip splice; 30-s cooldown
--   Step 11 -> 8      -> Downtime START: stamp timer, init accumulator
--   Step 8  -> 9      -> SEGMENT: log step-8 dwell, reset timer
--   Step 9  -> 10     -> SEGMENT: log step-9 dwell, reset timer
--   Step 10 -> 11     -> END: log step-10 dwell, close event
--   Step 8/9/10 -> 7  -> ABORT: roll back event, decrement count
--
-- DOWNTIME COLUMNS on [Change paper brik]
-- -------------------------------------------------------
--   Downtime_Count          INT      -- stops completed this batch
--   Total_Downtime_Seconds  INT      -- cumulative seconds (all events)
--   Current_Downtime_Start  DATETIME -- per-step timer start (NULL = idle)
--   Current_Event_Seconds   INT      -- seconds added in this event (abort rollback)
--
-- Run once before deploying V5:
--   ALTER TABLE [Change paper brik] ADD Current_Event_Seconds INT NULL
--
-- Down_log upgrade (add columns if upgrading from V4):
--   ALTER TABLE [Down_log] ADD Step_From INT NULL
--   ALTER TABLE [Down_log] ADD Step_To   INT NULL
--
-- Full Down_log DDL (create fresh if not exists):
--   CREATE TABLE [dbo].[Down_log] (
--       ID                     INT IDENTITY(1,1) PRIMARY KEY,
--       Machine                NVARCHAR(50),
--       Event                  NVARCHAR(10),  -- 'START','SEGMENT','END','ABORT'
--       Step_From              INT,
--       Step_To                INT,
--       Batch_ID               INT,
--       Downtime_Count         INT,
--       Duration_Seconds       INT,           -- NULL on START/ABORT
--       Total_Downtime_Seconds INT,           -- NULL on START/ABORT
--       Log_Time               DATETIME
--   )
--
-- t_log event codes
-- -------------------------------------------------------
--   _DT:START      step 11->8  downtime event opened
--   _DT:SEG        step 8->9 or 9->10  segment logged
--   _DT:END        step 10->11  event closed
--   _DT:ABORT      step x->7   event rolled back
--   _EndRoll       paper roll splice
--   _ST            strip splice
--   _S14           CIP end event
-- ============================================================

USE [DB_BUDIBASE]
GO
CREATE OR ALTER TRIGGER [dbo].[TRI_UPDATE_FILLER_V5]
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
        -- STEP 14 : CIP End (Machine A and D only)
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
                WHERE Machine = @cur_Machine_S14
                AND [end time] IS NOT NULL

                IF @GID_S14 IS NOT NULL
                BEGIN
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
                        SET End_time_CIP = @EndTime_S14
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
                            ':EndTime=' + CONVERT(NVARCHAR, @EndTime_S14, 121) + '-LOGGED'
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
        -- Machine entered stop state.
        -- Stamp per-step timer, initialise event accumulator to 0.
        -- Downtime_Count is incremented here so Down_log START
        -- rows carry the correct stop number for this batch.
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
        -- Log how long machine was in step 8 (stopped).
        -- Add to Total and Current_Event_Seconds, reset timer to now.
        -- Guard: Current_Downtime_Start IS NOT NULL ensures this
        -- only fires inside a real downtime event (not at startup).
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
        -- [V5 NEW] STEP 9 -> 10 : Segment
        -- Log how long machine was in step 9 (restart sequence).
        -- Same pattern as 8->9: add duration, reset timer to now.
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
        -- [V5 NEW] STEP 10 -> 11 : Downtime End
        -- Machine is back in full production.
        -- Log the final segment (step 10 warmup duration), then
        -- close the event: clear timer and event accumulator.
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
        -- Machine abandoned recovery at any point before step 11.
        -- Roll back every second added during this event using
        -- Current_Event_Seconds, decrement Downtime_Count, clear timer.
        -- No-op if Current_Downtime_Start IS NULL (not in a stop).
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
                            Current_Event_Seconds  = NULL
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

    COMMIT TRANSACTION
    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION
        INSERT INTO t_log(txt) VALUES (ERROR_MESSAGE())
    END CATCH

END
