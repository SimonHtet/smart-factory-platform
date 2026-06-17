-- ============================================================
-- REEL -> PALLET TRACEABILITY VIEWS  (2026-06-17, outfeed-at-splice)
-- Database : DB_BUDIBASE
-- Pairs with: TRI_UPDATE_FILLER_V5.7 (captures [dbo].[Reel_Splice_log])
-- Author   : Simon (DairyPlus Manufacturing Systems Engineer)
--
-- PURPOSE
-- -------------------------------------------------------
-- Reverse traceability for recall. A finished pallet is found bad ->
-- trace back to the supplier barcode (reel) that fed it, and flag every
-- pallet that reel touched.
--
-- METHOD = OUTFEED COUNTER AT EACH SPLICE  (accurate, no estimate)
-- -------------------------------------------------------
-- V5.7 captures the live outfeed counter at every real reel change into
-- [Reel_Splice_log] (Splice_No = kth end-roll). The outfeed counter is
-- ALREADY cumulative, so the captured value IS the brik position on the
-- run -- just divide by the pallet size:
--      pallet boundary = outfeed_at_splice / 4800
-- This uses ACTUAL machine output, so it excludes waste and does NOT depend
-- on the supplier's declared [Var count] (which varies 17000/17500/18000 and
-- includes waste). Replaces the earlier [Var count] estimate (git history,
-- commit 0355236) -- that one was the retroactive stopgap for a batch already
-- running; this is the real method.
--
-- Reel seq N occupies outfeed [ splice(N-1) .. splice(N) ):
--   reel 1   : 0                  -> outfeed @ splice 1
--   reel N   : outfeed @ splice N-1 -> outfeed @ splice N
--   running  : outfeed @ last splice -> live T_M_Filler_Process counter
--
-- BIG-DOWNTIME RESET CORRECTION (V5.5): a breakdown zeroes the raw counter
-- (130000 -> 0 -> 150000), so the true cumulative at any point =
--   raw counter + SUM([Feed_Segment_log].Out_Feed_Seg logged before that point).
-- Both the splice boundaries and the live counter are corrected this way.
-- Time compare uses UTC columns on both sides (Reel_Splice_log.Log_Time and
-- Feed_Segment_log.Reset_Time are both GETUTCDATE()) -- do NOT use Splice_Time
-- (SYSDATETIME/local) against Reset_Time (UTC).
--
-- DEDUP: PLC repeats the same (Order,Reel) across consecutive columns while a
-- reel runs -> LAG-dedup consecutive identical pairs, ROW_NUMBER survivors into
-- seq = true reel order. supplier_barcode = Order + Reel via decimal(38,0) cast
-- (kills float scientific notation). seq must line up with Splice_No: #distinct
-- reels should = #splices + 1 (reel 1 has no preceding splice; running reel has
-- no closing splice). Validate with the check at the bottom.
--
-- PALLET MATH (FLOOR/CEILING so a reel straddling a pallet boundary flags that
-- pallet for BOTH reels -> recall-safe).
--
-- SCOPE (v1): Group M only (Machine LIKE 'M%'), [Product Date] >= 2026-06-16,
--             currently running batch (End_time_CIP IS NULL).
-- NOTE: FORWARD-ONLY -- only splices captured AFTER V5.7 went live appear, so
--       this populates fully from the NEXT clean batch (start to finish). The
--       batch already running shows little until then.
-- pallet_no is the continuous count per batch; the real warehouse pallet number
-- (and per-machine separation) is the NEXT step, not integrated here yet.
-- ============================================================

USE [DB_BUDIBASE]
GO

