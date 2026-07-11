USE [DB_BUDIBASE]
GO
-- ============================================================
-- TRI_CPB_FEED_GUARD  (2026-07-11)
-- Table : [Change paper brik]   (AFTER UPDATE)
--
-- WHY
-- ----
-- 2026-07-03 incident: a Budibase operator-app full-row save wrote the
-- bound row back with the PLC-owned counter columns as NULL, wiping
-- In_Feed_MC / Out_Feed_MC after V5.8's Step-13 stamp (caught by
-- CPB_Write_Audit: APP_NAME()='node-mssql', HOST_NAME()='8e96675d4482').
-- The app is fixed, but this guard kills the CLASS of bug: once a
-- protected column holds data, no direct writer can regress it to 0 or
-- NULL. Regressed columns are silently restored from deleted.*; the
-- rest of the save goes through, so the operator app keeps working.
--
-- SCOPE
-- ----
-- Protected : In_Feed_MC, Out_Feed_MC, In_Feed_DE_MC, Sampling_Waste
-- Blocked   : non-NULL -> NULL, non-zero -> 0
-- Allowed   : NULL -> anything; non-zero -> other non-zero
-- Exempt    : writes arriving through another trigger
--             (TRIGGER_NESTLEVEL() > 1) = V5.8's PLC path, incl. the
--             legitimate A/B/D/M Step-13 re-logs to lower values.
--
-- NOTE: companion trigger, NOT an edit to TRI_UPDATE_FILLER_V5_8.
-- V5.8 fires on T_M_Filler_Process where counter resets to 0 are
-- LEGITIMATE (V5.5 breakdown segments); the overwrite hits
-- [Change paper brik] directly, so the block lives here on the
-- snapshot columns. Restores are logged to t_log as _FEEDGUARD, and
-- TRI_CPB_WRITE_AUDIT still records both the bad write and the fix.
--
-- Recursion: the corrective UPDATE only re-fires this trigger if the
-- DB option RECURSIVE_TRIGGERS is ON (default OFF), and even then the
-- nest-level check exits immediately. The audit trigger logging the
-- restore as a second row is expected.
--
-- TEST (leaves no trace either way):
--   BEGIN TRAN;
--       UPDATE [Change paper brik] SET In_Feed_MC = NULL, Out_Feed_MC = 0 WHERE ID = <ID>;
--       SELECT ID, In_Feed_MC, Out_Feed_MC FROM [Change paper brik] WHERE ID = <ID>;  -- originals survive
--       SELECT * FROM t_log WHERE txt LIKE '%[_]FEEDGUARD%';                          -- one RESTORED row
--   ROLLBACK;
-- ============================================================
CREATE OR ALTER TRIGGER [dbo].[TRI_CPB_FEED_GUARD]
ON [dbo].[Change paper brik]
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Trigger-originated writes (V5.8 Step-13 stamp, splice updates,
    -- downtime accumulators) are the authoritative PLC path: let through.
    IF TRIGGER_NESTLEVEL() > 1 RETURN;

    -- Fast exit: did any protected column regress to 0/NULL on any row?
    IF NOT EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON i.ID = d.ID
        WHERE (d.In_Feed_MC     IS NOT NULL AND (i.In_Feed_MC     IS NULL OR (i.In_Feed_MC     = 0 AND d.In_Feed_MC     <> 0)))
           OR (d.Out_Feed_MC    IS NOT NULL AND (i.Out_Feed_MC    IS NULL OR (i.Out_Feed_MC    = 0 AND d.Out_Feed_MC    <> 0)))
           OR (d.In_Feed_DE_MC  IS NOT NULL AND (i.In_Feed_DE_MC  IS NULL OR (i.In_Feed_DE_MC  = 0 AND d.In_Feed_DE_MC  <> 0)))
           OR (d.Sampling_Waste IS NOT NULL AND (i.Sampling_Waste IS NULL OR (i.Sampling_Waste = 0 AND d.Sampling_Waste <> 0)))
    ) RETURN;

    -- Restore ONLY the regressed columns from the pre-update values;
    -- every other column keeps what the writer just saved.
    UPDATE cpb
    SET In_Feed_MC     = CASE WHEN d.In_Feed_MC     IS NOT NULL AND (i.In_Feed_MC     IS NULL OR (i.In_Feed_MC     = 0 AND d.In_Feed_MC     <> 0)) THEN d.In_Feed_MC     ELSE i.In_Feed_MC     END,
        Out_Feed_MC    = CASE WHEN d.Out_Feed_MC    IS NOT NULL AND (i.Out_Feed_MC    IS NULL OR (i.Out_Feed_MC    = 0 AND d.Out_Feed_MC    <> 0)) THEN d.Out_Feed_MC    ELSE i.Out_Feed_MC    END,
        In_Feed_DE_MC  = CASE WHEN d.In_Feed_DE_MC  IS NOT NULL AND (i.In_Feed_DE_MC  IS NULL OR (i.In_Feed_DE_MC  = 0 AND d.In_Feed_DE_MC  <> 0)) THEN d.In_Feed_DE_MC  ELSE i.In_Feed_DE_MC  END,
        Sampling_Waste = CASE WHEN d.Sampling_Waste IS NOT NULL AND (i.Sampling_Waste IS NULL OR (i.Sampling_Waste = 0 AND d.Sampling_Waste <> 0)) THEN d.Sampling_Waste ELSE i.Sampling_Waste END
    FROM [Change paper brik] cpb
    JOIN inserted i ON cpb.ID = i.ID
    JOIN deleted  d ON d.ID  = i.ID
    WHERE (d.In_Feed_MC     IS NOT NULL AND (i.In_Feed_MC     IS NULL OR (i.In_Feed_MC     = 0 AND d.In_Feed_MC     <> 0)))
       OR (d.Out_Feed_MC    IS NOT NULL AND (i.Out_Feed_MC    IS NULL OR (i.Out_Feed_MC    = 0 AND d.Out_Feed_MC    <> 0)))
       OR (d.In_Feed_DE_MC  IS NOT NULL AND (i.In_Feed_DE_MC  IS NULL OR (i.In_Feed_DE_MC  = 0 AND d.In_Feed_DE_MC  <> 0)))
       OR (d.Sampling_Waste IS NOT NULL AND (i.Sampling_Waste IS NULL OR (i.Sampling_Waste = 0 AND d.Sampling_Waste <> 0)))

    -- Tripwire: fingerprint who tried it, per row, with what was restored.
    INSERT INTO t_log(txt)
    SELECT i.Machine + '_FEEDGUARD:ID=' + CAST(i.ID AS NVARCHAR(20))
         + CASE WHEN d.In_Feed_MC     IS NOT NULL AND (i.In_Feed_MC     IS NULL OR (i.In_Feed_MC     = 0 AND d.In_Feed_MC     <> 0))
                THEN ':IF='  + CAST(d.In_Feed_MC     AS NVARCHAR(20)) + '<-' + ISNULL(CAST(i.In_Feed_MC     AS NVARCHAR(20)), 'NULL') ELSE '' END
         + CASE WHEN d.Out_Feed_MC    IS NOT NULL AND (i.Out_Feed_MC    IS NULL OR (i.Out_Feed_MC    = 0 AND d.Out_Feed_MC    <> 0))
                THEN ':OF='  + CAST(d.Out_Feed_MC    AS NVARCHAR(20)) + '<-' + ISNULL(CAST(i.Out_Feed_MC    AS NVARCHAR(20)), 'NULL') ELSE '' END
         + CASE WHEN d.In_Feed_DE_MC  IS NOT NULL AND (i.In_Feed_DE_MC  IS NULL OR (i.In_Feed_DE_MC  = 0 AND d.In_Feed_DE_MC  <> 0))
                THEN ':DEIF=' + CAST(d.In_Feed_DE_MC AS NVARCHAR(20)) + '<-' + ISNULL(CAST(i.In_Feed_DE_MC  AS NVARCHAR(20)), 'NULL') ELSE '' END
         + CASE WHEN d.Sampling_Waste IS NOT NULL AND (i.Sampling_Waste IS NULL OR (i.Sampling_Waste = 0 AND d.Sampling_Waste <> 0))
                THEN ':SW='  + CAST(d.Sampling_Waste AS NVARCHAR(20)) + '<-' + ISNULL(CAST(i.Sampling_Waste AS NVARCHAR(20)), 'NULL') ELSE '' END
         + ':app='   + ISNULL(APP_NAME(), '?')
         + ':host='  + ISNULL(HOST_NAME(), '?')
         + ':login=' + ISNULL(SUSER_SNAME(), '?')
         + '-RESTORED'
    FROM inserted i
    JOIN deleted  d ON i.ID = d.ID
    WHERE (d.In_Feed_MC     IS NOT NULL AND (i.In_Feed_MC     IS NULL OR (i.In_Feed_MC     = 0 AND d.In_Feed_MC     <> 0)))
       OR (d.Out_Feed_MC    IS NOT NULL AND (i.Out_Feed_MC    IS NULL OR (i.Out_Feed_MC    = 0 AND d.Out_Feed_MC    <> 0)))
       OR (d.In_Feed_DE_MC  IS NOT NULL AND (i.In_Feed_DE_MC  IS NULL OR (i.In_Feed_DE_MC  = 0 AND d.In_Feed_DE_MC  <> 0)))
       OR (d.Sampling_Waste IS NOT NULL AND (i.Sampling_Waste IS NULL OR (i.Sampling_Waste = 0 AND d.Sampling_Waste <> 0)))
END
GO
