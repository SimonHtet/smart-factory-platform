USE [DB_BUDIBASE]
GO
-- ============================================================
-- CLEAN UP BOGUS _BD:SEG0 SEGMENTS  (2026-08-27)
--
-- V6.2 committed a feed segment on ANY arrival at step 0, using a stash
-- that nothing cleared. A machine parked at rest produced a segment from
-- a counter value taken hours earlier. Step 13 folded it into
-- [Change paper brik], inflating In_Feed_MC / Out_Feed_MC.
--
-- Signature: [Change paper brik] wrong, temp_production_run RIGHT
-- (tpr reads the PLC counter directly and never sees the fold).
--
-- Run STEP 1 and 2 and eyeball before deleting anything.
-- ============================================================

-- ================= STEP 1 -- every POWERCUT segment V6.2 wrote =========
-- Ended_By='POWERCUT' is V6.2's tag; 'BREAKDOWN' is V5.5's counter-edge path.
SELECT  f.ID, f.Machine, f.Batch_ID, f.Segment_No,
        f.In_Feed_Seg, f.Out_Feed_Seg, f.Reset_Time, f.Ended_By,
        batch_date    = c.[Product Date],
        first_splice  = c.[Splicing time 1],
        batch_end     = c.[end time],
        batch_cip     = c.[End_time_CIP],
        -- a segment logged before the batch even started is definitely wrong
        verdict = CASE
                    WHEN c.[Splicing time 1] IS NULL              THEN 'BATCH NEVER STARTED'
                    WHEN f.Reset_Time < c.[Splicing time 1]       THEN 'SEGMENT PREDATES BATCH'
                    WHEN c.[end time] IS NOT NULL
                     AND f.Reset_Time > c.[end time]              THEN 'SEGMENT AFTER BATCH CLOSED'
                    ELSE 'review manually'
                  END
FROM    dbo.Feed_Segment_log f
JOIN    dbo.[Change paper brik] c ON c.ID = f.Batch_ID
WHERE   f.Ended_By = 'POWERCUT'
ORDER BY f.Log_Time DESC;
GO

-- ============ STEP 2 -- how much did each one inflate cpb? =============
SELECT  c.Machine, c.[Product Date], c.ID,
        cpb_infeed  = c.[In_Feed_MC],
        tpr_infeed  = t.in_feed_mc,
        segs_all    = ISNULL(s.tot_all, 0),
        segs_pcut   = ISNULL(s.tot_pcut, 0),
        inflation   = c.[In_Feed_MC] - t.in_feed_mc
FROM    dbo.[Change paper brik] c
JOIN    analytics.temp_production_run t
     ON t.run_key = CONVERT(varchar, c.[Product Date], 112) + c.Machine
OUTER APPLY (
    SELECT tot_all  = SUM(In_Feed_Seg),
           tot_pcut = SUM(CASE WHEN Ended_By = 'POWERCUT' THEN In_Feed_Seg ELSE 0 END)
    FROM   dbo.Feed_Segment_log WHERE Batch_ID = c.ID
) s
WHERE   EXISTS (SELECT 1 FROM dbo.Feed_Segment_log
                WHERE Batch_ID = c.ID AND Ended_By = 'POWERCUT')
ORDER BY ABS(c.[In_Feed_MC] - t.in_feed_mc) DESC;
GO

-- ================= STEP 3 -- DELETE the bogus segments ==================
-- Edit the ID list from STEP 1. Deliberately NOT a blanket
-- "DELETE WHERE Ended_By='POWERCUT'" -- a genuine power cut logged by V6.2
-- is a segment you WANT to keep.
/*
BEGIN TRAN;

    DECLARE @bad TABLE (ID INT);
    INSERT INTO @bad(ID) VALUES
        (0000), (0000);          -- <-- paste Feed_Segment_log.ID values here

    -- audit trail before removal
    INSERT INTO dbo.t_log(txt)
    SELECT f.Machine + '_BD:SEG0CLEANUP:fsl_id=' + CAST(f.ID AS NVARCHAR)
         + ':batch=' + CAST(f.Batch_ID AS NVARCHAR)
         + ':infeed=' + CAST(f.In_Feed_Seg AS NVARCHAR)
         + ':login=' + ISNULL(SUSER_SNAME(), '?') + '-DELETED'
    FROM dbo.Feed_Segment_log f JOIN @bad b ON b.ID = f.ID;

    DELETE f FROM dbo.Feed_Segment_log f JOIN @bad b ON b.ID = f.ID;

    SELECT deleted_rows = @@ROWCOUNT;

-- COMMIT;   -- uncomment once the count looks right
ROLLBACK;
*/
GO

-- ========== STEP 4 -- repair [Change paper brik] after deletion ==========
-- A/B/D/M batches still without CIP self-heal: Step 13 re-fires while
-- End_time_CIP IS NULL and recomputes counter + segments from scratch.
-- Batches already past CIP will NOT re-fire and need setting by hand.
-- tpr holds the PLC truth, so use it as the source.
/*
BEGIN TRAN;

    UPDATE c
    SET c.[In_Feed_MC]  = t.in_feed_mc  + ISNULL(s.tot, 0),
        c.[Out_Feed_MC] = t.out_feed_mc + ISNULL(s.tot_out, 0)
    OUTPUT deleted.ID, deleted.[In_Feed_MC], inserted.[In_Feed_MC]
    FROM   dbo.[Change paper brik] c
    JOIN   analytics.temp_production_run t
        ON t.run_key = CONVERT(varchar, c.[Product Date], 112) + c.Machine
    OUTER APPLY (
        SELECT tot = SUM(In_Feed_Seg), tot_out = SUM(Out_Feed_Seg)
        FROM dbo.Feed_Segment_log WHERE Batch_ID = c.ID
    ) s
    WHERE  c.[End_time_CIP] IS NOT NULL          -- won't self-heal
      AND  c.ID IN (0000, 0000);                 -- <-- affected batch IDs

-- COMMIT;
ROLLBACK;
*/
GO

-- ================= STEP 5 -- verify ====================================
SELECT  c.Machine, c.[Product Date], c.ID,
        cpb_infeed = c.[In_Feed_MC],
        tpr_plus_segs = t.in_feed_mc + ISNULL(s.tot, 0),
        delta = c.[In_Feed_MC] - (t.in_feed_mc + ISNULL(s.tot, 0))
FROM    dbo.[Change paper brik] c
JOIN    analytics.temp_production_run t
     ON t.run_key = CONVERT(varchar, c.[Product Date], 112) + c.Machine
OUTER APPLY (SELECT tot = SUM(In_Feed_Seg) FROM dbo.Feed_Segment_log
             WHERE Batch_ID = c.ID) s
WHERE   c.[Product Date] >= DATEADD(day, -5, GETDATE())
ORDER BY ABS(c.[In_Feed_MC] - (t.in_feed_mc + ISNULL(s.tot, 0))) DESC;
-- delta should be ~0 on every row
GO
