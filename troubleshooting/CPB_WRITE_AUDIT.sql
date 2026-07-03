-- ============================================================
-- CPB_WRITE_AUDIT.sql                        (2026-07-03)
-- Database : DB_BUDIBASE
-- Table    : [dbo].[Change paper brik]
-- Purpose  : Catch the SECOND WRITER that NULLs the step-13
--            counters AFTER the trigger has stamped them.
--
-- WHY THIS EXISTS
-- -------------------------------------------------------
-- The comms audit (Comms_Audit) cleared the OPMS -> SQL path:
-- payloads arrived with counters present, no gaps, no NULLDATA.
-- The V5.8 Step-13 UPDATE is also cleared: it writes all five
-- columns ([end time], In_Feed_MC, Out_Feed_MC, In_Feed_DE_MC,
-- Sampling_Waste) atomically from ONE inserted row, and
-- Sampling_Waste = counter_outfeed - counter_infeed_DE.
--
-- The smoking gun: batch 260701-27We3-F4 ended with
-- Sampling_Waste = 921 but In/Out/DE counters all NULL. A single
-- firing cannot produce that -- SW non-NULL requires both source
-- counters non-NULL in the same statement, which would have
-- written them. So a good step-13 stamp landed first (incl.
-- SW=921), then a SEPARATE write NULLed the three counters
-- without touching SW. Nothing in the trigger pipeline writes
-- those counters without also writing SW -> the second writer is
-- EXTERNAL (prime suspect: a Budibase form/automation saving a
-- stale row it loaded while the batch was still open).
--
-- F4 is the only DE-wired machine, so it is the only machine
-- where SW is ever non-NULL and the overwrite leaves a trace.
-- On the other machines (F3/M1/G*) the identical overwrite just
-- looks like "all counters NULL".
--
-- WHAT THIS LOGS
-- -------------------------------------------------------
-- Every UPDATE that changes any of the five step-13 columns:
-- old -> new values, plus the CALLER's connection identity via
-- APP_NAME() / SUSER_SNAME() / HOST_NAME() (a trigger runs in the
-- writer's own session, so these report the writer, not the
-- trigger). Own TRY/CATCH so a diagnostics failure can never
-- block a write. Logs only on actual change -> a few rows per
-- machine per day, safe to leave running long-term.
--
-- ATTRIBUTION LIMIT: identifies the APPLICATION / LOGIN / HOST,
-- not the human. Budibase runs all users through one shared DB
-- login, so a Budibase hit says "Budibase at <time>" -- match
-- that timestamp against Budibase's own audit log (self-hosted:
-- Settings -> Audit Logs) to find the app/user/screen.
--
-- VERDICT QUERY (run after the next incident)
-- -------------------------------------------------------
--   SELECT * FROM dbo.CPB_Write_Audit
--   WHERE New_InFeed IS NULL AND Old_InFeed IS NOT NULL
--   ORDER BY Log_Time DESC;
--
-- A row showing Old_InFeed = <value> -> New_InFeed = NULL, with
-- App_Name / Login_Name / Host_Name of something other than the
-- OPMS writer, closes the case.
--
-- REMOVAL (when the case closes)
--   DROP TRIGGER dbo.TRI_CPB_WRITE_AUDIT;
--   -- keep or drop dbo.CPB_Write_Audit (keep = evidence archive)
-- ============================================================

USE [DB_BUDIBASE]
GO

-- ------------------------------------------------------------
-- STEP 1 : evidence table (run once)
-- ------------------------------------------------------------
IF OBJECT_ID('dbo.CPB_Write_Audit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CPB_Write_Audit (
        ID          INT IDENTITY(1,1) PRIMARY KEY,
        Batch_ID    INT,
        Machine     NVARCHAR(50),
        Old_InFeed  INT,      New_InFeed  INT,
        Old_OutFeed INT,      New_OutFeed INT,
        Old_DE      INT,      New_DE      INT,
        Old_SW      INT,      New_SW      INT,
        Old_EndTime DATETIME, New_EndTime DATETIME,
        App_Name    NVARCHAR(128),
        Login_Name  NVARCHAR(128),
        Host_Name   NVARCHAR(128),
        Log_Time    DATETIME NOT NULL DEFAULT GETUTCDATE()
    );

    CREATE NONCLUSTERED INDEX IX_CPBWriteAudit_Time
        ON dbo.CPB_Write_Audit (Log_Time DESC);
END
GO

-- ------------------------------------------------------------
-- STEP 2 : audit trigger (CREATE OR ALTER, safe to re-run)
-- ------------------------------------------------------------
CREATE OR ALTER TRIGGER dbo.TRI_CPB_WRITE_AUDIT
ON [dbo].[Change paper brik]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO dbo.CPB_Write_Audit
            (Batch_ID, Machine, Old_InFeed, New_InFeed, Old_OutFeed, New_OutFeed,
             Old_DE, New_DE, Old_SW, New_SW, Old_EndTime, New_EndTime,
             App_Name, Login_Name, Host_Name)
        SELECT d.ID, d.Machine,
               d.In_Feed_MC,     i.In_Feed_MC,
               d.Out_Feed_MC,    i.Out_Feed_MC,
               d.In_Feed_DE_MC,  i.In_Feed_DE_MC,
               d.Sampling_Waste, i.Sampling_Waste,
               d.[end time],     i.[end time],
               APP_NAME(), SUSER_SNAME(), HOST_NAME()
        FROM inserted i
        JOIN deleted d ON i.ID = d.ID
        WHERE ISNULL(i.In_Feed_MC,-1)     <> ISNULL(d.In_Feed_MC,-1)
           OR ISNULL(i.Out_Feed_MC,-1)    <> ISNULL(d.Out_Feed_MC,-1)
           OR ISNULL(i.In_Feed_DE_MC,-1)  <> ISNULL(d.In_Feed_DE_MC,-1)
           OR ISNULL(i.Sampling_Waste,-1) <> ISNULL(d.Sampling_Waste,-1)
           OR ISNULL(i.[end time],'1900-01-01') <> ISNULL(d.[end time],'1900-01-01');
    END TRY
    BEGIN CATCH
        INSERT INTO t_log(txt) VALUES ('CPB_AUDIT_ERR:' + ERROR_MESSAGE());
    END CATCH
END
GO
