-- Run in the database that holds dbo.tbl_sidel.
-- ============================================================
-- TRI_SIDEL_BASKET_RENUMBER  (2026-10-16)
-- Table   : [dbo].[tbl_sidel]   (AFTER INSERT, UPDATE, DELETE)
-- Trigger : trg_tbl_sidel_renumber
--
-- WHAT
-- ----
-- Keeps Baskets as a running 1..N count per (Product_id, Type),
-- ordered by id. Same Product_id + same Type -> keeps counting;
-- a different Type under the same Product_id starts again at 1.
--
-- CHANGE vs PREVIOUS (live, never committed until now)
-- ----
-- 1. PARTITION BY Product_id -> PARTITION BY Product_id, [Type]
-- 2. AFTER INSERT, DELETE   -> AFTER INSERT, UPDATE, DELETE
--    Editing a row's Product_id or Type in the app used to leave both
--    groups stale until the next insert/delete. Updates to any other
--    column return early.
-- 3. TRIGGER_NESTLEVEL guard: the trigger's own UPDATE of Baskets
--    must not re-enter it now that UPDATE is in the event list.
-- 4. Only rows whose number actually changes are written.
--
-- KNOWN BEHAVIOUR (unchanged)
-- ----
-- - DELETE closes the gap: deleting basket 2 of 1..5 renumbers 3,4,5
--   to 2,3,4.
-- - Order is by id (insert order), not by fill time.
--
-- PREVIOUS DEFINITION (for rollback)
-- ----
-- CREATE TRIGGER trg_tbl_sidel_renumber
-- ON [dbo].[tbl_sidel]
-- AFTER INSERT, DELETE
-- AS
-- BEGIN
--     SET NOCOUNT ON;
--     ;WITH cte AS (
--         SELECT Baskets,
--                ROW_NUMBER() OVER (PARTITION BY Product_id ORDER BY id) AS rn
--         FROM [dbo].[tbl_sidel] t
--         WHERE Product_id IN (
--             SELECT Product_id FROM inserted
--             UNION
--             SELECT Product_id FROM deleted
--         )
--     )
--     UPDATE cte SET Baskets = rn;
-- END
-- ============================================================

CREATE OR ALTER TRIGGER [dbo].[trg_tbl_sidel_renumber]
ON [dbo].[tbl_sidel]
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- stop the trigger re-firing on its own UPDATE below
    IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;

    -- on UPDATE, only renumber when Product_id or Type was changed
    IF EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)
       AND NOT (UPDATE(Product_id) OR UPDATE([Type]))
        RETURN;

    -- filter by Product_id only: renumbers every Type of a touched
    -- product (cheap) and stays correct when Type is NULL
    ;WITH cte AS (
        SELECT
            Baskets,
            ROW_NUMBER() OVER (PARTITION BY Product_id, [Type] ORDER BY id) AS rn
        FROM [dbo].[tbl_sidel]
        WHERE Product_id IN (
            SELECT Product_id FROM inserted
            UNION
            SELECT Product_id FROM deleted
        )
    )
    UPDATE cte SET Baskets = rn
    WHERE Baskets IS NULL OR Baskets <> rn;
END
GO

-- ============================================================
-- ONE-TIME BACKFILL: renumber existing rows under the new rule.
-- Run after the trigger above. Review the SELECT before committing.
-- ============================================================

-- preview
SELECT id, Product_id, [Type], Baskets,
       ROW_NUMBER() OVER (PARTITION BY Product_id, [Type] ORDER BY id) AS new_baskets
FROM dbo.tbl_sidel
ORDER BY Product_id, [Type], id;

-- apply
BEGIN TRAN;
;WITH cte AS (
    SELECT Baskets,
           ROW_NUMBER() OVER (PARTITION BY Product_id, [Type] ORDER BY id) AS rn
    FROM dbo.tbl_sidel
)
UPDATE cte SET Baskets = rn WHERE Baskets IS NULL OR Baskets <> rn;
-- check the row count, then:
-- COMMIT;   -- or ROLLBACK;
