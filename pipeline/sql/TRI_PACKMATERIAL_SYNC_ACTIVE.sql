-- Run in the database that holds dbo.[Packmaterial MotherData].
-- ============================================================
-- TRI_PACKMATERIAL_SYNC_ACTIVE  (2026-10-29)
-- Table   : [dbo].[Packmaterial MotherData]   (AFTER INSERT, UPDATE)
-- Trigger : trg_PackMaterial_SyncActive
--
-- WHAT
-- ----
-- Plant1 / Plant2 / Plant3 are per-plant activation flags. When one
-- changes, this keeps the derived columns in step:
--   Active      = 1 if any plant flag = 1, else 0
--   Plant       = text list of active plants: 1 | 1,3 | 1,2,3 | NULL
--   modified_at = SYSDATETIME()
-- Updates to any other column return early.
--
-- CHANGE vs PREVIOUS
-- ----
-- Replaces trg_Update_Plant, which wrote one plant by priority
-- (Plant1 > Plant2 > Plant3) on every update. Left in place, it turns
-- 1,3 back into 1, so it must not run alongside this trigger.
--
-- REQUIRES
-- ----
-- [Plant] NVARCHAR(10), [modified_at] DATETIME2(0), SQL Server 2017+
-- for CONCAT_WS.
-- ============================================================

DROP TRIGGER IF EXISTS [dbo].[trg_Update_Plant];
GO

CREATE OR ALTER TRIGGER [dbo].[trg_PackMaterial_SyncActive]
ON [dbo].[Packmaterial MotherData]
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (UPDATE([Plant1]) OR UPDATE([Plant2]) OR UPDATE([Plant3]))
        RETURN;

    UPDATE t
    SET t.[Active] = CASE WHEN i.[Plant1] = 1 OR i.[Plant2] = 1 OR i.[Plant3] = 1
                          THEN 1 ELSE 0 END,
        t.[Plant]  = NULLIF(CONCAT_WS(',',
                         CASE WHEN i.[Plant1] = 1 THEN '1' END,
                         CASE WHEN i.[Plant2] = 1 THEN '2' END,
                         CASE WHEN i.[Plant3] = 1 THEN '3' END), ''),
        t.[modified_at] = SYSDATETIME()
    FROM [dbo].[Packmaterial MotherData] t
    JOIN inserted i ON i.[id] = t.[id];
END;
GO
