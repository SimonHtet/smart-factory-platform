-- ============================================================
-- COMMS_AUDIT_SETUP.sql                     (2026-07-02)
-- Database : DB_BUDIBASE
-- Purpose  : Evidence table for the OPMS -> T_M_Filler_Process
--            comms investigation (step-13 data loss, started
--            ~2026-06-30 on G3/G1/F3/M1).
--
-- The trigger-side logger (TRI_UPDATE_FILLER_V5.8_COMMS_AUDIT.sql)
-- writes three event types here:
--
--   HEARTBEAT : one row per machine per minute while OPMS is
--               writing. A GAP in heartbeats during production
--               = OPMS went silent (comms drop), timestamped.
--   NULLDATA  : a machine mid-production (step 8-13) arrived
--               with counter_infeed NULL = OPMS delivered the
--               step but an empty counter payload. Rate-limited
--               to 1/min/machine.
--   MULTIROW  : one UPDATE statement touched >1 machine row =
--               bundled write (suspected reconnect flush).
--               Detail lists every machine:step in the statement.
--
-- DEPLOY ORDER
--   1. Run this file (creates dbo.Comms_Audit + index).
--   2. Run TRI_UPDATE_FILLER_V5.8_COMMS_AUDIT.sql (CREATE OR ALTER).
--   3. Read evidence with COMMS_AUDIT_QUERIES.sql.
--
-- REMOVAL (when the investigation closes)
--   1. Re-run pipeline/sql/TRI_UPDATE_FILLER_V5.8.sql (canonical,
--      un-instrumented trigger).
--   2. Optionally:  DROP TABLE dbo.Comms_Audit;
--      (keep it if you want the evidence archived)
-- ============================================================

USE [DB_BUDIBASE]
GO

IF OBJECT_ID('dbo.Comms_Audit', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Comms_Audit (
        ID        INT IDENTITY(1,1) PRIMARY KEY,
        Event     NVARCHAR(20)  NOT NULL,   -- HEARTBEAT / NULLDATA / MULTIROW
        Machine   NVARCHAR(50)  NULL,       -- NULL for MULTIROW (machines in Detail)
        Step      INT           NULL,
        Infeed    BIGINT        NULL,
        Outfeed   BIGINT        NULL,
        Infeed_DE BIGINT        NULL,
        Detail    NVARCHAR(400) NULL,
        Log_Time  DATETIME      NOT NULL DEFAULT GETUTCDATE()
    );

    -- supports the 1/min rate-limit lookups inside the trigger
    CREATE NONCLUSTERED INDEX IX_CommsAudit_Machine_Event_Time
        ON dbo.Comms_Audit (Machine, Event, Log_Time DESC);
END
GO
