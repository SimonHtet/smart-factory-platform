-- ============================================================
-- DE_DOWNTIME_SETUP
-- Database : DB_BUDIBASE
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- One-time setup for DE-line downtime tracking (deploy BEFORE V5.8).
--
-- signal_DE_NotReady on T_M_Filler_Process: 0 = DE line OK, 1 = DE down.
-- We log each 0->1 ... 1->0 episode, accumulate the seconds onto the
-- batch row (same shape as Total_Downtime_Seconds), then surface it in
-- analytics.temp_production_run so TBA *actual* downtime can be isolated:
--
--     tba_actual_downtime = total_downtime - de_downtime   (floored at 0)
--
-- because a DE stall drags the TBA filler into downtime that is NOT the
-- filler's own fault.
-- ============================================================

USE [DB_BUDIBASE]
GO

-- ------------------------------------------------------------
-- 1. DE downtime episode log  (twin of Big_Downtime_log)
--    One row per DE-not-ready episode. OPEN at 0->1, CLOSED at 1->0.
-- ------------------------------------------------------------
IF OBJECT_ID('[dbo].[DE_Downtime_log]', 'U') IS NULL
CREATE TABLE [dbo].[DE_Downtime_log] (
    ID               INT IDENTITY(1,1) PRIMARY KEY,
    Machine          NVARCHAR(50),
    Batch_ID         INT,            -- = [Change paper brik].ID
    Start_Time       DATETIME,       -- signal 0 -> 1
    End_Time         DATETIME,       -- signal 1 -> 0
    Duration_Seconds INT,
    Status           NVARCHAR(10),   -- 'OPEN' / 'CLOSED'
    Log_Time         DATETIME
);
GO

-- ------------------------------------------------------------
-- 2. Accumulator + open-episode marker on the batch row
-- ------------------------------------------------------------
IF COL_LENGTH('[dbo].[Change paper brik]', 'Total_DE_Downtime_Seconds') IS NULL
    ALTER TABLE [dbo].[Change paper brik] ADD Total_DE_Downtime_Seconds INT NULL;
GO
IF COL_LENGTH('[dbo].[Change paper brik]', 'DE_Downtime_Count') IS NULL
    ALTER TABLE [dbo].[Change paper brik] ADD DE_Downtime_Count INT NULL;
GO
IF COL_LENGTH('[dbo].[Change paper brik]', 'Current_DE_Downtime_Start') IS NULL
    ALTER TABLE [dbo].[Change paper brik] ADD Current_DE_Downtime_Start DATETIME NULL;
GO

-- ------------------------------------------------------------
-- 3. Surface columns on the analytic table
-- ------------------------------------------------------------
IF COL_LENGTH('[analytics].[temp_production_run]', 'de_downtime_count') IS NULL
    ALTER TABLE [analytics].[temp_production_run] ADD de_downtime_count INT NULL;
GO
IF COL_LENGTH('[analytics].[temp_production_run]', 'de_downtime_seconds') IS NULL
    ALTER TABLE [analytics].[temp_production_run] ADD de_downtime_seconds INT NULL;
GO
IF COL_LENGTH('[analytics].[temp_production_run]', 'de_downtime_minutes') IS NULL
    ALTER TABLE [analytics].[temp_production_run] ADD de_downtime_minutes FLOAT NULL;
GO
IF COL_LENGTH('[analytics].[temp_production_run]', 'tba_actual_downtime_seconds') IS NULL
    ALTER TABLE [analytics].[temp_production_run] ADD tba_actual_downtime_seconds INT NULL;
GO
IF COL_LENGTH('[analytics].[temp_production_run]', 'tba_actual_downtime_minutes') IS NULL
    ALTER TABLE [analytics].[temp_production_run] ADD tba_actual_downtime_minutes FLOAT NULL;
GO
