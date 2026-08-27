USE [DB_BUDIBASE]
GO
-- ============================================================
-- WRONG-BATCH FEED SEGMENTS -- diagnose and repair   (2026-08-27)
--
-- Cause: `MAX(ID) WHERE End_time_CIP IS NULL` is not a current-batch test.
-- The next loop's row is created before this loop's CIP is stamped, so the
-- counter reset at the loop boundary is logged against the FUTURE batch.
--
-- Proven on M1, 2026-08-26 (local):
--   20:56  batch 6539 created (27 Aug run)
--   22:48  _BD:RESET infeed=458457 -> logged onto 6539
--   23:07  CIP finally stamped on 6526 (26 Aug run)  <- 19 min too late
--
-- A wrong-batch segment is identifiable without guessing: its Reset_Time
-- falls OUTSIDE the batch it is attached to.
-- ============================================================

-- ============ STEP 1 -- every segment that doesn't belong ==============
SELECT  f.ID AS fsl_id, f.Machine, f.Batch_ID, f.Segment_No, f.Ended_By,
        f.In_Feed_Seg, f.Out_Feed_Seg, f.Reset_Time,
        batch_date   = c.[Product Date],
        batch_start  = c.[Splicing time 1],
        batch_end    = c.[end time],
        batch_cip    = c.[End_time_CIP],
        verdict = CASE
                    WHEN c.[Splicing time 1] IS NULL            THEN 'BATCH NEVER STARTED'
                    WHEN f.Reset_Time < c.[Splicing time 1]     THEN 'SEGMENT PREDATES BATCH'
                    WHEN c.[end time] IS NOT NULL
                     AND f.Reset_Time > c.[end time]            THEN 'SEGMENT AFTER BATCH ENDED'
                    ELSE 'looks legitimate'
                  END,
        -- which batch SHOULD have owned it: the one running at Reset_Time
        should_be = (SELECT MAX(c2.ID) FROM dbo.[Change paper brik] c2
                     WHERE c2.Machine = f.Machine
                       AND c2.[Splicing time 1] IS NOT NULL
                       AND c2.[Splicing time 1] <= f.Reset_Time
                       AND (c2.[end time] IS NULL OR c2.[end time] >= f.Reset_Time))
FROM    dbo.Feed_Segment_log f
JOIN    dbo.[Change paper brik] c ON c.ID = f.Batch_ID
WHERE   f.Log_Time >= DATEADD(day, -30, GETUTCDATE())
ORDER BY f.Log_Time DESC;
GO

-- ====== STEP 2 -- inflation per batch (cpb vs the PLC truth in tpr) =====
SELECT  c.Machine, c.[Product Date], c.ID,
        cpb_infeed = c.[In_Feed_MC],
        tpr_infeed = t.in_feed_mc,
        segs       = ISNULL(s.tot, 0),
        inflation  = c.[In_Feed_MC] - t.in_feed_mc,
        seg_kinds  = s.kinds
FROM    dbo.[Change paper brik] c
JOIN    analytics.temp_production_run t
     ON t.run_key = CONVERT(varchar, c.[Product Date], 112) + c.Machine
OUTER APPLY (
    SELECT tot = SUM(In_Feed_Seg),
           kinds = STRING_AGG(Ended_By, ',')
    FROM   dbo.Feed_Segment_log WHERE Batch_ID = c.ID
) s
WHERE   c.[Product Date] >= DATEADD(day, -14, GETDATE())
  AND   ABS(c.[In_Feed_MC] - t.in_feed_mc) > 1000
ORDER BY ABS(c.[In_Feed_MC] - t.in_feed_mc) DESC;
GO