-- ------------------------------------------------------------
-- VIEW A : v_reel_pallet_estimate
-- One row per reel in each running M batch.
-- Columns: id, product_id, supplier_barcode, outfeed
-- (outfeed = corrected cumulative outfeed counter at the end of that reel.)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW [analytics].[v_reel_pallet_estimate] AS
WITH splice AS (
    SELECT rsl.Batch_ID, rsl.Splice_No AS k,
           rsl.Counter_Outfeed
         + ISNULL((SELECT SUM(fs.Out_Feed_Seg) FROM [dbo].[Feed_Segment_log] fs
                   WHERE fs.Batch_ID = rsl.Batch_ID
                     AND fs.Reset_Time < rsl.Log_Time), 0) AS c   -- reset-corrected (UTC compare)
    FROM [dbo].[Reel_Splice_log] rsl
),
live AS (
    SELECT cpb.ID AS Batch_ID,
           (SELECT MAX(f.counter_outfeed) FROM [dbo].[T_M_Filler_Process] f WHERE f.Machine = cpb.Machine)
         + ISNULL((SELECT SUM(fs.Out_Feed_Seg) FROM [dbo].[Feed_Segment_log] fs WHERE fs.Batch_ID = cpb.ID), 0) AS live_c
    FROM [dbo].[Change paper brik] cpb
    WHERE cpb.Machine LIKE 'M%' AND cpb.[Product Date] >= '2026-06-16' AND cpb.End_time_CIP IS NULL
),
reel_raw AS (
    SELECT cpb.ID AS Batch_ID, cpb.[Product_ID] AS product_id, cpb.Machine, v.N, v.ord, v.reel
    FROM [dbo].[Change paper brik] cpb
    CROSS APPLY (VALUES
        (1, cpb.[Order1], cpb.[Reel1]),   (2, cpb.[Order2], cpb.[Reel2]),
        (3, cpb.[Order3], cpb.[Reel3]),   (4, cpb.[Order4], cpb.[Reel4]),
        (5, cpb.[Order5], cpb.[Reel5]),   (6, cpb.[Order6], cpb.[Reel6]),
        (7, cpb.[Order7], cpb.[Reel7]),   (8, cpb.[Order8], cpb.[Reel8]),
        (9, cpb.[Order9], cpb.[Reel9]),   (10, cpb.[Order10], cpb.[Reel10]),
        (11, cpb.[Order11], cpb.[Reel11]),(12, cpb.[Order12], cpb.[Reel12]),
        (13, cpb.[Order13], cpb.[Reel13]),(14, cpb.[Order14], cpb.[Reel14]),
        (15, cpb.[Order15], cpb.[Reel15]),(16, cpb.[Order16], cpb.[Reel16]),
        (17, cpb.[Order17], cpb.[Reel17]),(18, cpb.[Order18], cpb.[Reel18]),
        (19, cpb.[Order19], cpb.[Reel19]),(20, cpb.[Order20], cpb.[Reel20]),
        (21, cpb.[Order21], cpb.[Reel21]),(22, cpb.[Order22], cpb.[Reel22]),
        (23, cpb.[Order23], cpb.[Reel23]),(24, cpb.[Order24], cpb.[Reel24]),
        (25, cpb.[Order25], cpb.[Reel25]),(26, cpb.[Order26], cpb.[Reel26]),
        (27, cpb.[Order27], cpb.[Reel27]),(28, cpb.[Order28], cpb.[Reel28]),
        (29, cpb.[Order29], cpb.[Reel29]),(30, cpb.[Order30], cpb.[Reel30]),
        (31, cpb.[Order31], cpb.[Reel31]),(32, cpb.[Order32], cpb.[Reel32]),
        (33, cpb.[Order33], cpb.[Reel33]),(34, cpb.[Order34], cpb.[Reel34]),
        (35, cpb.[Order35], cpb.[Reel35]),(36, cpb.[Order36], cpb.[Reel36]),
        (37, cpb.[Order37], cpb.[Reel37]),(38, cpb.[Order38], cpb.[Reel38]),
        (39, cpb.[Order39], cpb.[Reel39]),(40, cpb.[Order40], cpb.[Reel40]),
        (41, cpb.[Order41], cpb.[Reel41]),(42, cpb.[Order42], cpb.[Reel42]),
        (43, cpb.[Order43], cpb.[Reel43]),(44, cpb.[Order44], cpb.[Reel44]),
        (45, cpb.[Order45], cpb.[Reel45])
    ) v(N, ord, reel)
    WHERE cpb.Machine LIKE 'M%'
      AND cpb.[Product Date] >= '2026-06-16'
      AND cpb.End_time_CIP IS NULL
      AND v.ord IS NOT NULL
),
reel_dd AS (
    SELECT Batch_ID, product_id, Machine, N, ord, reel,
           LAG(ord)  OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_ord,
           LAG(reel) OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_reel
    FROM reel_raw
),
reel AS (
    SELECT Batch_ID, product_id, Machine,
           ROW_NUMBER() OVER (PARTITION BY Batch_ID ORDER BY N) AS seq,
           CAST(CAST(ord  AS decimal(38,0)) AS varchar(50))
         + CAST(CAST(reel AS decimal(38,0)) AS varchar(50)) AS supplier_barcode
    FROM reel_dd
    WHERE prev_ord IS NULL OR ord <> prev_ord OR reel <> prev_reel
)
SELECT
    r.Batch_ID AS id,
    r.product_id,
    r.supplier_barcode,
    CONVERT(BIGINT, ISNULL(s_end.c, l.live_c)) AS outfeed   -- outfeed @ splice=seq, else live (running reel)
