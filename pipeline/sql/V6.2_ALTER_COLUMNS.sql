USE [DB_BUDIBASE]
GO
-- ============================================================
-- V6.2 prerequisite -- run ONCE, BEFORE TRI_UPDATE_FILLER_V6.2.sql
--
-- Two columns to stash the feed counters between "machine left
-- step 11" and "machine reached step 0". Sits alongside the
-- existing BigDT_Pending_Start, which V6.1 uses the same way for
-- the stop TIME.
--
-- Purely additive. No rebuild, no rewrite of the 761-column table,
-- no lock beyond a brief schema-modify. Nothing else reads these.
-- Safe to run during a production week.
--
-- Idempotent: re-running is a no-op.
-- ============================================================

IF COL_LENGTH('dbo.Change paper brik', 'BigDT_Pending_Infeed') IS NULL
    ALTER TABLE [dbo].[Change paper brik] ADD [BigDT_Pending_Infeed] BIGINT NULL;
GO

IF COL_LENGTH('dbo.Change paper brik', 'BigDT_Pending_Outfeed') IS NULL
    ALTER TABLE [dbo].[Change paper brik] ADD [BigDT_Pending_Outfeed] BIGINT NULL;
GO

-- Verify
SELECT  COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM    INFORMATION_SCHEMA.COLUMNS
WHERE   TABLE_NAME = 'Change paper brik'
  AND   COLUMN_NAME IN ('BigDT_Pending_Start', 'BigDT_Pending_Infeed', 'BigDT_Pending_Outfeed')
ORDER BY COLUMN_NAME;
-- expect 3 rows
GO