-- ==== STEP 3 -- DELETE the wrong-batch segments (edit the ID list) =====
-- Loop-boundary resets should not exist at all: the counter reset because
-- the loop ended, not because anything broke. Delete, don't re-point.
/*
BEGIN TRAN;

    DECLARE @bad TABLE (ID INT);
    INSERT INTO @bad(ID) VALUES
        (0000), (0000);        -- <-- fsl_id values from STEP 1

    INSERT INTO dbo.t_log(txt)
    SELECT f.Machine + '_BD:SEGFIX:fsl_id=' + CAST(f.ID AS NVARCHAR)
         + ':batch=' + CAST(f.Batch_ID AS NVARCHAR)
         + ':infeed=' + CAST(f.In_Feed_Seg AS NVARCHAR)
         + ':login=' + ISNULL(SUSER_SNAME(), '?') + '-DELETED'
    FROM dbo.Feed_Segment_log f JOIN @bad b ON b.ID = f.ID;

    DELETE f FROM dbo.Feed_Segment_log f JOIN @bad b ON b.ID = f.ID;
    SELECT deleted_rows = @@ROWCOUNT;

-- COMMIT;
ROLLBACK;
*/
GO

-- ========= STEP 4 -- repair cpb on batches that won't self-heal ========
-- A/B/D/M batches still without CIP self-heal: Step 13 re-fires while
-- End_time_CIP IS NULL and recomputes counter + segments from scratch.
-- Batches already past CIP need setting by hand. tpr holds the PLC truth.
/*
BEGIN TRAN;
    UPDATE c
    SET c.[In_Feed_MC]  = t.in_feed_mc  + ISNULL(s.tot_in, 0),
        c.[Out_Feed_MC] = t.out_feed_mc + ISNULL(s.tot_out, 0)
    OUTPUT deleted.ID, deleted.[In_Feed_MC] AS was, inserted.[In_Feed_MC] AS now
    FROM   dbo.[Change paper brik] c
    JOIN   analytics.temp_production_run t
        ON t.run_key = CONVERT(varchar, c.[Product Date], 112) + c.Machine
    OUTER APPLY (SELECT tot_in = SUM(In_Feed_Seg), tot_out = SUM(Out_Feed_Seg)
                 FROM dbo.Feed_Segment_log WHERE Batch_ID = c.ID) s
    WHERE  c.ID IN (0000, 0000);      -- <-- affected batch IDs
-- COMMIT;
ROLLBACK;
*/
GO

-- ===== STEP 5 -- exposure: how often is CIP later than the reset? ======
-- This is the condition that makes the bug possible. If it is common,
-- V6.4 is not optional.
SELECT  c.Machine, c.[Product Date], c.ID,
        batch_end = c.[end time], cip = c.[End_time_CIP],
        gap_minutes = DATEDIFF(minute, c.[end time], c.[End_time_CIP])
FROM    dbo.[Change paper brik] c
WHERE   c.[end time] IS NOT NULL
  AND   c.[End_time_CIP] IS NOT NULL
  AND   c.[Product Date] >= DATEADD(day, -14, GETDATE())
  AND   (c.Machine LIKE 'A%' OR c.Machine LIKE 'B%'
      OR c.Machine LIKE 'D%' OR c.Machine LIKE 'M%')
ORDER BY gap_minutes DESC;
GO

-- ===== STEP 6 -- the same wrong batch on the DOWNTIME side =============
-- Not fixed by V6.4 -- reported so the scale is known. A big-downtime row
-- whose Start_Time predates its batch is idle-between-loops recorded as a
-- breakdown (M1 2026-08-26: ID=6539, dur=18062s = 5.0 h).
SELECT  b.ID, b.Machine, b.Batch_ID, b.Start_Time, b.End_Time,
        b.Duration_Seconds, hours = b.Duration_Seconds / 3600.0, b.Status,
        batch_start = c.[Splicing time 1], batch_end = c.[end time]
FROM    dbo.Big_Downtime_log b
JOIN    dbo.[Change paper brik] c ON c.ID = b.Batch_ID
WHERE   b.Log_Time >= DATEADD(day, -14, GETUTCDATE())
  AND   (c.[Splicing time 1] IS NULL OR b.Start_Time < c.[Splicing time 1])
ORDER BY b.Duration_Seconds DESC;
GO