FROM reel r
LEFT JOIN splice s_end ON s_end.Batch_ID = r.Batch_ID AND s_end.k = r.seq
LEFT JOIN live   l     ON l.Batch_ID = r.Batch_ID
GO

-- ------------------------------------------------------------
-- VIEW B : v_reel_pallet_map
-- One row per (reel, pallet) -> the many-to-many recall surface.
-- Columns: id, product_id, supplier_barcode, pallet_no
-- A bad pallet:  SELECT supplier_barcode FROM analytics.v_reel_pallet_map
--                WHERE id=@batch AND pallet_no=@pallet;
-- A bad reel:    ... WHERE supplier_barcode=@bc;  -> every pallet it touched.
-- ------------------------------------------------------------
CREATE OR ALTER VIEW [analytics].[v_reel_pallet_map] AS
WITH splice AS (
    SELECT rsl.Batch_ID, rsl.Splice_No AS k,
           rsl.Counter_Outfeed
         + ISNULL((SELECT SUM(fs.Out_Feed_Seg) FROM [dbo].[Feed_Segment_log] fs
                   WHERE fs.Batch_ID = rsl.Batch_ID
                     AND fs.Reset_Time < rsl.Log_Time), 0) AS c
    FROM [dbo].[Reel_Splice_log] rsl
),
live AS (
    SELECT cpb.ID AS Batch_ID,
           (SELECT MAX(f.counter_outfeed) FROM [dbo].[T_M_Filler_Process] f WHERE f.Machine = cpb.Machine)
         + ISNULL((SELECT SUM(fs.Out_Feed_Seg) FROM [dbo].[Feed_Segment_log] fs WHERE fs.Batch_ID = cpb.ID), 0) AS live_c
    FROM [dbo].[Change paper brik] cpb
    WHERE cpb.Machine LIKE 'M%' AND cpb.[Product Date] >= '2026-06-16' AND cpb.End_time_CIP IS NULL
),
reel_raw AS (
    SELECT cpb.ID AS Batch_ID, cpb.[Product_ID] AS product_id, cpb.Machine, v.N, v.ord, v.reel
    FROM [dbo].[Change paper brik] cpb
    CROSS APPLY (VALUES
        (1, cpb.[Order1], cpb.[Reel1]),   (2, cpb.[Order2], cpb.[Reel2]),
        (3, cpb.[Order3], cpb.[Reel3]),   (4, cpb.[Order4], cpb.[Reel4]),
        (5, cpb.[Order5], cpb.[Reel5]),   (6, cpb.[Order6], cpb.[Reel6]),
        (7, cpb.[Order7], cpb.[Reel7]),   (8, cpb.[Order8], cpb.[Reel8]),
        (9, cpb.[Order9], cpb.[Reel9]),   (10, cpb.[Order10], cpb.[Reel10]),
        (11, cpb.[Order11], cpb.[Reel11]),(12, cpb.[Order12], cpb.[Reel12]),
        (13, cpb.[Order13], cpb.[Reel13]),(14, cpb.[Order14], cpb.[Reel14]),
        (15, cpb.[Order15], cpb.[Reel15]),(16, cpb.[Order16], cpb.[Reel16]),
        (17, cpb.[Order17], cpb.[Reel17]),(18, cpb.[Order18], cpb.[Reel18]),
        (19, cpb.[Order19], cpb.[Reel19]),(20, cpb.[Order20], cpb.[Reel20]),
        (21, cpb.[Order21], cpb.[Reel21]),(22, cpb.[Order22], cpb.[Reel22]),
        (23, cpb.[Order23], cpb.[Reel23]),(24, cpb.[Order24], cpb.[Reel24]),
        (25, cpb.[Order25], cpb.[Reel25]),(26, cpb.[Order26], cpb.[Reel26]),
        (27, cpb.[Order27], cpb.[Reel27]),(28, cpb.[Order28], cpb.[Reel28]),
        (29, cpb.[Order29], cpb.[Reel29]),(30, cpb.[Order30], cpb.[Reel30]),
        (31, cpb.[Order31], cpb.[Reel31]),(32, cpb.[Order32], cpb.[Reel32]),
        (33, cpb.[Order33], cpb.[Reel33]),(34, cpb.[Order34], cpb.[Reel34]),
        (35, cpb.[Order35], cpb.[Reel35]),(36, cpb.[Order36], cpb.[Reel36]),
        (37, cpb.[Order37], cpb.[Reel37]),(38, cpb.[Order38], cpb.[Reel38]),
        (39, cpb.[Order39], cpb.[Reel39]),(40, cpb.[Order40], cpb.[Reel40]),
        (41, cpb.[Order41], cpb.[Reel41]),(42, cpb.[Order42], cpb.[Reel42]),
        (43, cpb.[Order43], cpb.[Reel43]),(44, cpb.[Order44], cpb.[Reel44]),
        (45, cpb.[Order45], cpb.[Reel45])
    ) v(N, ord, reel)
    WHERE cpb.Machine LIKE 'M%'
      AND cpb.[Product Date] >= '2026-06-16'
      AND cpb.End_time_CIP IS NULL
      AND v.ord IS NOT NULL
),
reel_dd AS (
    SELECT Batch_ID, product_id, Machine, N, ord, reel,
           LAG(ord)  OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_ord,
           LAG(reel) OVER (PARTITION BY Batch_ID ORDER BY N) AS prev_reel
    FROM reel_raw
),
reel AS (
    SELECT Batch_ID, product_id, Machine,
           ROW_NUMBER() OVER (PARTITION BY Batch_ID ORDER BY N) AS seq,
           CAST(CAST(ord  AS decimal(38,0)) AS varchar(50))
         + CAST(CAST(reel AS decimal(38,0)) AS varchar(50)) AS supplier_barcode
    FROM reel_dd
    WHERE prev_ord IS NULL OR ord <> prev_ord OR reel <> prev_reel
),
rng AS (
    SELECT
        r.Batch_ID AS id, r.product_id, r.supplier_barcode,
        CONVERT(INT, FLOOR(ISNULL(s_start.c, 0)        / 4800.0) + 1) AS start_pallet,
        CONVERT(INT, CEILING(ISNULL(s_end.c, l.live_c) / 4800.0))     AS end_pallet
    FROM reel r
    LEFT JOIN splice s_start ON s_start.Batch_ID = r.Batch_ID AND s_start.k = r.seq - 1
    LEFT JOIN splice s_end   ON s_end.Batch_ID   = r.Batch_ID AND s_end.k   = r.seq
    LEFT JOIN live   l       ON l.Batch_ID = r.Batch_ID
)
SELECT rng.id, rng.product_id, rng.supplier_barcode, p.pallet_no
FROM rng
CROSS APPLY (
    SELECT TOP (rng.end_pallet - rng.start_pallet + 1)
           rng.start_pallet + CONVERT(INT, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))) - 1 AS pallet_no
    FROM sys.all_objects
) p
WHERE rng.end_pallet >= rng.start_pallet
GO

-- ------------------------------------------------------------
-- VALIDATION (run after a batch has a few reel changes):
-- distinct reels should = splices + 1 per batch.
--   SELECT e.id, COUNT(*) AS reels,
--          (SELECT COUNT(*) FROM dbo.[Reel_Splice_log] s WHERE s.Batch_ID=e.id) AS splices
--   FROM analytics.v_reel_pallet_estimate e GROUP BY e.id;
-- If reels <> splices+1, seq and Splice_No are misaligned (missed/extra splice).
-- ------------------------------------------------------------
